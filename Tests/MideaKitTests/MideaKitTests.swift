import XCTest
@testable import MideaKit

/// Every vector in vectors.json was produced by the msmart-ng Python reference implementation.
/// Discovery replies, the LAN packet and the V3 encrypted request/response come from packets in msmart-ng's own
/// public test suite (test_discover.py, test_lan.py). Handshake and key-derivation inputs are synthetic values
/// run through msmart-ng; the state, capability, energy and property frames are appliance payloads with no identifiers.
final class MideaKitTests: XCTestCase {
    static let vectors: [String: Any] = {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()
    var v: [String: Any] { Self.vectors }
    func hex(_ s: Any?) -> [UInt8] { [UInt8](hex: s as! String)! }

    func testCRC8AndChecksum() {
        for c in v["crc8"] as! [[String: Any]] {
            let data = hex(c["data"])
            XCTAssertEqual(Int(CRC8.calculate(data)), c["crc"] as! Int, "crc8 of \(data.hex)")
            XCTAssertEqual(Int(ACFrame.checksum(data)), c["checksum"] as! Int, "checksum of \(data.hex)")
        }
    }

    func testCommandFrames() {
        var p = SetStateParameters()
        p.beep = true; p.power = true; p.targetTemperature = 23.5; p.mode = 2; p.fanSpeed = 102; p.eco = false
        p.swingMode = 0xC; p.turbo = false; p.fahrenheit = false; p.sleep = false; p.freezeProtection = false; p.targetHumidity = 40
        var p2 = SetStateParameters()
        p2.beep = false; p2.power = true; p2.targetTemperature = 16; p2.mode = 4; p2.fanSpeed = 60; p2.eco = true
        p2.swingMode = 0xF; p2.turbo = true; p2.fahrenheit = false; p2.sleep = true; p2.freezeProtection = true; p2.targetHumidity = 55
        let commands: [String: ACCommand] = [
            "get_state": .getState,
            "get_capabilities": .getCapabilities(additional: false),
            "get_capabilities_more": .getCapabilities(additional: true),
            "set_state_cool_23_5": .setState(p),
            "set_state_heat_16_alt": .setState(p2),
            "toggle_display_nobeep": .toggleDisplay(beep: false),
            "get_properties_flash_ieco": .getProperties([.flash, .ieco]),
            "set_properties": .setProperties([(.flash, [1]), (.ieco, [0, 8, 1] + [UInt8](repeating: 0, count: 10)), (.buzzer, [1])]),
            "get_group_5": .getGroupData(5),
        ]
        for f in v["frames"] as! [[String: Any]] {
            let name = f["name"] as! String
            guard let cmd = commands[name] else { XCTFail("missing \(name)"); continue }
            XCTAssertEqual(cmd.encode(messageId: UInt8(f["message_id"] as! Int)).hex, f["expected"] as! String, name)
        }
    }

    func testLanPacketRoundTrip() throws {
        let lp = v["lan_packet"] as! [String: Any]
        let ts = (lp["timestamp"] as! [Int]).map(UInt8.init)
        // 2026-10-13 04:05:06.07 UTC
        var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 13; comps.hour = 4; comps.minute = 5; comps.second = 6; comps.nanosecond = 70_000_000
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: comps)!
        XCTAssertEqual(LanPacket.timestampBytes(date), ts)
        let frame = hex(lp["frame"])
        let packet = try LanPacket.encode(deviceId: UInt64(lp["device_id"] as! Int), frame: frame, date: date)
        XCTAssertEqual(packet.hex, lp["expected"] as! String)
        XCTAssertEqual(try LanPacket.decode(packet), frame)
    }

    func testV3Framing() throws {
        let hs = v["v3_handshake_request"] as! [String: Any]
        var codec = V3Codec()
        XCTAssertEqual(codec.encodeHandshake(token: hex(hs["token"])).hex, hs["expected"] as! String)

        let er = v["v3_encrypted_request"] as! [String: Any]
        codec = V3Codec(); codec.packetId = 1; codec.localKey = Data(hex(er["local_key"]))
        XCTAssertEqual(try codec.encodeEncryptedRequest(hex(er["data"]), padding: hex(er["pad"])).hex, er["expected"] as! String)

        let resp = v["v3_encrypted_response"] as! [String: Any]
        codec.localKey = Data(hex(resp["local_key"]))
        XCTAssertEqual(try codec.decode(hex(resp["packet"])), .encryptedResponse(hex(resp["expected"])))

        let lk = v["v3_local_key"] as! [String: Any]
        XCTAssertEqual(try V3Codec.deriveLocalKey(key: Data(hex(lk["key"])), response: hex(lk["response"])).hex, lk["expected"] as! String)

        let hp = v["v3_handshake_response_packet"] as! [String: Any]
        XCTAssertEqual(try codec.decode(hex(hp["packet"])), .handshakeResponse(hex(hp["expected"])))
        XCTAssertEqual(try codec.decode(hex(v["v3_error_packet"])), .error)

        // Buffer splitting: two packets with a partial third.
        var buffer = hex(resp["packet"]) + hex(hp["packet"]) + [0x83, 0x70, 0x00]
        let packets = V3Codec.extractPackets(from: &buffer)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(buffer, [0x83, 0x70, 0x00])
    }

    func testDiscoveryParsing() throws {
        for d in v["discovery"] as! [[String: Any]] {
            let dev = try Discovery.parse(response: hex(d["raw"]), from: d["ip"] as! String)
            XCTAssertEqual(dev.deviceId, UInt64(d["device_id"] as! Int))
            XCTAssertEqual(Int(dev.port), d["port"] as! Int)
            XCTAssertEqual(dev.serialNumber, d["sn"] as! String)
            XCTAssertEqual(dev.name, d["name"] as! String)
            XCTAssertEqual(Int(dev.deviceType), d["type"] as! Int)
            XCTAssertEqual(dev.version, d["version"] as! Int)
        }
        for u in v["udpid"] as! [[String: Any]] {
            let id = UInt64(u["device_id"] as! Int)
            XCTAssertEqual(MideaSecurity.udpid(deviceId: id, littleEndian: true), u["little"] as! String)
            XCTAssertEqual(MideaSecurity.udpid(deviceId: id, littleEndian: false), u["big"] as! String)
        }
    }

    func testCloudCrypto() {
        let c = v["cloud"] as! [String: Any]
        XCTAssertEqual(SmartHomeCloud.sign(body: c["body"] as! String, random: c["random"] as! String), c["sign"] as! String)
        XCTAssertEqual(SmartHomeCloud.encryptPassword(loginId: c["login_id"] as! String, password: c["password"] as! String), c["encrypt_password"] as! String)
        XCTAssertEqual(SmartHomeCloud.encryptIAMPassword(loginId: c["login_id"] as! String, password: c["password"] as! String), c["encrypt_iam_password"] as! String)
    }

    func testStateResponses() throws {
        for s in v["state_responses"] as! [[String: Any]] {
            let frame = hex(s["frame"])
            guard case .state(let r) = try ACResponse.parse(frame: frame) else { XCTFail("not a state response: \(frame.hex)"); continue }
            let ctx = frame.hex
            XCTAssertEqual(r.power, s["power"] as! Bool, ctx)
            XCTAssertEqual(r.targetTemperature, s["target_temperature"] as! Double, ctx)
            XCTAssertEqual(Int(r.mode), s["mode"] as! Int, ctx)
            XCTAssertEqual(r.fanSpeed, s["fan_speed"] as! Int, ctx)
            XCTAssertEqual(Int(r.swingMode), s["swing_mode"] as! Int, ctx)
            XCTAssertEqual(r.turbo, s["turbo"] as! Bool, ctx)
            XCTAssertEqual(r.eco, s["eco"] as! Bool, ctx)
            XCTAssertEqual(r.sleep, s["sleep"] as! Bool, ctx)
            XCTAssertEqual(r.fahrenheit, s["fahrenheit"] as! Bool, ctx)
            XCTAssertEqual(r.indoorTemperature, s["indoor_temperature"] as? Double, ctx)
            XCTAssertEqual(r.outdoorTemperature, s["outdoor_temperature"] as? Double, ctx)
            XCTAssertEqual(r.displayOn, s["display_on"] as! Bool, ctx)
            XCTAssertEqual(r.filterAlert, s["filter_alert"] as! Bool, ctx)
            XCTAssertEqual(r.freezeProtection, s["freeze_protection"] as? Bool, ctx)
            XCTAssertEqual(r.targetHumidity, s["target_humidity"] as? Int, ctx)
            XCTAssertEqual(r.errorCode, s["error_code"] as! Int, ctx)
            XCTAssertEqual(r.followMe, s["follow_me"] as! Bool, ctx)
            XCTAssertEqual(r.purifier, s["purifier"] as! Bool, ctx)
        }
    }

    func testCapabilityResponses() throws {
        for c in v["capability_responses"] as! [[String: Any]] {
            let frame = hex(c["frame"])
            guard case .capabilities(let r) = try ACResponse.parse(frame: frame) else { XCTFail("not capabilities: \(frame.hex)"); continue }
            let ctx = frame.hex
            let raw = (c["raw"] as! [String: Any]).mapValues { ($0 as! NSNumber).doubleValue }
            XCTAssertEqual(r.flags, raw, ctx)
            XCTAssertEqual(r.additionalCapabilities, c["additional"] as! Bool, ctx)
            let caps = r.capabilities()
            XCTAssertEqual(caps.modes.map { Int($0.rawValue) }.sorted(), c["modes"] as! [Int], ctx)
            XCTAssertEqual(caps.fanSpeeds.map(\.rawValue).sorted(), c["fan_speeds"] as! [Int], ctx)
            XCTAssertEqual(caps.swingModes.map { Int($0.rawValue) }.sorted(), c["swing_modes"] as! [Int], ctx)
            XCTAssertEqual(caps.eco, c["eco"] as! Bool, ctx)
            XCTAssertEqual(caps.turbo, c["turbo"] as! Bool, ctx)
            XCTAssertEqual(caps.freezeProtection, c["freeze_protection"] as! Bool, ctx)
            XCTAssertEqual(caps.displayControl, c["display_control"] as! Bool, ctx)
            XCTAssertEqual(caps.flash, c["flash"] as! Bool, ctx)
            XCTAssertEqual(caps.ieco, c["ieco"] as! Bool, ctx)
            XCTAssertEqual(caps.iecoNumber, c["ieco_number"] as! Int, ctx)
            XCTAssertEqual(caps.humidity, c["humidity"] as! Bool, ctx)
            XCTAssertEqual(caps.targetHumidity, c["target_humidity"] as! Bool, ctx)
            XCTAssertEqual(caps.breezeAway || caps.breezeControl, c["breeze_away"] as! Bool, ctx)
            XCTAssertEqual(caps.breezeControl, c["breeze_control"] as! Bool, ctx)
            XCTAssertEqual(caps.breezeless || caps.breezeControl, c["breezeless"] as! Bool, ctx)
            XCTAssertEqual(caps.sound, c["sound"] as! Bool, ctx)
            XCTAssertEqual(caps.minTemperature, c["min_temperature"] as! Double, ctx)
            XCTAssertEqual(caps.maxTemperature, c["max_temperature"] as! Double, ctx)
            XCTAssertEqual(caps.swingHorizontalAngle, c["swing_horizontal_angle"] as! Bool, ctx)
            XCTAssertEqual(caps.swingVerticalAngle, c["swing_vertical_angle"] as! Bool, ctx)
            XCTAssertEqual(caps.selfClean, c["self_clean"] as! Bool, ctx)
            XCTAssertEqual(caps.purifier, c["purifier"] as! Bool, ctx)
            XCTAssertEqual(caps.filterReminder, c["filter_reminder"] as! Bool, ctx)
        }
    }

    func testEnergyResponses() throws {
        func check(_ actual: Double?, _ expected: Any?, _ ctx: String) {
            if let e = expected as? Double {
                XCTAssertNotNil(actual, ctx)
                if let a = actual { XCTAssertEqual(a, e, accuracy: 1e-9, ctx) }
            } else {
                XCTAssertNil(actual, ctx)
            }
        }
        let vectors = v["energy_responses"] as! [[String: Any]]
        XCTAssertFalse(vectors.isEmpty)
        for e in vectors {
            let frame = hex(e["frame"])
            guard case .group4(let r) = try ACResponse.parse(frame: frame) else { XCTFail("not group 4: \(frame.hex)"); continue }
            check(r.totalEnergy, e["total_energy"], frame.hex)
            check(r.currentRunEnergy, e["current_energy"], frame.hex)
            check(r.realTimePower, e["real_time_power"], frame.hex)
        }
    }

    func testPropertyResponses() throws {
        for p in v["property_responses"] as! [[String: Any]] {
            let frame = hex(p["frame"])
            guard case .properties(let r) = try ACResponse.parse(frame: frame) else { XCTFail("not properties: \(frame.hex)"); continue }
            let expected = (p["values"] as! [String: Any]).reduce(into: [PropertyId: Int]()) { acc, kv in
                if let id = PropertyId(rawValue: UInt16(kv.key)!) { acc[id] = (kv.value as! NSNumber).intValue }
            }
            XCTAssertEqual(r.values, expected, frame.hex)
        }
    }
}
