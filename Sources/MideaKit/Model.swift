import Foundation

public enum OperationalMode: UInt8, CaseIterable, Codable, Sendable {
    case auto = 1, cool = 2, dry = 3, heat = 4, fanOnly = 5, smartDry = 6

    public var name: String {
        switch self {
        case .auto: return "Auto"
        case .cool: return "Cool"
        case .dry: return "Dry"
        case .heat: return "Heat"
        case .fanOnly: return "Fan"
        case .smartDry: return "Smart Dry"
        }
    }
}

public enum FanSpeed: Int, CaseIterable, Codable, Sendable {
    case silent = 20, low = 40, medium = 60, high = 80, max = 100, auto = 102

    public var name: String {
        switch self {
        case .silent: return "Silent"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .max: return "Max"
        case .auto: return "Auto"
        }
    }

    /// Nearest named speed for a raw percentage.
    public static func nearest(_ raw: Int) -> FanSpeed {
        if raw == FanSpeed.auto.rawValue { return .auto }
        return FanSpeed.allCases.filter { $0 != .auto }.min { abs($0.rawValue - raw) < abs($1.rawValue - raw) } ?? .auto
    }
}

public enum SwingMode: UInt8, CaseIterable, Codable, Sendable {
    case off = 0x0, horizontal = 0x3, vertical = 0xC, both = 0xF

    public var name: String {
        switch self {
        case .off: return "Off"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .both: return "Both"
        }
    }
}

public enum SwingAngle: UInt8, CaseIterable, Codable, Sendable {
    case off = 0, pos1 = 1, pos2 = 25, pos3 = 50, pos4 = 75, pos5 = 100
}

public enum BreezeMode: UInt8, CaseIterable, Codable, Sendable {
    case off = 1, breezeAway = 2, breezeMild = 3, breezeless = 4
}

public enum AuxHeatMode: UInt8, CaseIterable, Codable, Sendable {
    case off = 0, auxHeat = 1, auxOnly = 2
}

/// Mutable state of an air conditioner. Setters feed `AirConditioner.apply`,
/// sensors are read-only and refreshed from the device.
public struct ACState: Equatable, Codable, Sendable {
    public var power = false
    public var targetTemperature: Double = 24
    public var mode: OperationalMode = .auto
    /// Fan speed as a percentage, or `FanSpeed.auto.rawValue` (102).
    public var fanSpeed: Int = FanSpeed.auto.rawValue
    public var swingMode: SwingMode = .off
    public var eco = false
    public var turbo = false
    public var sleep = false
    public var freezeProtection = false
    public var fahrenheit = false
    public var displayOn = true
    /// Whether the unit beeps when a command is applied.
    public var sound = true
    public var followMe = false
    public var purifier = false
    public var targetHumidity = 40
    public var auxMode: AuxHeatMode = .off

    // Property based features (0xB0/0xB1 frames).
    public var flash = false          // "Cool/Heat Flash" button
    public var ieco = false           // "AI" / ECOMASTER button
    public var breezeMode: BreezeMode = .off
    public var horizontalSwingAngle: SwingAngle = .off
    public var verticalSwingAngle: SwingAngle = .off

    // Sensors
    public var indoorTemperature: Double?
    public var outdoorTemperature: Double?
    public var indoorHumidity: Int?
    public var filterAlert = false
    public var errorCode = 0

    // Energy (group 4), when the unit reports it
    public var realTimePower: Double?      // W
    public var totalEnergy: Double?        // kWh, cumulative
    public var currentRunEnergy: Double?   // kWh since power on

    public init() {}
}

public struct ACCapabilities: Equatable, Codable, Sendable {
    public var modes: [OperationalMode] = [.auto, .cool, .dry, .heat, .fanOnly]
    public var fanSpeeds: [FanSpeed] = [.silent, .low, .medium, .high, .auto]
    public var customFanSpeed = true
    public var swingModes: [SwingMode] = [.off, .vertical, .horizontal, .both]
    public var eco = true
    public var turbo = true
    public var freezeProtection = true
    public var displayControl = true
    public var filterReminder = true
    public var purifier = true
    public var humidity = false
    public var targetHumidity = false
    public var swingHorizontalAngle = false
    public var swingVerticalAngle = false
    public var breezeAway = false
    public var breezeControl = false
    public var breezeless = false
    public var cascade = false
    public var flash = false
    public var freshAir = false
    public var outSilent = false
    public var selfClean = false
    public var sound = false
    public var ieco = false
    public var iecoNumber = 1
    public var energyStats = false
    public var auxModes: [AuxHeatMode] = [.off]
    public var minTemperature: Double = 16
    public var maxTemperature: Double = 30
    /// Raw decoded capability flags, kept for diagnostics.
    public var raw: [String: Double] = [:]

    public init() {}
}

public struct DiscoveredDevice: Equatable, Codable, Sendable, Identifiable, Hashable {
    public var ip: String
    public var port: UInt16
    public var deviceId: UInt64
    public var name: String      // Wi-Fi SSID of the module, e.g. net_ac_1A2B
    public var serialNumber: String
    public var deviceType: UInt8 // 0xAC = air conditioner
    public var version: Int      // LAN protocol version, 2 or 3

    public var id: UInt64 { deviceId }
    public var isAirConditioner: Bool { deviceType == 0xAC }
    /// Short tag derived from the SSID suffix, e.g. "E3DC".
    public var shortTag: String { name.split(separator: "_").last.map(String.init) ?? name }

    public init(ip: String, port: UInt16, deviceId: UInt64, name: String, serialNumber: String, deviceType: UInt8, version: Int) {
        self.ip = ip; self.port = port; self.deviceId = deviceId; self.name = name
        self.serialNumber = serialNumber; self.deviceType = deviceType; self.version = version
    }
}
