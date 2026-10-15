import SwiftUI
import MideaKit

struct ControlPanelView: View {
    @EnvironmentObject var store: DeviceStore

    private var state: ACState { store.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let suggestion = store.coolingSuggestion {
                coolingBanner(suggestion).padding(.top, 12)
            }
            HeroView(isOn: state.power, mode: state.mode, swing: state.swingMode, fanSpeed: state.fanSpeed)
                .frame(height: 132, alignment: .top)
            temperatureRow
            sliderRow.padding(.top, 14)
            tiles.padding(.top, 18)
            footer.padding(.top, 18)
        }
        .padding(20)
        .foregroundStyle(Theme.ink)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 16))
                .foregroundStyle(Theme.inkMuted)
            if store.sessions.count > 1 {
                Menu {
                    ForEach(store.sessions) { session in
                        Button {
                            store.select(deviceId: session.id)
                        } label: {
                            let room = session.state.indoorTemperature.map { " · \(store.displayTemperature($0, decimals: false))\(store.unitSymbol)" } ?? ""
                            let power = session.status.isOnline ? (session.state.power ? "on" : "off") : "offline"
                            Label("\(session.name)\(room) · \(power)", systemImage: session.id == store.current?.id ? "checkmark" : "air.conditioner.horizontal")
                        }
                    }
                    Divider()
                    Button("Add unit…") { store.showSetup = true }
                } label: {
                    HStack(spacing: 5) {
                        Text(store.deviceName).font(.system(size: 18, design: .serif))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkMuted)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                // The unit's name is a name on the canvas: set in the serif, like the house style's labels.
                Text(store.deviceName)
                    .font(.system(size: 18, design: .serif))
            }
            Text(roomTemperature)
                .fontWeight(.semibold)
                .contentTransition(.numericText())
                .help("Room temperature, measured by the unit")
            if let humidity = state.indoorHumidity {
                HStack(spacing: 3) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 11))
                    Text("\(humidity)%")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkMuted)
                .help("Indoor humidity \(humidity)%, measured by the unit")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Indoor humidity \(humidity) percent")
            }
            Spacer()
            PowerButton(isOn: state.power) { store.setPower(!state.power) }
        }
        .font(.system(size: 15))
    }

    private var roomTemperature: String {
        guard let t = state.indoorTemperature else { return "—" }
        return store.displayTemperature(t, decimals: false) + store.unitSymbol
    }

    private var temperatureRow: some View {
        HStack(alignment: .center) {
            let parts = store.temperatureParts(state.targetTemperature)
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(parts.whole)
                    .font(.system(size: 58, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: state.targetTemperature)
                // One fixed column: unit at the top, half degree at the baseline. Nothing moves
                // when the ".5" appears, and without it the unit reads like a raised "22 °C".
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.unitSymbol)
                        .foregroundStyle(Theme.inkMuted)
                    Spacer(minLength: 0)
                    Text(parts.fraction ?? ".5")
                        .opacity(parts.fraction == nil ? 0 : 1)
                        .contentTransition(.numericText())
                }
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
                .frame(width: 34, height: 50, alignment: .leading)
            }
            Spacer()
            if store.ecoSupported {
                EcoCard(label: store.ecoLabel,
                        isOn: Binding(get: { store.ecoOn }, set: { store.setEco($0) }))
            }
        }
        .opacity(state.power ? 1 : 0.55)
    }

    private var sliderRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                RoundIconButton("minus") { store.stepTemperature(-0.5) }
                TemperatureSlider(
                    value: Binding(get: { state.targetTemperature }, set: { store.setTargetTemperature($0) }),
                    range: store.capabilities.minTemperature...store.capabilities.maxTemperature,
                    step: 0.5)
                RoundIconButton("plus") { store.stepTemperature(0.5) }
            }
            HStack {
                Text(store.displayTemperature(store.capabilities.minTemperature, decimals: false) + "°")
                Spacer()
                Text(store.displayTemperature(store.capabilities.maxTemperature, decimals: false) + "°")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 62)
        }
        .opacity(state.power ? 1 : 0.55)
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            TileMenu(icon: Self.modeIcon(state.mode), label: "Mode", value: state.mode.name) {
                ForEach(store.capabilities.modes, id: \.self) { mode in
                    Button { store.setMode(mode) } label: { Label(mode.name, systemImage: Self.modeIcon(mode)) }
                }
            }
            TileMenu(icon: "fan", label: "Fan", value: fanName) {
                ForEach(fanOptions, id: \.self) { speed in
                    Button(speed.name) { store.setFanSpeed(speed.rawValue) }
                }
            }
            if store.boostSupported {
                TileToggle(icon: "bolt", label: store.boostLabel, isOn: store.boostOn) { store.setBoost(!store.boostOn) }
            } else {
                TileToggle(icon: "moon", label: "Sleep", isOn: state.sleep) { store.setSleep(!state.sleep) }
            }
            TileMenu(icon: "wind", label: "Airflow", value: state.swingMode.name) {
                ForEach(store.capabilities.swingModes, id: \.self) { swing in
                    Button(swing.name) { store.setSwing(swing) }
                }
                if store.capabilities.breezeAway || store.capabilities.breezeControl || store.capabilities.breezeless {
                    Divider()
                    if store.capabilities.breezeAway || store.capabilities.breezeControl {
                        Button(state.breezeMode == .breezeAway ? "✓ Breeze Away" : "Breeze Away") {
                            store.setBreeze(state.breezeMode == .breezeAway ? .off : .breezeAway)
                        }
                    }
                    if store.capabilities.breezeless || store.capabilities.breezeControl {
                        Button(state.breezeMode == .breezeless ? "✓ Breezeless" : "Breezeless") {
                            store.setBreeze(state.breezeMode == .breezeless ? .off : .breezeless)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            StatusLabel(status: store.status)
            if state.power, let watts = state.realTimePower, watts > 0 {
                Text("· \(powerText(watts))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            Button { store.openSettingsRequested?() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private func coolingBanner(_ suggestion: DeviceStore.CoolingSuggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "thermometer.high")
                .font(.system(size: 18))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Mac is running hot")
                    .font(.system(size: 13, weight: .semibold))
                Text(store.suggestionDetail(suggestion))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Cool") { store.acceptCoolingSuggestion() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .foregroundStyle(Theme.onPrimary)
                .controlSize(.small)
            Button { store.snoozeCoolingSuggestion() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Not now (1 hour)")
        }
        .padding(12)
        .raised(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func powerText(_ watts: Double) -> String {
        watts >= 1000 ? String(format: "%.1f kW", watts / 1000) : "\(Int(watts.rounded())) W"
    }

    // MARK: Helpers

    private var fanOptions: [FanSpeed] {
        let supported = store.capabilities.fanSpeeds
        let order: [FanSpeed] = [.auto, .silent, .low, .medium, .high, .max]
        let options = order.filter { supported.contains($0) }
        return options.isEmpty ? [.auto, .low, .medium, .high] : options
    }

    private var fanName: String {
        if state.fanSpeed == FanSpeed.auto.rawValue { return "Auto" }
        if let named = FanSpeed(rawValue: state.fanSpeed) { return named.name }
        return "\(state.fanSpeed)%"
    }

    static func modeIcon(_ mode: OperationalMode) -> String {
        switch mode {
        case .auto: return "arrow.triangle.2.circlepath"
        case .cool: return "snowflake"
        case .dry: return "drop"
        case .heat: return "sun.max"
        case .fanOnly: return "fan"
        case .smartDry: return "humidity"
        }
    }
}
