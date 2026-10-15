import Foundation

/// Lightweight diagnostics hook. The app installs a handler; the library stays dependency free.
public enum MideaLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (String) -> Void)?

    public static var handler: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    static func log(_ message: @autoclosure () -> String) {
        guard let h = handler else { return }
        h(message())
    }
}
