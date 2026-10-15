import Foundation
import os

/// Unified-log output plus an in-memory ring buffer for "Copy diagnostics".
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    private let logger = Logger(subsystem: "com.arikalabs.breeze", category: "app")
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity = 800

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(Self.formatter.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
    }

    func recentLines() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

func breezeLog(_ message: String) { Diagnostics.shared.log(message) }
