import Foundation

public enum LanError: Error, Equatable {
    case timeout
    case connectFailed(String)
    case connectionClosed
    case notConnected
    case missingCredentials
    case protocolError(String)
    case authenticationFailed(String)
    case deviceRejected   // 0x8370 error frame, typically a bad token/key
}

/// V2 LAN packet: 40 byte header + AES-ECB encrypted frame + 16 byte MD5 sign.
enum LanPacket {
    static func timestampBytes(_ date: Date = Date()) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let year = c.year ?? 2000
        return [
            UInt8((c.nanosecond ?? 0) / 10_000_000),
            UInt8(c.second ?? 0), UInt8(c.minute ?? 0), UInt8(c.hour ?? 0),
            UInt8(c.day ?? 1), UInt8(c.month ?? 1),
            UInt8(year % 100), UInt8(year / 100),
        ]
    }

    static func encode(deviceId: UInt64, frame: [UInt8], date: Date = Date()) throws -> [UInt8] {
        let encrypted = try MideaSecurity.encrypt(Data(frame)).bytes
        let length = 40 + encrypted.count + 16
        var header: [UInt8] = [0x5A, 0x5A, 0x01, 0x11]
        header += [UInt8(length & 0xFF), UInt8(length >> 8)]
        header += [0x20, 0x00]
        header += [0, 0, 0, 0]
        header += timestampBytes(date)
        header += leBytes(deviceId, count: 8)
        header += [UInt8](repeating: 0, count: 12)
        let packet = header + encrypted
        return packet + MideaSecurity.sign(Data(packet)).bytes
    }

    static func decode(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 6 else { throw LanError.protocolError("Packet too short: \(data.hex)") }
        guard data[0] == 0x5A, data[1] == 0x5A else { throw LanError.protocolError("Unsupported packet: \(data.hex)") }
        let length = Int(le16(data[4], data[5]))
        guard data.count >= length, length > 56 else { throw LanError.protocolError("Truncated packet, expected \(length) have \(data.count)") }
        let packet = Array(data[0..<length])
        let encrypted = Array(packet[40..<(length - 16)])
        let rxHash = Array(packet[(length - 16)...])
        guard MideaSecurity.sign(Data(packet[0..<(length - 16)])).bytes == rxHash else {
            throw LanError.protocolError("Packet MD5 mismatch")
        }
        return try MideaSecurity.decrypt(Data(encrypted)).bytes
    }
}

/// V3 "0x8370" framing that wraps LAN packets with a session key.
struct V3Codec {
    enum PacketType: UInt8 {
        case handshakeRequest = 0x0
        case handshakeResponse = 0x1
        case encryptedResponse = 0x3
        case encryptedRequest = 0x6
        case error = 0xF
    }

    enum Message: Equatable {
        case handshakeResponse([UInt8])
        case encryptedResponse([UInt8])
        case error
    }

    var packetId: UInt16 = 0
    var localKey: Data?

    private static func header(length: Int, extra: UInt8) -> [UInt8] {
        [0x83, 0x70, UInt8(length >> 8), UInt8(length & 0xFF), 0x20, extra]
    }

    private mutating func nextPacketId() -> [UInt8] {
        let id = packetId
        packetId = (packetId &+ 1) & 0xFFF
        return [UInt8(id >> 8), UInt8(id & 0xFF)]
    }

    mutating func encodeHandshake(token: [UInt8]) -> [UInt8] {
        let header = Self.header(length: token.count, extra: PacketType.handshakeRequest.rawValue)
        return header + nextPacketId() + token
    }

    mutating func encodeEncryptedRequest(_ data: [UInt8], padding: [UInt8]? = nil) throws -> [UInt8] {
        guard let localKey else { throw LanError.notConnected }
        let remainder = (data.count + 2) % 16
        let pad = remainder != 0 ? 16 - remainder : 0
        let length = data.count + pad + 32
        let header = Self.header(length: length, extra: UInt8(pad << 4) | PacketType.encryptedRequest.rawValue)
        let padBytes = padding ?? Crypto.randomBytes(pad).bytes
        precondition(padBytes.count == pad)
        let payload = nextPacketId() + data + padBytes
        let hash = Crypto.sha256(Data(header + payload)).bytes
        let encrypted = try Crypto.aesCBCEncryptZeroIV(key: localKey, data: Data(payload)).bytes
        return header + encrypted + hash
    }

    /// Pull complete 0x8370 packets off a receive buffer.
    static func extractPackets(from buffer: inout [UInt8]) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        while !buffer.isEmpty {
            guard let start = buffer.indices.first(where: { $0 + 1 < buffer.count && buffer[$0] == 0x83 && buffer[$0 + 1] == 0x70 }) else {
                return packets
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 6 else { return packets }
            let total = Int(be16(buffer[2], buffer[3])) + 8
            guard buffer.count >= total else { return packets }
            packets.append(Array(buffer[0..<total]))
            buffer.removeFirst(total)
        }
        return packets
    }

    func decode(_ packet: [UInt8]) throws -> Message {
        guard packet.count >= 6, packet[0] == 0x83, packet[1] == 0x70 else {
            throw LanError.protocolError("Invalid start of packet")
        }
        guard packet[4] == 0x20 else { throw LanError.protocolError(String(format: "Invalid magic byte 0x%02X", packet[4])) }
        let type = packet[5] & 0xF
        switch PacketType(rawValue: type) {
        case .encryptedResponse:
            guard let localKey else { throw LanError.notConnected }
            guard packet.count > 6 + 32 else { throw LanError.protocolError("Short encrypted response") }
            let header = Array(packet[0..<6])
            let payload = Array(packet[6..<(packet.count - 32)])
            let rxHash = Array(packet[(packet.count - 32)...])
            let decrypted = try Crypto.aesCBCDecryptZeroIV(key: localKey, data: Data(payload)).bytes
            guard Crypto.sha256(Data(header + decrypted)).bytes == rxHash else {
                throw LanError.protocolError("SHA256 mismatch on encrypted response")
            }
            let pad = Int(header[5] >> 4)
            guard decrypted.count >= 2 + pad else { throw LanError.protocolError("Bad padding") }
            return .encryptedResponse(Array(decrypted[2..<(decrypted.count - pad)]))
        case .handshakeResponse:
            guard packet.count >= 8 else { throw LanError.protocolError("Short handshake response") }
            return .handshakeResponse(Array(packet[8...]))
        case .error:
            return .error
        default:
            throw LanError.protocolError("Unexpected packet type \(type)")
        }
    }

    /// Derive the session key from the handshake response and the cloud key.
    static func deriveLocalKey(key: Data, response: [UInt8]) throws -> Data {
        guard response.count == 64 else { throw LanError.authenticationFailed("Invalid handshake length \(response.count)") }
        let payload = Data(response[0..<32])
        let rxHash = Array(response[32..<64])
        let decrypted = try Crypto.aesCBCDecryptZeroIV(key: key, data: payload)
        guard Crypto.sha256(decrypted).bytes == rxHash else {
            throw LanError.authenticationFailed("Handshake digest mismatch (wrong key?)")
        }
        return Crypto.xor(decrypted, key)
    }
}
