import Foundation
import Combine

struct ThermalSample: Equatable {
    var date: Date
    /// Hottest CPU/SoC die sensor, °C.
    var socTemperature: Double?
    var hottestName: String?
    var hottestValue: Double?
    var thermalState: ProcessInfo.ThermalState

    var displayTemperature: Double? { socTemperature ?? hottestValue }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

/// Reads the Mac's temperature sensors through IOKit's HID event system. This is the same
/// source `powermetrics` uses, but it needs no root. The functions are private, so they are
/// resolved at runtime and the reader degrades to "no sensors" if they ever disappear.
final class SensorReader: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let temperatureEventType: Int64 = 15

    private let lock = NSLock()
    private var client: CFTypeRef?
    private var services: [CFTypeRef] = []
    private var copyProperty: CopyPropertyFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        // Usage page 0xff00 / usage 5 = Apple temperature sensors.
        setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = copyServices(client)?.takeRetainedValue() as [AnyObject]? ?? []
        self.client = client
        self.services = list.map { $0 as CFTypeRef }
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    var isAvailable: Bool { !services.isEmpty }

    func readAll() -> [(name: String, value: Double)] {
        lock.lock(); defer { lock.unlock() }
        guard let copyProperty, let copyEvent, let getFloat else { return [] }
        var rows: [(String, Double)] = []
        for service in services {
            guard let event = copyEvent(service, Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloat(event, Int32(Self.temperatureEventType << 16))
            guard value > -40, value < 150 else { continue }
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? "sensor"
            rows.append((name, value))
        }
        return rows
    }

    /// The hottest CPU/SoC die reading. Apple Silicon reports "PMU tdie*"; Intel Macs report "CPU"-style names.
    static func socTemperature(from rows: [(name: String, value: Double)]) -> Double? {
        let keys = ["tdie", "cpu", "soc", "pacc", "eacc", "pmgr"]
        let soc = rows.filter { row in keys.contains { row.name.lowercased().contains($0) } }
        return soc.map(\.value).max()
    }
}

@MainActor
final class ThermalMonitor: ObservableObject {
    @Published private(set) var sample: ThermalSample?
    @Published private(set) var isHot = false

    /// Temperature at which the Mac counts as hot. Clears `hysteresis` degrees lower.
    var hotThreshold: Double = 90
    var hysteresis: Double = 8
    /// How long the temperature must stay above the threshold (pressure "serious" counts immediately).
    var sustain: TimeInterval = 60

    private let reader = SensorReader()
    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var hotSince: Date?

    var sensorsAvailable: Bool { reader.isAvailable }

    func start(interval: TimeInterval = 30) {
        stop()
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sampleNow() }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleNow()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func sampleNow() async {
        let reader = self.reader
        let rows = await Task.detached(priority: .utility) { reader.readAll() }.value
        let hottest = rows.max { $0.value < $1.value }
        let s = ThermalSample(date: Date(),
                              socTemperature: SensorReader.socTemperature(from: rows),
                              hottestName: hottest?.name,
                              hottestValue: hottest?.value,
                              thermalState: ProcessInfo.processInfo.thermalState)
        sample = s
        evaluate(s)
    }

    private func evaluate(_ s: ThermalSample) {
        let temperature = s.displayTemperature ?? 0
        let pressure = s.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if pressure || temperature >= hotThreshold {
            let since = hotSince ?? s.date
            hotSince = since
            if pressure || s.date.timeIntervalSince(since) >= sustain { isHot = true }
        } else if temperature <= hotThreshold - hysteresis,
                  s.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue {
            hotSince = nil
            isHot = false
        }
    }
}
