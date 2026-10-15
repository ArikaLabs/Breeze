import Foundation

/// Fixed keys and helpers shared by the Midea LAN protocol.
public enum MideaSecurity {
    static let signKey = Data("xhdiwjnchekd4d512chdjx5d8e4c394D2D7S".utf8)
    static let encKey = Crypto.md5(signKey)   // 16 bytes -> AES-128

    /// Encrypt a frame for transport inside a LAN packet (AES-128-ECB, PKCS7).
    static func encrypt(_ data: Data) throws -> Data { try Crypto.aesECBEncrypt(key: encKey, data: data) }
    static func decrypt(_ data: Data) throws -> Data { try Crypto.aesECBDecrypt(key: encKey, data: data) }

    /// MD5 signature appended to LAN packets.
    static func sign(_ data: Data) -> Data { Crypto.md5(data + signKey) }

    /// The "udpid" the cloud uses to identify a device when issuing tokens.
    public static func udpid(deviceIdBytes: Data) -> Data {
        let h = Crypto.sha256(deviceIdBytes)
        return Crypto.xor(h.prefix(16), h.suffix(16))
    }

    /// Hex udpid for a numeric device ID. The cloud accepts the ID encoded either way,
    /// so callers try little endian first and big endian second.
    public static func udpid(deviceId: UInt64, littleEndian: Bool) -> String {
        let bytes = littleEndian ? leBytes(deviceId, count: 6) : beBytes(deviceId, count: 6)
        return udpid(deviceIdBytes: Data(bytes)).hex
    }
}

/// CRC-8 used by appliance payloads (Dallas/Maxim polynomial, table identical to the reference "CRC8-854" table).
enum CRC8 {
    static let table: [UInt8] = (0..<256).map { i -> UInt8 in
        var crc = UInt8(i)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1 }
        return crc
    }

    static func calculate<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0
        for b in bytes { crc = table[Int(crc ^ b)] }
        return crc
    }
}
