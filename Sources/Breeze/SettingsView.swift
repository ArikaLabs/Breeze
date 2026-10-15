import SwiftUI
import ServiceManagement
import MideaKit

struct SettingsView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notice: String?

    var body: some View {
        Group {
            if store.showSetup || !store.isConfigured {
                SetupFlowView().frame(width: 460)
            } else {
                form
            }
        }
        .background(StoneGround())
    }

    private func flash(_ text: String) {
        notice = text
        Task { try? await Task.sleep(for: .seconds(2.5)); if notice == text { notice = nil } }
    }

    private var form: some View {
        Form {
            Section("Air conditioners") {
                ForEach(store.sessions) { session in
                    UnitRow(session: session, isSelected: session.id == store.current?.id)
                }
                HStack {
                    Button("Add unit…") { store.showSetup = true }
                    Spacer()
                    if store.capabilities.selfClean {
                        Button("Self clean") { store.startSelfClean() }
                            .help("Runs the unit's evaporator self-cleaning cycle (unit should be idle)")
                    }
                    Button("Identify (blink display)") { store.identify() }
                    Button("Toggle unit display") { store.toggleDisplay() }
                }
            }

            Section("Preferences") {
                Picker("Temperature unit", selection: Binding(get: { store.settings.useFahrenheit }, set: { store.settings.useFahrenheit = $0 })) {
                    Text("Celsius").tag(false)
                    Text("Fahrenheit").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Beep on commands", isOn: Binding(get: { store.settings.beep }, set: { store.settings.beep = $0 }))
                Picker("Appearance", selection: Binding(get: { store.settings.appearance }, set: { store.settings.appearance = $0 })) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Refresh every", selection: Binding(get: { store.settings.pollIntervalSeconds }, set: { store.settings.pollIntervalSeconds = $0 })) {
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("30 minutes").tag(1800)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Mac temperature") {
                Toggle("Suggest cooling when my Mac runs hot",
                       isOn: Binding(get: { store.settings.suggestCooling }, set: { store.settings.suggestCooling = $0 }))
                Stepper(value: Binding(get: { store.settings.hotMacThreshold }, set: { store.settings.hotMacThreshold = $0 }),
                        in: 70...105, step: 1) {
                    HStack { Text("Mac hotter than"); Spacer(); Text("\(Int(store.settings.hotMacThreshold)) °C").monospacedDigit() }
                }
                Stepper(value: Binding(get: { store.settings.warmRoomThreshold }, set: { store.settings.warmRoomThreshold = $0 }),
                        in: 16...32, step: 0.5) {
                    HStack { Text("Room warmer than"); Spacer(); Text("\(store.displayTemperature(store.settings.warmRoomThreshold))\(store.unitSymbol)").monospacedDigit() }
                }
                ThermalReadout(monitor: store.thermal)
            }

            Section("Energy") {
                Toggle("Log energy use", isOn: Binding(get: { store.settings.energyLogging }, set: { store.settings.energyLogging = $0 }))
                EnergyReadout()
                LabeledContent("Database") {
                    Text(EnergyLog.shared.fileURL.path)
                        .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }

            Section("Automation") {
                Text("Shortcuts, scripts and cron can drive Breeze with URLs:\nbreeze://cool?temp=22 · breeze://off · breeze://power?on=toggle&unit=Office · breeze://set?mode=heat&fan=low\nThe midea-cli tool accepts --saved to reuse the linked unit from scripts.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Backup & diagnostics") {
                HStack {
                    Button("Copy token & key") { store.copyCredentials(); flash("Token and key copied") }
                    Button("Reveal credentials file") { store.revealCredentials() }
                    Spacer()
                    Button("Copy diagnostics") { store.copyDiagnostics(); flash("Diagnostics copied") }
                }
                Text("Stored in \(CredentialStore.usesKeychain ? "the macOS Keychain" : "a user-only file (Keychain is used once the app has a stable code signature)"). Keep a copy in a password manager: Midea's cloud may stop issuing tokens, and they are the only way to control the unit locally.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Theme.primary)
                }
            }

            Section("What \(store.deviceName) supports") {
                Text(capabilitySummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .textSelection(.enabled)
            }

            Section {
                HStack {
                    Button("Remove \(store.deviceName)", role: .destructive) {
                        if let s = store.current { store.forget(deviceId: s.id) }
                    }
                    Spacer()
                    Button("Quit Breeze") { store.quitRequested?() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(Theme.primary)
        .frame(width: 460, height: 780)
    }

    private var capabilitySummary: String {
        let c = store.capabilities
        var lines: [String] = []
        lines.append("modes: " + c.modes.map(\.name).joined(separator: ", "))
        lines.append("fan: " + c.fanSpeeds.map(\.name).joined(separator: ", ") + (c.customFanSpeed ? " (custom %)" : ""))
        lines.append("swing: " + c.swingModes.map(\.name).joined(separator: ", "))
        lines.append("range: \(c.minTemperature)–\(c.maxTemperature) °C")
        var flags: [String] = []
        if c.eco { flags.append("eco") }
        if c.ieco { flags.append("AI ECOMASTER") }
        if c.turbo { flags.append("turbo") }
        if c.flash { flags.append("flash") }
        if c.humidity { flags.append("humidity") }
        if c.targetHumidity { flags.append("target humidity") }
        if c.breezeAway || c.breezeControl { flags.append("breeze away") }
        if c.breezeless || c.breezeControl { flags.append("breezeless") }
        if c.displayControl { flags.append("display") }
        if c.selfClean { flags.append("self clean") }
        if c.sound { flags.append("sound") }
        if c.freezeProtection { flags.append("freeze protection") }
        if c.energyStats { flags.append("energy stats") }
        lines.append("features: " + (flags.isEmpty ? "—" : flags.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }
}

struct UnitRow: View {
    @EnvironmentObject var store: DeviceStore
    @ObservedObject var session: DeviceSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { store.select(deviceId: session.id) } label: {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.primary : Theme.inkMuted)
            }
            .buttonStyle(.plain)
            .help("Show this unit in the menu bar")
            TextField("Name", text: Binding(get: { session.name }, set: { store.rename(deviceId: session.id, to: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.config.device.ip)
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                StatusLabel(status: session.status)
            }
            .help("Device id \(String(session.id)) · \(session.config.device.name)")
            Spacer()
            Text(roomText).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
        }
        .padding(.vertical, 2)
    }

    private var roomText: String {
        guard let t = session.state.indoorTemperature else { return "" }
        return store.displayTemperature(t, decimals: false) + store.unitSymbol
    }
}

struct EnergyReadout: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        let s = store.energySummary()
        Group {
            LabeledContent("Now") { Text(s?.nowWatts.map(watts) ?? "—") }
            LabeledContent("Today") { Text(s?.todayKWh.map(kwh) ?? "—") }
            LabeledContent("Last 7 days") { Text(s?.weekKWh.map(kwh) ?? "—") }
            LabeledContent("Unit lifetime counter") { Text(s?.totalKWh.map(kwh) ?? "—") }
        }
        .foregroundStyle(Theme.inkMuted)
    }

    private func watts(_ w: Double) -> String { w >= 1000 ? String(format: "%.2f kW", w / 1000) : "\(Int(w.rounded())) W" }
    private func kwh(_ k: Double) -> String { String(format: "%.2f kWh", k) }
}

struct ThermalReadout: View {
    @ObservedObject var monitor: ThermalMonitor

    var body: some View {
        LabeledContent("Right now") {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(monitor.isHot ? Theme.warning : Theme.inkMuted)
                .multilineTextAlignment(.trailing)
        }
    }

    private var text: String {
        guard let s = monitor.sample else {
            return monitor.sensorsAvailable ? "Reading sensors…" : "No temperature sensors available"
        }
        var parts: [String] = []
        if let soc = s.socTemperature { parts.append("SoC \(Int(soc.rounded()))°C") }
        if let name = s.hottestName, let v = s.hottestValue, s.socTemperature == nil { parts.append("\(name) \(Int(v.rounded()))°C") }
        parts.append("pressure \(s.thermalState.label.lowercased())")
        if monitor.isHot { parts.append("HOT") }
        return parts.joined(separator: " · ")
    }
}
