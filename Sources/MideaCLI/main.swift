import Foundation
import MideaKit

// Minimal CLI mirroring msmart-ng, used to exercise MideaKit against real units.

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var pairs: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { flags[name] = argv[i + 1]; i += 1 } else { flags[name] = "true" }
            } else if let eq = a.firstIndex(of: "=") {
                pairs[String(a[..<eq])] = String(a[a.index(after: eq)...])
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
}

func usage() -> Never {
    print("""
    midea-cli discover [host] [--timeout 3]
    midea-cli token [HOST] --account EMAIL --password PASS --id DEVICE_ID
    midea-cli list --account EMAIL --password PASS
    midea-cli query [HOST] (--saved [--unit NAME] | --id ID --token HEX --key HEX) [--caps]
    midea-cli set [HOST] (--saved | --id … --token … --key …) power=on temp=23 mode=cool fan=auto swing=vertical eco=on turbo=off sleep=off ieco=on flash=off sound=on
    midea-cli display [HOST] (--saved | --id … --token … --key …)
    midea-cli monitor [HOST] (--saved | --id … --token … --key …) [--interval 30]

    --saved uses the unit and token Breeze.app has already linked (default: the selected unit).
    """)
    exit(2)
}

struct SavedUnit {
    let name: String
    let ip: String
    let port: UInt16
    let id: UInt64
    let token: String
    let key: String
}

/// Reads Breeze.app's configured units and stored credentials.
enum Saved {
    static func load(unit wanted: String?) -> SavedUnit? {
        let domains = ["com.arikalabs.breeze"]
        guard let data = domains.lazy.compactMap({ UserDefaults(suiteName: $0)?.data(forKey: "breeze.settings.v1") }).first,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var units: [(name: String, device: [String: Any])] = []
        if let devices = json["devices"] as? [[String: Any]] {
            for d in devices { if let dev = d["device"] as? [String: Any] { units.append(((d["name"] as? String) ?? "Unit", dev)) } }
        } else if let dev = json["device"] as? [String: Any] {
            units.append(((json["deviceName"] as? String) ?? "Unit", dev))
        }
        let selected = (json["selectedDeviceId"] as? NSNumber)?.uint64Value
        func deviceId(_ d: [String: Any]) -> UInt64? { (d["deviceId"] as? NSNumber)?.uint64Value }
        let pick = units.first { u in wanted.map { u.name.lowercased() == $0.lowercased() } ?? false }
            ?? units.first { selected != nil && deviceId($0.device) == selected }
            ?? units.first
        guard let p = pick, let id = deviceId(p.device), let ip = p.device["ip"] as? String else { return nil }
        let port = UInt16((p.device["port"] as? NSNumber)?.intValue ?? 6444)
        let credURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Breeze/credentials.json")
        guard let cdata = try? Data(contentsOf: credURL),
              let creds = try? JSONSerialization.jsonObject(with: cdata) as? [String: [String: String]],
              let c = creds[String(id)], let token = c["token"], let key = c["key"] else { return nil }
        return SavedUnit(name: p.name, ip: ip, port: port, id: id, token: token, key: key)
    }
}

func printJSON(_ value: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: d, as: UTF8.self))
    }
}

func encodeState(_ s: ACState) -> [String: Any] {
    [
        "power": s.power, "target_temperature": s.targetTemperature, "mode": s.mode.name,
        "fan_speed": s.fanSpeed, "swing": s.swingMode.name, "eco": s.eco, "turbo": s.turbo, "sleep": s.sleep,
        "freeze_protection": s.freezeProtection, "display_on": s.displayOn, "sound": s.sound,
        "indoor_temperature": s.indoorTemperature as Any, "outdoor_temperature": s.outdoorTemperature as Any,
        "indoor_humidity": s.indoorHumidity as Any, "flash": s.flash, "ieco": s.ieco,
        "breeze": s.breezeMode.rawValue, "error_code": s.errorCode, "filter_alert": s.filterAlert,
        "power_w": s.realTimePower as Any, "total_kwh": s.totalEnergy as Any, "run_kwh": s.currentRunEnergy as Any,
    ]
}

func makeDevice(_ args: Args) async throws -> AirConditioner {
    let host = args.positional.count >= 2 ? args.positional[1] : nil
    if args.flags["saved"] != nil {
        guard let unit = Saved.load(unit: args.flags["unit"]) else {
            fputs("No linked unit found. Link one in Breeze.app first (or pass --id/--token/--key).\n", stderr)
            exit(1)
        }
        fputs("using \(unit.name) at \(host ?? unit.ip)\n", stderr)
        let dev = AirConditioner(ip: host ?? unit.ip, port: unit.port, id: unit.id)
        try await dev.setCredentials(tokenHex: unit.token, keyHex: unit.key)
        return dev
    }
    guard let host, let idStr = args.flags["id"], let id = UInt64(idStr),
          let token = args.flags["token"], let key = args.flags["key"] else { usage() }
    let dev = AirConditioner(ip: host, id: id)
    try await dev.setCredentials(tokenHex: token, keyHex: key)
    return dev
}

let args = Args(Array(CommandLine.arguments.dropFirst()))
guard let command = args.positional.first else { usage() }

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        switch command {
        case "discover":
            let hosts = args.positional.count > 1 ? [args.positional[1]] : ["255.255.255.255"]
            let timeout = Double(args.flags["timeout"] ?? "3") ?? 3
            let devices = try await Discovery.scan(hosts: hosts, timeout: timeout)
            if devices.isEmpty { print("No devices found.") }
            for d in devices {
                print("\(d.ip):\(d.port)  id=\(d.deviceId)  type=0x\(String(d.deviceType, radix: 16, uppercase: true))  v\(d.version)  name=\(d.name)  sn=\(d.serialNumber)")
            }
        case "token":
            guard let a = args.flags["account"], let p = args.flags["password"], let idStr = args.flags["id"], let id = UInt64(idStr) else { usage() }
            let cloud = SmartHomeCloud(account: a, password: p)
            let candidates = try await cloud.fetchCredentialCandidates(deviceId: id)
            if args.positional.count > 1 {
                // Verify against the unit and print only the working pair.
                let dev = AirConditioner(ip: args.positional[1], id: id)
                let creds = try await dev.authenticate(trying: candidates)
                await dev.disconnect()
                print("token=\(creds.token)\nkey=\(creds.key)\nverified=true")
            } else {
                for (i, c) in candidates.enumerated() {
                    print("candidate \(i + 1) (\(i == 0 ? "little" : "big")-endian udpid):\ntoken=\(c.token)\nkey=\(c.key)")
                }
                print("Add the unit's IP as the first argument to verify which one the unit accepts.")
            }
        case "list":
            guard let a = args.flags["account"], let p = args.flags["password"] else { usage() }
            let cloud = SmartHomeCloud(account: a, password: p)
            for app in try await cloud.listAppliances() {
                print("\(app.id)  \(app.name)  type=0x\(String(app.type, radix: 16, uppercase: true))  online=\(app.online)  room=\(app.room ?? "-")")
            }
        case "query":
            let dev = try await makeDevice(args)
            try await dev.authenticate()
            if args.flags["caps"] != nil {
                try await dev.getCapabilities()
                let c = await dev.capabilities
                print("capabilities:")
                printJSON([
                    "modes": c.modes.map(\.name), "fan_speeds": c.fanSpeeds.map(\.name), "custom_fan": c.customFanSpeed,
                    "swing_modes": c.swingModes.map(\.name), "eco": c.eco, "turbo": c.turbo, "freeze_protection": c.freezeProtection,
                    "display_control": c.displayControl, "humidity": c.humidity, "target_humidity": c.targetHumidity,
                    "flash": c.flash, "ieco": c.ieco, "ieco_number": c.iecoNumber, "breeze_away": c.breezeAway,
                    "breeze_control": c.breezeControl, "breezeless": c.breezeless, "sound": c.sound,
                    "swing_angles": [c.swingHorizontalAngle, c.swingVerticalAngle], "self_clean": c.selfClean,
                    "min_temperature": c.minTemperature, "max_temperature": c.maxTemperature, "raw": c.raw,
                ])
            }
            let s = try await dev.refresh()
            print("state:")
            printJSON(encodeState(s))
            await dev.disconnect()
        case "set":
            let dev = try await makeDevice(args)
            try await dev.authenticate()
            try await dev.getCapabilities()
            var s = try await dev.refresh()
            func onoff(_ v: String) -> Bool { ["on", "true", "1", "yes"].contains(v.lowercased()) }
            for (k, v) in args.pairs {
                switch k {
                case "power": s.power = onoff(v)
                case "temp", "target_temperature": s.targetTemperature = Double(v) ?? s.targetTemperature
                case "mode": s.mode = OperationalMode.allCases.first { $0.name.lowercased() == v.lowercased() } ?? s.mode
                case "fan": s.fanSpeed = Int(v) ?? FanSpeed.allCases.first { $0.name.lowercased() == v.lowercased() }?.rawValue ?? s.fanSpeed
                case "swing": s.swingMode = SwingMode.allCases.first { $0.name.lowercased() == v.lowercased() } ?? s.swingMode
                case "eco": s.eco = onoff(v)
                case "turbo": s.turbo = onoff(v)
                case "sleep": s.sleep = onoff(v)
                case "ieco": s.ieco = onoff(v)
                case "flash": s.flash = onoff(v)
                case "sound", "beep": s.sound = onoff(v)
                case "fahrenheit": s.fahrenheit = onoff(v)
                default: print("unknown key \(k)")
                }
            }
            let result = try await dev.apply(s)
            printJSON(encodeState(result))
            await dev.disconnect()
        case "display":
            let dev = try await makeDevice(args)
            try await dev.authenticate()
            try await dev.toggleDisplay()
            printJSON(encodeState(await dev.state))
            await dev.disconnect()
        case "monitor":
            let dev = try await makeDevice(args)
            try await dev.authenticate()
            try await dev.getCapabilities()
            var last = try await dev.refresh()
            printJSON(encodeState(last))
            await dev.setStateObserver { s in
                print("\(Date()) unsolicited report:")
                printJSON(encodeState(s))
            }
            let interval = Double(args.flags["interval"] ?? "30") ?? 30
            while true {
                try await Task.sleep(for: .seconds(interval))
                if let s = try? await dev.refresh(), s != last {
                    last = s
                    print("\(Date()) changed:")
                    printJSON(encodeState(s))
                }
            }
        default:
            usage()
        }
    } catch {
        fputs("error: \(error)\n", stderr)
        if let c = error as? CloudError { fputs("\(c.localizedDescription)\n", stderr) }
        exitCode = 1
    }
    semaphore.signal()
}
semaphore.wait()
exit(exitCode)
