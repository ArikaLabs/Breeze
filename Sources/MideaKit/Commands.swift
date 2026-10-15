import Foundation

public enum FrameType: UInt8 {
    case control = 0x02
    case query = 0x03
    case report = 0x04
}

public enum FrameError: Error, Equatable {
    case tooShort
    case badChecksum(received: UInt8, expected: UInt8)
    case wrongDeviceType(UInt8)
    case badPayloadCRC
}

/// Appliance frame: `AA len AC 00 00 00 00 00 ver type | payload msgId crc8 | checksum`.
enum ACFrame {
    static let headerLength = 10
    static let deviceType: UInt8 = 0xAC

    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var sum: UInt8 = 0
        for b in bytes { sum = sum &+ b }
        return 0 &- sum
    }

    static func build(type: FrameType, payload: [UInt8], messageId: UInt8) -> [UInt8] {
        var data = payload
        data.append(messageId)
        data.append(CRC8.calculate(data))

        var frame = [UInt8](repeating: 0, count: headerLength)
        frame[0] = 0xAA
        frame[1] = UInt8(truncatingIfNeeded: data.count + headerLength)
        frame[2] = deviceType
        frame[8] = 0 // protocol version
        frame[9] = type.rawValue
        frame += data
        frame.append(checksum(frame[1...]))
        return frame
    }

    static func validate(_ frame: [UInt8]) throws {
        guard frame.count >= headerLength + 1 else { throw FrameError.tooShort }
        let expected = checksum(frame[1..<(frame.count - 1)])
        guard expected == frame[frame.count - 1] else {
            throw FrameError.badChecksum(received: frame[frame.count - 1], expected: expected)
        }
        guard frame[2] == deviceType else { throw FrameError.wrongDeviceType(frame[2]) }
    }
}

public enum PropertyId: UInt16, CaseIterable, Sendable, Codable {
    case swingUDAngle = 0x0009
    case swingLRAngle = 0x000A
    case indoorHumidity = 0x0015
    case breezeless = 0x0018
    case buzzer = 0x001A
    case selfClean = 0x0039
    case breezeAway = 0x0042
    case breezeControl = 0x0043
    case rateSelect = 0x0048
    case freshAir = 0x004B
    case cascade = 0x0059
    case flash = 0x0067
    case outSilent = 0x00CD
    case ieco = 0x00E3
    case anion = 0x021E
    case sound = 0x022C

    /// Decode raw property bytes to a plain integer (bools as 0/1). Returns nil when not decodable.
    func decode(_ data: ArraySlice<UInt8>) -> Int? {
        guard let first = data.first else { return nil }
        let second = data.dropFirst().first ?? 0
        switch self {
        case .breezeless, .flash, .selfClean, .sound: return first != 0 ? 1 : 0
        case .breezeAway: return first == 2 ? 1 : 0
        case .buzzer: return nil
        case .cascade: return first != 0 ? Int(second) : 0
        case .freshAir: return first != 0 ? Int(second) : 0
        case .ieco: return second != 0 ? 1 : 0
        case .outSilent: return first == 3 ? 1 : 0
        case .indoorHumidity, .anion: return nil
        case .swingUDAngle, .swingLRAngle, .breezeControl, .rateSelect: return Int(first)
        }
    }
}

struct SetStateParameters {
    var beep = true
    var power = false
    var targetTemperature: Double = 25
    var mode: UInt8 = 0
    var fanSpeed: UInt8 = 0
    var eco = true
    var swingMode: UInt8 = 0
    var turbo = false
    var fahrenheit = true
    var sleep = false
    var freezeProtection = false
    var followMe = false
    var purifier = false
    var targetHumidity = 40
    var auxHeat = false
    var forceAuxHeat = false
    var independentAuxHeat = false

    func payload() -> [UInt8] {
        let beepBit: UInt8 = beep ? 0x40 : 0
        let powerBit: UInt8 = power ? 0x1 : 0

        let integral = Int(targetTemperature.rounded(.towardZero))
        let fractional = targetTemperature - Double(integral)
        var temperature: UInt8
        var temperatureAlt: UInt8
        if (17...30).contains(integral) {
            temperature = UInt8((integral - 16) & 0xF)
            temperatureAlt = 0
        } else {
            temperature = 0
            temperatureAlt = UInt8((integral - 12) & 0x1F)
        }
        if fractional > 0 { temperature |= 0x10 }

        let modeBits = (mode & 0x7) << 5
        let swing: UInt8 = 0x30 | (swingMode & 0x3F)
        let ecoBit: UInt8 = eco ? 0x80 : 0
        let purifierBit: UInt8 = purifier ? 0x20 : 0
        let auxHeatBit: UInt8 = auxHeat ? 0x08 : 0
        let forceAuxBit: UInt8 = forceAuxHeat ? 0x10 : 0
        let sleepBit: UInt8 = sleep ? 0x01 : 0
        let turboBit: UInt8 = turbo ? 0x02 : 0
        let fahrenheitBit: UInt8 = fahrenheit ? 0x04 : 0
        let turboAlt: UInt8 = turbo ? 0x20 : 0
        let followMeBit: UInt8 = followMe ? 0x80 : 0
        let humidity = UInt8(targetHumidity & 0x7F)
        let freeze: UInt8 = freezeProtection ? 0x80 : 0
        let independentAux: UInt8 = independentAuxHeat ? 0x08 : 0

        return [
            0x40,
            0x02 | beepBit | powerBit,
            temperature | modeBits,
            fanSpeed,
            0x7F, 0x7F, 0x00,
            swing,
            followMeBit | turboAlt,
            ecoBit | purifierBit | forceAuxBit | auxHeatBit,
            sleepBit | turboBit | fahrenheitBit,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            temperatureAlt,
            humidity,
            0x00,
            freeze,
            independentAux,
            0x00,
        ]
    }
}

enum ACCommand {
    case getState
    case getCapabilities(additional: Bool)
    case setState(SetStateParameters)
    case toggleDisplay(beep: Bool)
    case getProperties([PropertyId])
    case setProperties([(PropertyId, [UInt8])])
    case getGroupData(UInt8)

    var frameType: FrameType {
        switch self {
        case .setState, .setProperties: return .control
        default: return .query
        }
    }

    var payload: [UInt8] {
        switch self {
        case .getState:
            return [0x41, 0x81, 0x00, 0xFF, 0x03, 0xFF, 0x00, 0x02,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x03]
        case .getCapabilities(let additional):
            return additional ? [0xB5, 0x01, 0x01, 0x01] : [0xB5, 0x01, 0x00]
        case .setState(let p):
            return p.payload()
        case .toggleDisplay(let beep):
            return [0x41, 0x02 | (beep ? 0x40 : 0), 0x00, 0xFF, 0x02, 0x00, 0x02, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        case .getProperties(let props):
            var out: [UInt8] = [0xB1, UInt8(props.count)]
            for p in props { out += [UInt8(p.rawValue & 0xFF), UInt8(p.rawValue >> 8)] }
            return out
        case .setProperties(let props):
            var out: [UInt8] = [0xB0, UInt8(props.count)]
            for (p, value) in props {
                out += [UInt8(p.rawValue & 0xFF), UInt8(p.rawValue >> 8), UInt8(value.count)]
                out += value
            }
            return out
        case .getGroupData(let group):
            var out = [UInt8](repeating: 0, count: 20)
            out[0] = 0x41; out[1] = 0x21; out[2] = 0x01; out[3] = 0x40 | group
            return out
        }
    }

    func encode(messageId: UInt8) -> [UInt8] {
        ACFrame.build(type: frameType, payload: payload, messageId: messageId)
    }
}
