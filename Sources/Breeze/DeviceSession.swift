import Foundation
import Combine
import MideaKit

enum ConnectionStatus: Equatable {
    case notConfigured
    case connecting
    case connected
    case syncing
    case offline(String)

    var isOnline: Bool { self == .connected || self == .syncing }
}

/// One configured air conditioner: connection, live state, optimistic updates.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: UInt64
    @Published var config: ConfiguredDevice
    @Published private(set) var state = ACState()
    @Published private(set) var capabilities = ACCapabilities()
    @Published private(set) var status: ConnectionStatus = .connecting
    @Published private(set) var lastRefresh: Date?

    private(set) var ac: AirConditioner
    var beep = true
    var demo = false
    var onIPChanged: ((String) -> Void)?
    var onStateChanged: ((DeviceSession) -> Void)?

    private var desired = ACState()
    private var applyTask: Task<Void, Never>?
    private var applyInFlight = false
    private var pendingApply = false
    private var connecting = false

    init(config: ConfiguredDevice, credentials: DeviceCredentials?, existing: AirConditioner? = nil) {
        self.id = config.id
        self.config = config
        self.ac = existing ?? AirConditioner(ip: config.device.ip, port: config.device.port, id: config.device.deviceId)
        if existing == nil, let credentials {
            let ac = self.ac
            Task { try? await ac.setCredentials(tokenHex: credentials.token, keyHex: credentials.key) }
        }
        installObserver()
    }

    private func installObserver() {
        let ac = self.ac
        Task {
            await ac.setStateObserver { [weak self] state in
                Task { @MainActor in self?.receiveUnsolicited(state) }
            }
        }
    }

    var name: String { config.name }

    // MARK: Demo

    func setDemo(state: ACState, capabilities: ACCapabilities) {
        demo = true
        self.state = state
        self.desired = state
        self.capabilities = capabilities
        status = .connected
        lastRefresh = Date()
    }

    // MARK: Connection

    func connect() async {
        guard !demo, !connecting else { return }
        connecting = true
        defer { connecting = false }
        status = .connecting
        do {
            try await ac.authenticate()
            await finishConnect()
        } catch {
            status = .offline(DeviceSession.describe(error))
            breezeLog("[\(name)] connect failed: \(error)")
            if case LanError.connectFailed = error { await relocate() }
            else if case LanError.timeout = error { await relocate() }
        }
    }

    private func finishConnect() async {
        await loadCapabilitiesIfNeeded()
        do {
            let s = try await ac.refresh()
            state = s
            desired = s
            lastRefresh = Date()
            status = .connected
            onStateChanged?(self)
        } catch {
            status = .offline(DeviceSession.describe(error))
        }
    }

    private func loadCapabilitiesIfNeeded() async {
        guard await !ac.capabilitiesLoaded else { return }
        for attempt in 0..<2 {
            do {
                try await ac.getCapabilities()
                capabilities = await ac.capabilities
                return
            } catch {
                breezeLog("[\(name)] capabilities attempt \(attempt + 1) failed: \(error)")
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(700)) }
            }
        }
    }

    /// The unit may have moved to a new DHCP address: find it again by device ID.
    private func relocate() async {
        guard let found = try? await Discovery.scan(timeout: 3),
              let match = found.first(where: { $0.deviceId == id }), match.ip != config.device.ip else { return }
        breezeLog("[\(name)] moved from \(config.device.ip) to \(match.ip)")
        config.device = match
        let creds = CredentialStore.credentials(for: id)
        await ac.disconnect()
        ac = AirConditioner(ip: match.ip, port: match.port, id: id)
        if let creds { try? await ac.setCredentials(tokenHex: creds.token, keyHex: creds.key) }
        installObserver()
        onIPChanged?(match.ip)
        await connect()
    }

    func reconnect() async {
        guard !demo else { return }
        await ac.disconnect()
        await connect()
    }

    func markOffline(_ reason: String) {
        guard !demo else { return }
        status = .offline(reason)
    }

    func disconnect() async {
        applyTask?.cancel()
        await ac.disconnect()
    }

    func refresh() async {
        guard !demo, !applyInFlight, applyTask == nil, !connecting else { return }
        if case .connecting = status { return }
        await loadCapabilitiesIfNeeded()
        do {
            let s = try await fetchState()
            if applyTask == nil && !applyInFlight {
                state = s
                desired = s
            }
            lastRefresh = Date()
            if status != .syncing { status = .connected }
            onStateChanged?(self)
        } catch {
            status = .offline(DeviceSession.describe(error))
        }
    }

    /// Between the long background polls the unit may drop the idle TCP connection without
    /// telling us; the first request then times out. Retry once on a fresh connection before
    /// reporting the unit offline. Unreachable or rejected units are not retried.
    private func fetchState() async throws -> ACState {
        do {
            return try await ac.refresh()
        } catch let error as LanError where [.timeout, .connectionClosed, .notConnected].contains(error) {
            breezeLog("[\(name)] refresh failed (\(DeviceSession.describe(error))), retrying on a new connection")
            await ac.disconnect()
            return try await ac.refresh()
        }
    }

    private func receiveUnsolicited(_ s: ACState) {
        guard applyTask == nil, !applyInFlight else { return }
        state = s
        desired = s
        lastRefresh = Date()
        onStateChanged?(self)
    }

    // MARK: Control

    func mutate(_ change: (inout ACState) -> Void) {
        change(&desired)
        desired.sound = beep
        state = desired
        if demo { return }
        scheduleApply()
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.applyTask = nil
            await self.performApply()
        }
    }

    private func performApply() async {
        if applyInFlight { pendingApply = true; return }
        applyInFlight = true
        status = .syncing
        let snapshot = desired
        do {
            let result = try await ac.apply(snapshot)
            if desired == snapshot {
                state = result
                desired = result
            }
            status = .connected
            lastRefresh = Date()
            onStateChanged?(self)
        } catch {
            status = .offline(DeviceSession.describe(error))
            breezeLog("[\(name)] apply failed: \(error)")
        }
        applyInFlight = false
        if pendingApply {
            pendingApply = false
            await performApply()
        }
    }

    func setPower(_ on: Bool) { mutate { $0.power = on } }
    func setTargetTemperature(_ celsius: Double) {
        let clamped = min(max(celsius, capabilities.minTemperature), capabilities.maxTemperature)
        mutate { $0.targetTemperature = (clamped * 2).rounded() / 2 }
    }
    func stepTemperature(_ delta: Double) { setTargetTemperature(state.targetTemperature + delta) }
    func setMode(_ mode: OperationalMode) { mutate { $0.mode = mode; $0.power = true } }
    func setFanSpeed(_ speed: Int) { mutate { $0.fanSpeed = speed } }
    func setSwing(_ swing: SwingMode) { mutate { $0.swingMode = swing } }
    func setEco(_ on: Bool) {
        let useIECO = capabilities.ieco
        mutate {
            if useIECO { $0.ieco = on } else { $0.eco = on }
            if on { $0.turbo = false; $0.flash = false }
        }
    }
    func setBoost(_ on: Bool) {
        let useFlash = capabilities.flash
        mutate {
            if useFlash { $0.flash = on } else { $0.turbo = on }
            if on { $0.eco = false; $0.ieco = false }
        }
    }
    func setSleep(_ on: Bool) { mutate { $0.sleep = on } }
    func setBreeze(_ mode: BreezeMode) { mutate { $0.breezeMode = mode } }

    func toggleDisplay() {
        guard !demo else { return }
        Task {
            status = .syncing
            do {
                try await ac.toggleDisplay()
                state = await ac.state
                desired = state
                status = .connected
            } catch { status = .offline(DeviceSession.describe(error)) }
        }
    }

    func startSelfClean() {
        guard !demo else { return }
        Task {
            status = .syncing
            do {
                try await ac.startSelfClean()
                status = .connected
                breezeLog("[\(name)] self clean started")
            } catch { status = .offline(DeviceSession.describe(error)) }
        }
    }

    /// Blink the unit's display so the user can tell which physical unit this is.
    func identify() {
        guard !demo else { return }
        Task {
            do {
                try await ac.toggleDisplay()
                try await Task.sleep(for: .seconds(1.5))
                try await ac.toggleDisplay()
                state = await ac.state
                desired = state
            } catch { status = .offline(DeviceSession.describe(error)) }
        }
    }

    // MARK: Derived

    var ecoSupported: Bool { capabilities.ieco || capabilities.eco }
    var ecoLabel: String { capabilities.ieco ? "AI Eco" : "Eco Mode" }
    var ecoOn: Bool { capabilities.ieco ? state.ieco : state.eco }
    var boostSupported: Bool { capabilities.flash || capabilities.turbo }
    var boostLabel: String { capabilities.flash ? "Flash" : "Turbo" }
    var boostOn: Bool { capabilities.flash ? state.flash : state.turbo }

    static func describe(_ error: Error) -> String {
        if let e = error as? LanError {
            switch e {
            case .timeout: return "No reply from the unit"
            case .connectFailed(let s): return "Can't reach the unit (\(s))"
            case .connectionClosed: return "Connection closed"
            case .notConnected: return "Not connected"
            case .missingCredentials: return "Missing token/key"
            case .protocolError(let s): return "Protocol error: \(s)"
            case .authenticationFailed(let s): return "Authentication failed: \(s)"
            case .deviceRejected: return "The unit rejected the token/key. Is it paired with this account?"
            }
        }
        if let e = error as? CloudError { return e.localizedDescription }
        return error.localizedDescription
    }
}
