import Foundation
import AppKit
import Security
import MideaKit

struct ConfiguredDevice: Codable, Equatable, Identifiable {
    var device: DiscoveredDevice
    var name: String
    var id: UInt64 { device.deviceId }
}

/// Which stone the app is cut from: Travertine (light), Basalt (dark), or whichever macOS is using.
enum Appearance: String, Codable, CaseIterable {
    case system, light, dark

    var label: String {
        switch self { case .system: return "System"; case .light: return "Light"; case .dark: return "Dark" }
    }
    var nsAppearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

struct AppSettings: Codable, Equatable {
    var devices: [ConfiguredDevice] = []
    var selectedDeviceId: UInt64?
    var useFahrenheit = false
    var beep = true
    var pollIntervalSeconds: Int = 300
    var appearance: Appearance = .system   // Travertine, Basalt, or whatever macOS is showing
    // Cooling suggestions driven by the Mac's own temperature sensors.
    var suggestCooling = true
    var hotMacThreshold: Double = 90
    var warmRoomThreshold: Double = 24
    var energyLogging = true

    static let key = "breeze.settings.v1"

    init() {}

    enum CodingKeys: String, CodingKey {
        case devices, selectedDeviceId, useFahrenheit, beep, pollIntervalSeconds, appearance
        case suggestCooling, hotMacThreshold, warmRoomThreshold, energyLogging
        case device, deviceName // v1 single-unit keys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = try c.decodeIfPresent([ConfiguredDevice].self, forKey: .devices) ?? []
        selectedDeviceId = try c.decodeIfPresent(UInt64.self, forKey: .selectedDeviceId)
        useFahrenheit = try c.decodeIfPresent(Bool.self, forKey: .useFahrenheit) ?? false
        beep = try c.decodeIfPresent(Bool.self, forKey: .beep) ?? true
        pollIntervalSeconds = max(60, try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        suggestCooling = try c.decodeIfPresent(Bool.self, forKey: .suggestCooling) ?? true
        hotMacThreshold = try c.decodeIfPresent(Double.self, forKey: .hotMacThreshold) ?? 90
        warmRoomThreshold = try c.decodeIfPresent(Double.self, forKey: .warmRoomThreshold) ?? 24
        energyLogging = try c.decodeIfPresent(Bool.self, forKey: .energyLogging) ?? true
        // Migrate the single-unit layout.
        if devices.isEmpty, let legacy = try c.decodeIfPresent(DiscoveredDevice.self, forKey: .device) {
            let name = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "Office"
            devices = [ConfiguredDevice(device: legacy, name: name)]
            selectedDeviceId = legacy.deviceId
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(devices, forKey: .devices)
        try c.encodeIfPresent(selectedDeviceId, forKey: .selectedDeviceId)
        try c.encode(useFahrenheit, forKey: .useFahrenheit)
        try c.encode(beep, forKey: .beep)
        try c.encode(pollIntervalSeconds, forKey: .pollIntervalSeconds)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(suggestCooling, forKey: .suggestCooling)
        try c.encode(hotMacThreshold, forKey: .hotMacThreshold)
        try c.encode(warmRoomThreshold, forKey: .warmRoomThreshold)
        try c.encode(energyLogging, forKey: .energyLogging)
    }

    static func load() -> AppSettings {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) { return s }
        return AppSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    var selectedDevice: ConfiguredDevice? {
        devices.first { $0.id == selectedDeviceId } ?? devices.first
    }
}

/// Is this process signed with a real certificate (stable across rebuilds) rather than ad hoc?
enum Signing {
    static let isStable: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        let flags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        let hasCertificates = ((dict[kSecCodeInfoCertificates as String] as? [Any])?.isEmpty == false)
        return !adhoc && hasCertificates
    }()
}

/// Device token/key storage. With a stable code signature the Keychain is used; an ad-hoc signed
/// build would re-prompt for Keychain access on every rebuild, so it falls back to a user-only
/// readable JSON file in Application Support.
enum CredentialStore {
    static var usesKeychain: Bool { Signing.isStable && ProcessInfo.processInfo.environment["BREEZE_FILE_CREDENTIALS"] == nil }
    private static let keychainService = "com.arikalabs.breeze.device"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Breeze", isDirectory: true)
    }
    static var fileURL: URL { directory.appendingPathComponent("credentials.json") }

    private static func loadAll() -> [String: DeviceCredentials] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: DeviceCredentials].self, from: data) else { return [:] }
        return dict
    }

    private static func saveAll(_ dict: [String: DeviceCredentials]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    static func credentials(for deviceId: UInt64) -> DeviceCredentials? {
        if usesKeychain {
            if let c = keychainLoad(deviceId) { return c }
            // Migrate anything still in the file.
            if let c = loadAll()[String(deviceId)] {
                if keychainSave(c, deviceId) { removeFromFile(deviceId) }
                return c
            }
            return nil
        }
        return loadAll()[String(deviceId)]
    }

    static func store(_ creds: DeviceCredentials, for deviceId: UInt64) {
        if usesKeychain, keychainSave(creds, deviceId) { return }
        var all = loadAll()
        all[String(deviceId)] = creds
        saveAll(all)
    }

    static func remove(deviceId: UInt64) {
        keychainDelete(deviceId)
        removeFromFile(deviceId)
    }

    private static func removeFromFile(_ deviceId: UInt64) {
        var all = loadAll()
        guard all.removeValue(forKey: String(deviceId)) != nil else { return }
        saveAll(all)
    }

    // MARK: Keychain

    private static func keychainQuery(_ deviceId: UInt64) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: String(deviceId)]
    }

    private static func keychainLoad(_ deviceId: UInt64) -> DeviceCredentials? {
        var query = keychainQuery(deviceId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(DeviceCredentials.self, from: data)
    }

    @discardableResult
    private static func keychainSave(_ creds: DeviceCredentials, _ deviceId: UInt64) -> Bool {
        guard let data = try? JSONEncoder().encode(creds) else { return false }
        let query = keychainQuery(deviceId)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Breeze — Midea unit \(deviceId)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func keychainDelete(_ deviceId: UInt64) {
        SecItemDelete(keychainQuery(deviceId) as CFDictionary)
    }

    /// Plain-text export for backing up in a password manager.
    static func exportText(for deviceId: UInt64) -> String? {
        guard let c = credentials(for: deviceId) else { return nil }
        return "Midea device \(deviceId)\ntoken=\(c.token)\nkey=\(c.key)\n"
    }
}
