import Foundation

public struct StateResponse: Equatable, Sendable {
    public var power = false
    public var targetTemperature: Double = 0
    public var mode: UInt8 = 0
    public var fanSpeed: Int = 0
    public var swingMode: UInt8 = 0
    public var turbo = false
    public var eco = false
    public var sleep = false
    public var fahrenheit = false
    public var indoorTemperature: Double?
    public var outdoorTemperature: Double?
    public var filterAlert = false
    public var displayOn = true
    public var freezeProtection: Bool?
    public var followMe = false
    public var purifier = false
    public var targetHumidity: Int?
    public var auxHeat = false
    public var independentAuxHeat = false
    public var errorCode = 0

    static func parseTemperature(_ raw: UInt8, decimals: Double, fahrenheit: Bool) -> Double? {
        if raw == 0xFF { return nil }
        let t = (Double(raw) - 50) / 2
        if !fahrenheit && decimals != 0 {
            return Double(Int(t)) + (t >= 0 ? decimals : -decimals)
        }
        if decimals >= 0.5 {
            return Double(Int(t)) + (t >= 0 ? 0.5 : -0.5)
        }
        return t
    }

    init(body p: [UInt8]) throws {
        guard p.count >= 17 else { throw FrameError.tooShort }
        power = (p[1] & 0x1) != 0
        targetTemperature = Double(p[2] & 0xF) + 16.0 + ((p[2] & 0x10) != 0 ? 0.5 : 0)
        mode = (p[2] >> 5) & 0x7
        fanSpeed = Int(p[3] & 0x7F)
        swingMode = p[7] & 0xF
        turbo = (p[8] & 0x20) != 0
        independentAuxHeat = (p[8] & 0x40) != 0
        followMe = (p[8] & 0x80) != 0
        eco = (p[9] & 0x10) != 0
        purifier = (p[9] & 0x20) != 0
        auxHeat = (p[9] & 0x08) != 0
        sleep = (p[10] & 0x1) != 0
        turbo = turbo || (p[10] & 0x2) != 0
        fahrenheit = (p[10] & 0x4) != 0
        indoorTemperature = Self.parseTemperature(p[11], decimals: Double(p[15] & 0xF) / 10, fahrenheit: fahrenheit)
        outdoorTemperature = Self.parseTemperature(p[12], decimals: Double(p[15] >> 4) / 10, fahrenheit: fahrenheit)
        let alt = p[13] & 0x1F
        if alt != 0 {
            targetTemperature = Double(alt) + 12 + ((p[2] & 0x10) != 0 ? 0.5 : 0)
        }
        filterAlert = (p[13] & 0x20) != 0
        displayOn = p[14] != 0x70
        errorCode = Int(p[16])
        if p.count >= 20 { targetHumidity = Int(p[19] & 0x7F) }
        if p.count >= 22 { freezeProtection = (p[21] & 0x80) != 0 }
    }
}

public struct CapabilitiesResponse: Equatable, Sendable {
    public var flags: [String: Double] = [:]
    public var additionalCapabilities = false

    private struct Reader { let name: String; let read: ([UInt8]) -> Double? }

    private static func eq(_ name: String, _ v: UInt8) -> Reader { Reader(name: name) { $0.first == v ? 1 : 0 } }
    private static func anyOf(_ name: String, _ set: Set<UInt8>) -> Reader { Reader(name: name) { $0.first.map { set.contains($0) ? 1 : 0 } ?? 0 } }

    private static let readers: [UInt16: [Reader]] = [
        0x021E: [eq("anion", 1)],
        0x0219: [eq("aux_electric_heat", 1)],
        0x0093: [eq("aux_fan_speed", 1)],
        0x0094: [eq("aux_heat_fan_speed", 1)],
        0x0042: [eq("breeze_away", 1)],
        0x0043: [eq("breeze_control", 1)],
        0x0018: [eq("breezeless", 1)],
        0x022C: [eq("sound", 1)],
        0x0059: [eq("cascade", 1)],
        0x0224: [anyOf("display_control", [1, 2, 100])],
        0x0216: [anyOf("energy_stats", [2, 3, 4, 5]), anyOf("energy_setting", [3, 5]), anyOf("energy_bcd", [2, 3])],
        0x0222: [eq("fahrenheit", 0)],
        0x0210: [anyOf("fan_silent", [6, 9]), anyOf("fan_low", [3, 4, 5, 6, 7, 9]), anyOf("fan_medium", [5, 6, 7]),
                 anyOf("fan_high", [3, 4, 5, 6, 7, 9]), anyOf("fan_auto", [4, 5, 6, 9]), eq("fan_custom", 1)],
        0x0217: [anyOf("filter_notice", [1, 2, 4]), anyOf("filter_clean", [3, 4])],
        0x0067: [anyOf("flash", [1, 2, 3, 4])],
        0x004B: [eq("fresh_air", 1)],
        0x021F: [anyOf("humidity_auto_set", [1, 2]), anyOf("humidity_manual_set", [2, 3])],
        0x0214: [anyOf("heat_mode", [1, 2, 4, 6, 7, 9, 10, 11, 12, 13]),
                 anyOf("cool_mode", [0, 1, 3, 4, 5, 6, 7, 8, 9, 11, 13, 14, 15]),
                 anyOf("dry_mode", [0, 1, 5, 6, 9, 11, 13, 14, 15]),
                 anyOf("auto_mode", [0, 1, 2, 7, 8, 9, 13, 14]),
                 eq("aux_heat_mode", 9),
                 anyOf("aux_mode", [9, 10, 11, 13, 14, 15])],
        0x00CD: [anyOf("out_silent", [1, 3])],
        0x0212: [anyOf("eco", [1, 2])],
        0x0213: [eq("freeze_protection", 1)],
        0x00E3: [Reader(name: "ieco") { $0.first.map(Double.init) },
                 Reader(name: "ieco_end") { $0.count > 1 ? Double($0[1]) : nil }],
        0x021A: [anyOf("turbo_heat", [1, 3]), anyOf("turbo_cool", [0, 1])],
        0x0048: [eq("rate_select_2_level", 1), anyOf("rate_select_5_level", [2, 3])],
        0x0039: [eq("self_clean", 1)],
        0x0030: [eq("smart_eye", 1)],
        0x000A: [eq("swing_horizontal_angle", 1)],
        0x0009: [eq("swing_vertical_angle", 1)],
        0x0215: [anyOf("swing_horizontal", [1, 3]), anyOf("swing_vertical", [0, 1])],
        0x0033: [eq("wind_off_me", 1)],
        0x0032: [eq("wind_on_me", 1)],
    ]

    init(body: [UInt8]) {
        guard body.count >= 2 else { return }
        let count = Int(body[1])
        var caps = Array(body[2...])
        for _ in 0..<count {
            if caps.count < 3 { break }
            let size = Int(caps[2])
            if size == 0 { caps = Array(caps.dropFirst(3)); continue }
            let rawId = le16(caps[0], caps[1])
            let value = Array(caps[3..<min(3 + size, caps.count)])
            if let readers = Self.readers[rawId] {
                for r in readers { if let v = r.read(value) { flags[r.name] = v } }
            } else if rawId == 0x0225 { // temperature ranges
                if size >= 6, caps.count >= 9 {
                    flags["cool_min_temperature"] = Double(caps[3]) * 0.5
                    flags["cool_max_temperature"] = Double(caps[4]) * 0.5
                    flags["auto_min_temperature"] = Double(caps[5]) * 0.5
                    flags["auto_max_temperature"] = Double(caps[6]) * 0.5
                    flags["heat_min_temperature"] = Double(caps[7]) * 0.5
                    flags["heat_max_temperature"] = Double(caps[8]) * 0.5
                    let decimals = size > 6 && caps.count > 9 ? caps[9] : caps[2]
                    flags["decimals"] = decimals != 0 ? 1 : 0
                }
            }
            caps = Array(caps.dropFirst(3 + size))
        }
        if caps.count > 1 { additionalCapabilities = caps[caps.count - 2] != 0 }
    }

    public mutating func merge(_ other: CapabilitiesResponse) {
        flags.merge(other.flags) { _, new in new }
    }

    func flag(_ name: String) -> Bool { (flags[name] ?? 0) != 0 }

    func fanSpeed(_ name: String) -> Bool {
        if flags.keys.contains(where: { $0.hasPrefix("fan_") }) {
            return flag("fan_\(name)") || flag("fan_custom")
        }
        return ["low", "medium", "high", "auto"].contains(name)
    }

    /// Fold the decoded flags into a capability description.
    public func capabilities(base: ACCapabilities = ACCapabilities()) -> ACCapabilities {
        var c = base
        c.raw = flags

        var modes: [OperationalMode] = [.fanOnly]
        if flag("dry_mode") { modes.append(.dry) }
        if flag("cool_mode") { modes.append(.cool) }
        if flag("heat_mode") { modes.append(.heat) }
        if flag("auto_mode") { modes.append(.auto) }
        if flag("humidity_manual_set") { modes.append(.smartDry) }
        c.modes = modes

        var swing: [SwingMode] = [.off]
        if flag("swing_horizontal") { swing.append(.horizontal) }
        if flag("swing_vertical") { swing.append(.vertical) }
        if flag("swing_horizontal") && flag("swing_vertical") { swing.append(.both) }
        c.swingModes = swing

        var fans: [FanSpeed] = []
        if fanSpeed("silent") { fans.append(.silent) }
        if fanSpeed("low") { fans.append(.low) }
        if fanSpeed("medium") { fans.append(.medium) }
        if fanSpeed("high") { fans.append(.high) }
        if fanSpeed("auto") { fans.append(.auto) }
        if flag("fan_custom") { fans.append(.max) }
        c.fanSpeeds = fans
        c.customFanSpeed = flag("fan_custom")

        c.eco = flag("eco")
        c.turbo = flag("turbo_heat") || flag("turbo_cool")
        c.freezeProtection = flag("freeze_protection")
        c.displayControl = flag("display_control")
        c.filterReminder = flag("filter_notice")
        c.purifier = flag("anion")

        var aux: [AuxHeatMode] = [.off]
        if flag("aux_electric_heat") || flag("aux_heat_mode") { aux.append(.auxHeat) }
        if flag("aux_mode") { aux.append(.auxOnly) }
        c.auxModes = aux

        c.minTemperature = ["cool", "auto", "heat"].map { flags["\($0)_min_temperature"] ?? 16 }.min() ?? 16
        c.maxTemperature = ["cool", "auto", "heat"].map { flags["\($0)_max_temperature"] ?? 30 }.max() ?? 30

        c.energyStats = c.energyStats || flag("energy_stats")
        c.humidity = flag("humidity_auto_set") || flag("humidity_manual_set")
        c.targetHumidity = flag("humidity_manual_set")
        c.swingVerticalAngle = flag("swing_vertical_angle")
        c.swingHorizontalAngle = flag("swing_horizontal_angle")
        c.cascade = flag("cascade")
        c.flash = flag("flash")
        c.freshAir = flag("fresh_air")
        c.selfClean = flag("self_clean")
        c.breezeControl = flag("breeze_control")
        if !c.breezeControl {
            c.breezeAway = flag("breeze_away")
            c.breezeless = flag("breezeless")
        } else {
            c.breezeAway = false
            c.breezeless = false
        }
        let ieco = Int(flags["ieco"] ?? 0), iecoEnd = Int(flags["ieco_end"] ?? 0)
        c.ieco = [1, 3, 4, 8].contains(ieco) || [1, 2, 3, 8].contains(iecoEnd)
        c.iecoNumber = iecoEnd == 8 ? 8 : ([1, 2, 3].contains(iecoEnd) ? 3 : 1)
        c.outSilent = flag("out_silent")
        c.sound = flag("sound")
        return c
    }
}

public struct PropertiesResponse: Equatable, Sendable {
    public var values: [PropertyId: Int] = [:]
    public var failed: Set<PropertyId> = []

    init(body: [UInt8]) {
        guard body.count >= 2 else { return }
        let count = Int(body[1])
        var props = Array(body[2...])
        for _ in 0..<count {
            if props.count < 4 { break }
            let size = Int(props[3])
            if size == 0 { props = Array(props.dropFirst(4)); continue }
            let rawId = le16(props[0], props[1])
            let value = props[4..<min(4 + size, props.count)]
            if let id = PropertyId(rawValue: rawId) {
                if props[2] & 0x10 != 0 { failed.insert(id) }
                if let v = id.decode(value) { values[id] = v }
            }
            props = Array(props.dropFirst(4 + size))
        }
    }
}

public struct Group5Response: Equatable, Sendable {
    public var humidity: Int?
    public var outdoorFanSpeed: Int
    public var defrost: Bool

    init(body p: [UInt8]) throws {
        guard p.count >= 11 else { throw FrameError.tooShort }
        humidity = p[4] != 0 ? Int(p[4]) : nil
        outdoorFanSpeed = Int(p[8]) * 8
        defrost = p[10] != 0
    }
}

public struct Group4Response: Equatable, Sendable {
    public var totalEnergy: Double?
    public var currentRunEnergy: Double?
    public var realTimePower: Double?

    static func bcd(_ b: UInt8) -> Double { Double(10 * Int(b >> 4) + Int(b & 0xF)) }

    init(body p: [UInt8]) throws {
        guard p.count >= 19 else { throw FrameError.tooShort }
        func energy(_ d: ArraySlice<UInt8>) -> Double {
            let a = Array(d)
            return 10000 * Self.bcd(a[0]) + 100 * Self.bcd(a[1]) + Self.bcd(a[2]) + 0.01 * Self.bcd(a[3])
        }
        let total = energy(p[4..<8])
        let current = energy(p[12..<16])
        let power = 1000 * Self.bcd(p[16]) + 10 * Self.bcd(p[17]) + 0.1 * Self.bcd(p[18])
        let valid = total != 0 || current != 0 || power != 0
        totalEnergy = valid ? total : nil
        currentRunEnergy = valid ? current : nil
        realTimePower = valid ? power : nil
    }
}

public enum ACResponse: Sendable {
    case state(StateResponse)
    case capabilities(CapabilitiesResponse)
    case properties(PropertiesResponse)
    case group4(Group4Response)
    case group5(Group5Response)
    case other(id: UInt8, body: [UInt8])

    /// Parse a raw appliance frame (`AA ... checksum`).
    public static func parse(frame: [UInt8]) throws -> ACResponse {
        try ACFrame.validate(frame)
        guard frame.count >= ACFrame.headerLength + 3 else { throw FrameError.tooShort }
        let frameType = frame[9]
        let payloadWithCRC = Array(frame[ACFrame.headerLength..<(frame.count - 1)])
        let body = Array(payloadWithCRC.dropLast())
        let id = body[0]

        let isProperties = id == 0xB1 || id == 0xB0
        if !isProperties {
            let crc = CRC8.calculate(body)
            let sum = ACFrame.checksum(body)
            let received = payloadWithCRC[payloadWithCRC.count - 1]
            guard crc == received || sum == received else { throw FrameError.badPayloadCRC }
        }

        switch id {
        case 0xC0:
            return .state(try StateResponse(body: body))
        case 0xB5 where frameType == FrameType.query.rawValue:
            return .capabilities(CapabilitiesResponse(body: body))
        case 0xB1, 0xB0:
            return .properties(PropertiesResponse(body: body))
        case 0xC1 where body.count > 3 && (body[3] & 0xF) == 4:
            return .group4(try Group4Response(body: body))
        case 0xC1 where body.count > 3 && (body[3] & 0xF) == 5:
            return .group5(try Group5Response(body: body))
        default:
            return .other(id: id, body: body)
        }
    }
}
