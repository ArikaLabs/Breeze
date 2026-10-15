import Foundation
import Darwin

/// Broadcast discovery of Midea appliances (UDP 6445 / 20086).
public enum Discovery {
    static let discoveryMessage: [UInt8] = [
        0x5a, 0x5a, 0x01, 0x11, 0x48, 0x00, 0x92, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x7f, 0x75, 0xbd, 0x6b, 0x3e, 0x4f, 0x8b, 0x76,
        0x2e, 0x84, 0x9c, 0x6e, 0x57, 0x8d, 0x65, 0x90,
        0x03, 0x6e, 0x9d, 0x43, 0x42, 0xa5, 0x0f, 0x1f,
        0x56, 0x9e, 0xb8, 0xec, 0x91, 0x8e, 0x92, 0xe5,
    ]
    public static let ports: [UInt16] = [6445, 20086]

    public enum ParseError: Error { case unsupportedVersion, tooShort, decryptFailed, badName }

    /// Parse a discovery reply. V3 replies are wrapped in a 0x8370 header; V2 replies start with 0x5A5A.
    public static func parse(response raw: [UInt8], from ip: String) throws -> DiscoveredDevice {
        guard raw.count > 2 else { throw ParseError.tooShort }
        var data = raw
        let version: Int
        if raw[0] == 0x83 && raw[1] == 0x70 {
            version = 3
            guard raw.count > 24 else { throw ParseError.tooShort }
            data = Array(raw[8..<(raw.count - 16)])
        } else if raw[0] == 0x5A && raw[1] == 0x5A {
            version = 2
        } else {
            throw ParseError.unsupportedVersion
        }
        guard data.count > 56 else { throw ParseError.tooShort }
        let deviceId = leUInt64(data[20..<26])
        let encrypted = Array(data[40..<(data.count - 16)])
        guard let decrypted = try? MideaSecurity.decrypt(Data(encrypted)).bytes, decrypted.count > 41 else {
            throw ParseError.decryptFailed
        }
        let reportedIP = "\(decrypted[3]).\(decrypted[2]).\(decrypted[1]).\(decrypted[0])"
        _ = reportedIP
        let port = le16(decrypted[4], decrypted[5])
        let sn = String(bytes: decrypted[8..<40], encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) ?? ""
        let nameLength = Int(decrypted[40])
        guard decrypted.count >= 41 + nameLength else { throw ParseError.badName }
        let name = String(bytes: decrypted[41..<(41 + nameLength)], encoding: .ascii) ?? ""
        let parts = name.split(separator: "_")
        let type = parts.count > 1 ? UInt8(parts[1], radix: 16) ?? 0 : 0
        return DiscoveredDevice(ip: ip, port: port, deviceId: deviceId, name: name, serialNumber: sn, deviceType: type, version: version)
    }

    /// Discover devices by broadcasting, or probe specific hosts.
    public static func scan(hosts: [String] = ["255.255.255.255"], timeout: TimeInterval = 3) async throws -> [DiscoveredDevice] {
        try await Task.detached(priority: .userInitiated) {
            try blockingScan(hosts: hosts, timeout: timeout)
        }.value
    }

    private static func blockingScan(hosts: [String], timeout: TimeInterval) throws -> [DiscoveredDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw LanError.connectFailed("socket() failed") }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { throw LanError.connectFailed("bind() failed") }

        func send(to host: String, port: UInt16) {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr(host)
            let msg = discoveryMessage
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var seen = Set<String>()
        var results: [DiscoveredDevice] = []
        var sends = 0
        var nextSend = Date()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            if sends < 3 && Date() >= nextSend {
                for host in hosts { for port in ports { send(to: host, port: port) } }
                sends += 1
                nextSend = Date().addingTimeInterval(1.0)
            }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            if n > 0 {
                let ip = String(cString: inet_ntoa(from.sin_addr))
                if !seen.contains(ip) {
                    seen.insert(ip)
                    if let dev = try? parse(response: Array(buffer[0..<n]), from: ip) {
                        results.append(dev)
                    }
                }
            }
        }
        return results.sorted { $0.ip < $1.ip }
    }
}
