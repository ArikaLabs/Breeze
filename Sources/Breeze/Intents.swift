import AppIntents
import AppKit
import MideaKit

// Siri / Shortcuts actions. They run inside the app process and drive the same store the UI uses.

@MainActor
private func breezeStore() throws -> DeviceStore {
    guard let store = (NSApp.delegate as? AppDelegate)?.store else { throw IntentError.notRunning }
    return store
}

@MainActor
private func targetSession(_ store: DeviceStore, named name: String?) throws -> DeviceSession {
    if let name, !name.isEmpty {
        guard let s = store.sessions.first(where: { $0.name.lowercased() == name.lowercased() }) else { throw IntentError.unknownUnit(name) }
        return s
    }
    guard let s = store.current else { throw IntentError.noUnit }
    return s
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case noUnit
    case unknownUnit(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: return "Breeze isn't running."
        case .noUnit: return "No air conditioner is linked in Breeze yet."
        case .unknownUnit(let n): return "Breeze has no unit called \(n)."
        }
    }
}

enum ACModeChoice: String, AppEnum {
    case auto, cool, dry, heat, fan

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "AC Mode" }
    static var caseDisplayRepresentations: [ACModeChoice: DisplayRepresentation] {
        [.auto: "Auto", .cool: "Cool", .dry: "Dry", .heat: "Heat", .fan: "Fan"]
    }

    var mode: OperationalMode {
        switch self {
        case .auto: return .auto
        case .cool: return .cool
        case .dry: return .dry
        case .heat: return .heat
        case .fan: return .fanOnly
        }
    }
}

struct TurnOnACIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn On Air Conditioner"
    static var description = IntentDescription("Turns the air conditioner on using its current mode and temperature.")
    static var openAppWhenRun = false

    @Parameter(title: "Unit", description: "Leave empty for the selected unit.")
    var unit: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try targetSession(try breezeStore(), named: unit)
        session.setPower(true)
        return .result(dialog: "Turning on \(session.name).")
    }
}

struct TurnOffACIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off Air Conditioner"
    static var description = IntentDescription("Turns the air conditioner off.")
    static var openAppWhenRun = false

    @Parameter(title: "Unit", description: "Leave empty for the selected unit.")
    var unit: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try targetSession(try breezeStore(), named: unit)
        session.setPower(false)
        return .result(dialog: "Turning off \(session.name).")
    }
}

struct SetACTemperatureIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Air Conditioner Temperature"
    static var description = IntentDescription("Sets the target temperature and turns the unit on.")
    static var openAppWhenRun = false

    @Parameter(title: "Temperature", description: "In the unit Breeze is set to display.")
    var temperature: Double

    @Parameter(title: "Mode")
    var mode: ACModeChoice?

    @Parameter(title: "Unit", description: "Leave empty for the selected unit.")
    var unit: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$unit) to \(\.$temperature) degrees") {
            \.$mode
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try breezeStore()
        let session = try targetSession(store, named: unit)
        let celsius = store.settings.useFahrenheit ? (temperature - 32) * 5 / 9 : temperature
        let clamped = min(max(celsius, session.capabilities.minTemperature), session.capabilities.maxTemperature)
        let chosen = mode
        session.mutate { s in
            s.power = true
            s.targetTemperature = (clamped * 2).rounded() / 2
            if let chosen { s.mode = chosen.mode }
        }
        return .result(dialog: "\(session.name) set to \(store.displayTemperature(clamped))\(store.unitSymbol).")
    }
}

struct SetACModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Air Conditioner Mode"
    static var description = IntentDescription("Switches the mode and turns the unit on.")
    static var openAppWhenRun = false

    @Parameter(title: "Mode")
    var mode: ACModeChoice

    @Parameter(title: "Unit", description: "Leave empty for the selected unit.")
    var unit: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try targetSession(try breezeStore(), named: unit)
        session.setMode(mode.mode)
        return .result(dialog: "\(session.name) switched to \(mode.mode.name).")
    }
}

struct GetACStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Air Conditioner Status"
    static var description = IntentDescription("Reports power, mode, set and room temperature.")
    static var openAppWhenRun = false

    @Parameter(title: "Unit", description: "Leave empty for the selected unit.")
    var unit: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = try breezeStore()
        let session = try targetSession(store, named: unit)
        let s = session.state
        var text = "\(session.name) is \(s.power ? "on" : "off")"
        if s.power { text += ", \(s.mode.name) at \(store.displayTemperature(s.targetTemperature))\(store.unitSymbol)" }
        if let room = s.indoorTemperature { text += ". Room \(store.displayTemperature(room, decimals: false))\(store.unitSymbol)" }
        if let h = s.indoorHumidity { text += ", \(h)% humidity" }
        text += "."
        return .result(value: text, dialog: "\(text)")
    }
}

struct BreezeShortcuts: AppShortcutsProvider {
    // Phrases deliberately avoid "turn on the air conditioner", which Siri routes to HomeKit.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnOnACIntent(),
                    phrases: ["Start cooling with \(.applicationName)",
                              "Cool the office with \(.applicationName)",
                              "\(.applicationName) on",
                              "Start \(.applicationName) cooling"],
                    shortTitle: "Start cooling", systemImageName: "snowflake")
        AppShortcut(intent: TurnOffACIntent(),
                    phrases: ["Stop cooling with \(.applicationName)",
                              "\(.applicationName) off",
                              "Stop \(.applicationName) cooling"],
                    shortTitle: "Stop cooling", systemImageName: "power")
        AppShortcut(intent: GetACStatusIntent(),
                    phrases: ["\(.applicationName) status",
                              "How is the office with \(.applicationName)",
                              "Check the office with \(.applicationName)"],
                    shortTitle: "Office status", systemImageName: "thermometer.medium")
    }
}
