import Foundation
import AppKit
import Combine
import Network
import MideaKit

/// App-wide state: configured units, the selected unit, polling, cooling suggestions,
/// setup flow, URL commands, and system events (sleep/wake, network changes).
@MainActor
final class DeviceStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if oldValue.appearance != settings.appearance { applyAppearance() }
            guard settings != oldValue else { return }
            if !demoMode { settings.save() }
            thermal.hotThreshold = settings.hotMacThreshold
            syncSessions()
            updateTitle()
            evaluateCoolingSuggestion()
        }
    }
    @Published private(set) var sessions: [DeviceSession] = []
    @Published private(set) var menuBarTitle = ""
    @Published private(set) var menuBarAlert = false
    @Published private(set) var networkAvailable = true

    // Setup flow
    @Published var discovered: [DiscoveredDevice] = []
    @Published var isScanning = false
    @Published var scanError: String?
    @Published var isLinking = false
    @Published var linkError: String?
    @Published var showSetup = false

    var openSettingsRequested: (() -> Void)?
    var showPopoverRequested: (() -> Void)?
    var quitRequested: (() -> Void)?

    // Cooling suggestions
    struct CoolingSuggestion: Equatable {
        var macTemperature: Double?
        var roomTemperature: Double?
        var thermalState: ProcessInfo.ThermalState
        var since: Date
    }
    let thermal = ThermalMonitor()
    let notifications = NotificationManager()
    @Published private(set) var coolingSuggestion: CoolingSuggestion?
    private var suggestionSnoozedUntil: Date?
    private var lastSuggestionNotified: Date?

    /// BREEZE_DEMO=1 renders the control panel with sample data and no device.
    let demoMode = ProcessInfo.processInfo.environment["BREEZE_DEMO"] != nil

    private var cancellables = Set<AnyCancellable>()
    private var sessionCancellables: [UInt64: [AnyCancellable]] = [:]
    private var pollTask: Task<Void, Never>?
    private var popoverVisible = false
    private var pendingTitle = ""
    private var pathMonitor: NWPathMonitor?
    private var wakeObserver: NSObjectProtocol?
    private var lastEnergyRecord: [UInt64: Date] = [:]

    init() {
        settings = AppSettings.load()
        if demoMode {
            let env = ProcessInfo.processInfo.environment
            var s = ACState()
            s.power = env["BREEZE_DEMO_POWER"]?.lowercased() != "off"
            s.targetTemperature = Double(env["BREEZE_DEMO_TEMP"] ?? "") ?? 23
            s.mode = .cool
            s.fanSpeed = FanSpeed.auto.rawValue
            s.swingMode = SwingMode.allCases.first { $0.name.lowercased() == (env["BREEZE_DEMO_SWING"] ?? "vertical").lowercased() } ?? .vertical
            s.indoorTemperature = 23
            s.indoorHumidity = 58
            s.realTimePower = 820
            var c = ACCapabilities()
            c.ieco = true; c.flash = true; c.humidity = true; c.energyStats = true
            c.minTemperature = 16; c.maxTemperature = 30
            c.swingModes = [.off, .vertical, .horizontal, .both]
            let fake = DiscoveredDevice(ip: "0.0.0.0", port: 6444, deviceId: 1, name: "net_ac_DEMO", serialNumber: "DEMO", deviceType: 0xAC, version: 3)
            let session = DeviceSession(config: ConfiguredDevice(device: fake, name: "Office"), credentials: nil)
            session.setDemo(state: s, capabilities: c)
            sessions = [session]
            if env["BREEZE_DEMO_UNITS"] != nil {
                let other = DiscoveredDevice(ip: "0.0.0.1", port: 6444, deviceId: 2, name: "net_ac_DEM2", serialNumber: "DEMO2", deviceType: 0xAC, version: 3)
                let s2 = DeviceSession(config: ConfiguredDevice(device: other, name: "Meeting room"), credentials: nil)
                var st2 = s; st2.power = false; st2.indoorTemperature = 25.5
                s2.setDemo(state: st2, capabilities: c)
                sessions.append(s2)
            }
            sessions.forEach(observe)
            settings.selectedDeviceId = 1
            if env["BREEZE_DEMO_HOT"] != nil {
                coolingSuggestion = CoolingSuggestion(macTemperature: 96, roomTemperature: 26, thermalState: .serious, since: Date())
                menuBarAlert = true
            }
            updateTitle()
        }
    }

    // MARK: Sessions

    var current: DeviceSession? {
        sessions.first { $0.id == settings.selectedDeviceId } ?? sessions.first
    }

    var isConfigured: Bool { !sessions.isEmpty }

    /// Create/remove sessions so they mirror `settings.devices`.
    private func syncSessions() {
        guard !demoMode else { return }
        var kept: [DeviceSession] = []
        for device in settings.devices {
            if let existing = sessions.first(where: { $0.id == device.id }) {
                if existing.config != device { existing.config = device }
                existing.beep = settings.beep
                kept.append(existing)
            } else if let creds = CredentialStore.credentials(for: device.id) {
                let session = DeviceSession(config: device, credentials: creds)
                session.beep = settings.beep
                observe(session)
                kept.append(session)
                Task { await session.connect() }
            }
        }
        for gone in sessions where !kept.contains(where: { $0.id == gone.id }) {
            sessionCancellables[gone.id] = nil
            Task { await gone.disconnect() }
        }
        if kept.map(\.id) != sessions.map(\.id) { sessions = kept }
    }

    private func observe(_ session: DeviceSession) {
        var subs: [AnyCancellable] = []
        subs.append(session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        subs.append(session.$state.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateTitle()
            self?.evaluateCoolingSuggestion()
        })
        subs.append(session.$status.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateTitle()
            self?.evaluateCoolingSuggestion()
        })
        sessionCancellables[session.id] = subs
        session.onIPChanged = { [weak self, weak session] ip in
            guard let self, let session, let index = self.settings.devices.firstIndex(where: { $0.id == session.id }) else { return }
            self.settings.devices[index].device.ip = ip
        }
        session.onStateChanged = { [weak self] session in self?.recordEnergy(for: session) }
    }

    func select(deviceId: UInt64) {
        guard settings.selectedDeviceId != deviceId else { return }
        settings.selectedDeviceId = deviceId
        if let s = current { Task { await s.refresh() } }
    }

    func rename(deviceId: UInt64, to name: String) {
        guard let index = settings.devices.firstIndex(where: { $0.id == deviceId }) else { return }
        settings.devices[index].name = name
    }

    func forget(deviceId: UInt64) {
        CredentialStore.remove(deviceId: deviceId)
        settings.devices.removeAll { $0.id == deviceId }
        if settings.selectedDeviceId == deviceId { settings.selectedDeviceId = settings.devices.first?.id }
    }

    // MARK: Lifecycle

    func start() {
        MideaLog.handler = { message in Diagnostics.shared.log("kit \(message)") }
        breezeLog("Breeze starting, \(settings.devices.count) unit(s) configured")
        guard !demoMode else { return }
        notifications.configure()
        notifications.onTurnOn = { [weak self] in self?.acceptCoolingSuggestion() }
        notifications.onSnooze = { [weak self] in self?.snoozeCoolingSuggestion() }
        notifications.onOpen = { [weak self] in self?.showPopoverRequested?() }
        thermal.hotThreshold = settings.hotMacThreshold
        thermal.start()
        thermal.$isHot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateCoolingSuggestion() }
            .store(in: &cancellables)
        applyAppearance()
        syncSessions()
        updateTitle()
        startPolling()
        startSystemObservers()
    }

    func stop() {
        thermal.stop()
        pollTask?.cancel()
        pathMonitor?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        let sessions = self.sessions
        Task { for s in sessions { await s.disconnect() } }
    }

    /// Travertine, Basalt or the system's choice. Previews pin one with BREEZE_APPEARANCE instead.
    func applyAppearance() {
        guard ProcessInfo.processInfo.environment["BREEZE_APPEARANCE"] == nil else { return }
        NSApp.appearance = settings.appearance.nsAppearance
    }

    func popoverWillShow() {
        popoverVisible = true
        refreshNow()
    }

    func popoverDidHide() {
        popoverVisible = false
        if menuBarTitle != pendingTitle { menuBarTitle = pendingTitle }
    }

    func refreshNow() {
        guard let s = current else { return }
        Task { await s.refresh() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { () -> Int in
                    guard let self else { return 60 }
                    // The unit never pushes updates, so this is the only source of fresh readings.
                    // Room temperature and humidity move slowly: poll often only while someone is looking.
                    return self.popoverVisible ? 15 : max(60, self.settings.pollIntervalSeconds)
                }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.pollTick()
            }
        }
    }

    private func pollTick() async {
        guard networkAvailable else { return }
        let currentId = current?.id
        for session in sessions {
            if session.id == currentId {
                await session.refresh()
            } else if session.lastRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                await session.refresh()
            }
        }
    }

    private func startSystemObservers() {
        // Wake from sleep: connections are dead, reconnect right away.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                breezeLog("woke from sleep, reconnecting")
                await self?.reconnectAll()
            }
        }
        // Network path changes: go offline immediately, reconnect when back.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let was = self.networkAvailable
                self.networkAvailable = available
                if available && !was {
                    breezeLog("network available, reconnecting")
                    await self.reconnectAll()
                } else if !available && was {
                    breezeLog("network unavailable")
                    self.sessions.forEach { $0.markOffline("No network") }
                    self.updateTitle()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "breeze.path"))
        pathMonitor = monitor
    }

    func reconnectAll() async {
        for s in sessions { await s.reconnect() }
    }

    // MARK: Forwarders for the selected unit (used by views)

    var state: ACState { current?.state ?? ACState() }
    var capabilities: ACCapabilities { current?.capabilities ?? ACCapabilities() }
    var status: ConnectionStatus { current?.status ?? .notConfigured }
    var deviceName: String { current?.name ?? "Air Conditioner" }
    var ecoSupported: Bool { current?.ecoSupported ?? false }
    var ecoLabel: String { current?.ecoLabel ?? "Eco Mode" }
    var ecoOn: Bool { current?.ecoOn ?? false }
    var boostSupported: Bool { current?.boostSupported ?? false }
    var boostLabel: String { current?.boostLabel ?? "Turbo" }
    var boostOn: Bool { current?.boostOn ?? false }

    func setPower(_ on: Bool) { current?.setPower(on) }
    func setTargetTemperature(_ c: Double) { current?.setTargetTemperature(c) }
    func stepTemperature(_ d: Double) { current?.stepTemperature(d) }
    func setMode(_ m: OperationalMode) { current?.setMode(m) }
    func setFanSpeed(_ s: Int) { current?.setFanSpeed(s) }
    func setSwing(_ s: SwingMode) { current?.setSwing(s) }
    func setEco(_ on: Bool) { current?.setEco(on) }
    func setBoost(_ on: Bool) { current?.setBoost(on) }
    func setSleep(_ on: Bool) { current?.setSleep(on) }
    func setBreeze(_ m: BreezeMode) { current?.setBreeze(m) }
    func toggleDisplay() { current?.toggleDisplay() }
    func identify() { current?.identify() }
    func startSelfClean() { current?.startSelfClean() }

    func displayTemperature(_ celsius: Double, decimals: Bool = true) -> String {
        if settings.useFahrenheit {
            return "\(Int((celsius * 9 / 5 + 32).rounded()))"
        }
        let rounded = (celsius * 2).rounded() / 2
        if decimals && rounded != rounded.rounded() { return String(format: "%.1f", rounded) }
        return "\(Int(rounded))"
    }

    var unitSymbol: String { settings.useFahrenheit ? "°F" : "°C" }

    /// Whole degrees plus an optional ".5" so the big readout can reserve a fixed slot for the fraction.
    func temperatureParts(_ celsius: Double) -> (whole: String, fraction: String?) {
        if settings.useFahrenheit { return (displayTemperature(celsius), nil) }
        let rounded = (celsius * 2).rounded() / 2
        let whole = Int(rounded.rounded(.towardZero))
        return (String(whole), rounded != rounded.rounded(.towardZero) ? ".5" : nil)
    }

    private func updateTitle() {
        let title: String
        if let s = current {
            if case .offline = s.status, s.lastRefresh == nil { title = "–" }
            else { title = s.state.power ? "\(displayTemperature(s.state.targetTemperature))°" : "Off" }
        } else {
            title = ""
        }
        pendingTitle = title
        // Frozen while the popover is open so the status item (and the popover anchored to it) never shifts.
        if !popoverVisible || menuBarTitle.isEmpty { menuBarTitle = title }
    }

    // MARK: Energy log

    private func recordEnergy(for session: DeviceSession) {
        guard settings.energyLogging, !session.demo else { return }
        let last = lastEnergyRecord[session.id] ?? .distantPast
        guard Date().timeIntervalSince(last) >= 55 else { return }
        lastEnergyRecord[session.id] = Date()
        EnergyLog.shared.record(deviceId: session.id, state: session.state)
    }

    func energySummary() -> EnergyLog.Summary? {
        guard let s = current, !s.demo else {
            return demoMode ? EnergyLog.Summary(nowWatts: 820, todayKWh: 3.2, weekKWh: 14.8, totalKWh: 1234.5, sampleCount: 1) : nil
        }
        return EnergyLog.shared.summary(deviceId: s.id)
    }

    // MARK: Cooling suggestions

    /// Suggest turning the AC on when the Mac is hot, the selected AC is off, and the room is warm.
    func evaluateCoolingSuggestion() {
        guard !demoMode, let s = current else { return }
        let roomIsWarm = s.state.indoorTemperature.map { $0 >= settings.warmRoomThreshold } ?? true
        let eligible = settings.suggestCooling && s.status.isOnline && thermal.isHot && !s.state.power && roomIsWarm
        guard eligible else {
            if coolingSuggestion != nil { coolingSuggestion = nil; notifications.clear() }
            if menuBarAlert { menuBarAlert = false }
            return
        }
        if let until = suggestionSnoozedUntil, until > Date() { return }
        guard coolingSuggestion == nil else { return }
        let suggestion = CoolingSuggestion(macTemperature: thermal.sample?.displayTemperature,
                                           roomTemperature: s.state.indoorTemperature,
                                           thermalState: thermal.sample?.thermalState ?? .nominal,
                                           since: Date())
        coolingSuggestion = suggestion
        menuBarAlert = true
        breezeLog("cooling suggestion: \(suggestionDetail(suggestion))")
        if lastSuggestionNotified.map({ Date().timeIntervalSince($0) > 3600 }) ?? true {
            lastSuggestionNotified = Date()
            notifications.postCoolingSuggestion(title: "Your Mac is running hot", body: suggestionDetail(suggestion))
        }
    }

    func suggestionDetail(_ s: CoolingSuggestion) -> String {
        var parts: [String] = []
        if let mac = s.macTemperature { parts.append("Mac \(Int(mac.rounded()))°C") }
        if s.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { parts.append("thermal pressure \(s.thermalState.label.lowercased())") }
        if let room = s.roomTemperature { parts.append("\(deviceName.lowercased()) \(displayTemperature(room, decimals: false))\(unitSymbol)") }
        parts.append("AC is off")
        return parts.joined(separator: " · ")
    }

    func acceptCoolingSuggestion() {
        guard let s = current else { return }
        let canCool = s.capabilities.modes.contains(.cool)
        s.mutate { st in
            st.power = true
            if canCool { st.mode = .cool }
        }
        coolingSuggestion = nil
        menuBarAlert = false
        notifications.clear()
    }

    func snoozeCoolingSuggestion(hours: Double = 1) {
        suggestionSnoozedUntil = Date().addingTimeInterval(hours * 3600)
        coolingSuggestion = nil
        menuBarAlert = false
        notifications.clear()
    }

    // MARK: Setup

    func scan(host: String? = nil) {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        Task {
            do {
                let hosts = host.map { [$0] } ?? ["255.255.255.255"]
                let found = try await Discovery.scan(hosts: hosts, timeout: host == nil ? 4 : 2)
                discovered = found.filter(\.isAirConditioner)
                if discovered.isEmpty { scanError = host == nil ? "No Midea units answered on this network." : "No Midea unit answered at \(host!)." }
            } catch {
                scanError = DeviceSession.describe(error)
            }
            isScanning = false
        }
    }

    func isAlreadyConfigured(_ device: DiscoveredDevice) -> Bool {
        settings.devices.contains { $0.id == device.deviceId }
    }

    /// Fetch token/key from the user's MSmartHome account, verify against the unit, and add it.
    func link(device: DiscoveredDevice, name: String, account: String, password: String) {
        guard !isLinking else { return }
        isLinking = true
        linkError = nil
        Task {
            do {
                let cloud = SmartHomeCloud(account: account, password: password)
                let candidates = try await cloud.fetchCredentialCandidates(deviceId: device.deviceId)
                let probe = AirConditioner(ip: device.ip, port: device.port, id: device.deviceId)
                let creds = try await probe.authenticate(trying: candidates)
                CredentialStore.store(creds, for: device.deviceId)
                let unitName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "AC \(device.shortTag)" : name
                let configured = ConfiguredDevice(device: device, name: unitName)
                // Reuse the connection that just authenticated.
                let session = DeviceSession(config: configured, credentials: creds, existing: probe)
                session.beep = settings.beep
                observe(session)
                if let old = sessions.first(where: { $0.id == device.deviceId }) {
                    Task { await old.disconnect() }
                    sessions.removeAll { $0.id == device.deviceId }
                }
                sessions.append(session)
                var s = settings
                if let i = s.devices.firstIndex(where: { $0.id == device.deviceId }) { s.devices[i] = configured } else { s.devices.append(configured) }
                s.selectedDeviceId = device.deviceId
                settings = s
                showSetup = false
                breezeLog("linked \(unitName) (\(device.ip))")
                await session.connect()
                updateTitle()
            } catch {
                linkError = DeviceSession.describe(error)
                breezeLog("link failed: \(error)")
            }
            isLinking = false
        }
    }

    // MARK: URL commands (breeze://…)

    /// breeze://power?on=1|0|toggle   breeze://set?temp=22&mode=cool&fan=auto&swing=vertical&power=on
    /// breeze://cool?temp=22   breeze://off   breeze://show   — add &unit=Name to target a specific unit.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "breeze" else { return }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            params[item.name.lowercased()] = item.value ?? ""
        }
        let target: DeviceSession?
        if let wanted = params["unit"], !wanted.isEmpty {
            guard let match = sessions.first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
                // Same rule as the App Intents: a named unit that is not linked is an error, never a fallback
                // to whichever unit happens to be selected.
                breezeLog("url command: \(command) ignored, no unit called \(wanted)")
                notifications.postNotice(title: "Breeze has no unit called \(wanted)",
                                         body: "The breeze:// link names a unit that is not linked. Check the unit name in Settings.")
                return
            }
            target = match
        } else {
            target = current
        }
        breezeLog("url command: \(command) \(params)")
        func onOff(_ v: String?) -> Bool? {
            guard let v = v?.lowercased() else { return nil }
            if ["1", "on", "true", "yes"].contains(v) { return true }
            if ["0", "off", "false", "no"].contains(v) { return false }
            return nil
        }
        switch command {
        case "show":
            showPopoverRequested?()
        case "power":
            guard let t = target else { return }
            if params["on"]?.lowercased() == "toggle" { t.setPower(!t.state.power) }
            else if let on = onOff(params["on"] ?? params["state"] ?? "on") { t.setPower(on) }
        case "off":
            target?.setPower(false)
        case "on":
            target?.setPower(true)
        case "set", "cool", "heat":
            guard let t = target else { return }
            t.mutate { s in
                if command == "cool" { s.power = true; s.mode = .cool }
                if command == "heat" { s.power = true; s.mode = .heat }
                if let p = onOff(params["power"]) { s.power = p }
                if let temp = params["temp"].flatMap(Double.init) {
                    let celsius = settings.useFahrenheit ? (temp - 32) * 5 / 9 : temp
                    let clamped = min(max(celsius, t.capabilities.minTemperature), t.capabilities.maxTemperature)
                    s.targetTemperature = (clamped * 2).rounded() / 2
                }
                if let m = params["mode"], let mode = OperationalMode.allCases.first(where: { $0.name.lowercased() == m.lowercased() }) { s.mode = mode; s.power = true }
                if let f = params["fan"] {
                    if let n = Int(f) { s.fanSpeed = n }
                    else if let speed = FanSpeed.allCases.first(where: { $0.name.lowercased() == f.lowercased() }) { s.fanSpeed = speed.rawValue }
                }
                if let sw = params["swing"], let swing = SwingMode.allCases.first(where: { $0.name.lowercased() == sw.lowercased() }) { s.swingMode = swing }
                if let e = onOff(params["eco"]) { if t.capabilities.ieco { s.ieco = e } else { s.eco = e } }
                if let b = onOff(params["boost"] ?? params["flash"] ?? params["turbo"]) { if t.capabilities.flash { s.flash = b } else { s.turbo = b } }
            }
        default:
            breezeLog("unknown url command \(command)")
        }
    }

    // MARK: Diagnostics

    func diagnosticsText() -> String {
        var out: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        out.append("Breeze \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("network: \(networkAvailable ? "available" : "unavailable")")
        if let t = thermal.sample {
            out.append("mac: soc \(t.socTemperature.map { "\(Int($0))°C" } ?? "n/a") pressure \(t.thermalState.label) hot=\(thermal.isHot)")
        }
        for s in sessions {
            out.append("unit \(s.name): \(s.config.device.ip):\(s.config.device.port) id \(s.id) status \(s.status) power=\(s.state.power) target=\(s.state.targetTemperature) room=\(s.state.indoorTemperature.map { "\($0)" } ?? "n/a") caps(ieco=\(s.capabilities.ieco) flash=\(s.capabilities.flash) energy=\(s.capabilities.energyStats))")
        }
        out.append("--- log ---")
        out += Diagnostics.shared.recentLines()
        return out.joined(separator: "\n")
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsText(), forType: .string)
    }

    func copyCredentials() {
        guard let s = current, let text = CredentialStore.exportText(for: s.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealCredentials() {
        NSWorkspace.shared.activateFileViewerSelecting([CredentialStore.fileURL])
    }
}
