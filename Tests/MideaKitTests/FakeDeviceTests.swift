import XCTest
import Network
@testable import MideaKit

/// An in-process stand-in for a V3 Midea unit: real 0x8370 handshake and framing,
/// real LAN packet crypto, and a small canned appliance behind it.
final class FakeMideaDevice: @unchecked Sendable {
    struct State: Equatable {
        var power = true
        var temperature = 23.0
        var mode: UInt8 = 2
        var fan: UInt8 = 102
        var swing: UInt8 = 0
        var eco = false
        var indoor = 24.0
        var humidity: UInt8 = 45
    }

    let token: [UInt8]
    let key: Data
    let deviceId: UInt64
    private(set) var port: UInt16 = 0

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.midea")
    private var connections: [NWConnection] = []
    private var sessions: [ObjectIdentifier: (localKey: Data, packetId: UInt16)] = [:]
    private var state = State()
    private var dropRequests = false
    private var payloads: [[UInt8]] = []

    init(token: [UInt8], key: Data, deviceId: UInt64) throws {
        self.token = token
        self.key = key
        self.deviceId = deviceId
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    deinit { listener.cancel() }

    // MARK: Test controls

    func currentState() -> State { queue.sync { state } }
    func setState(_ s: State) { queue.sync { state = s } }
    func setDropRequests(_ drop: Bool) { queue.sync { dropRequests = drop } }
    func receivedPayloads() -> [[UInt8]] { queue.sync { payloads } }

    func closeAll() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            sessions.removeAll()
        }
    }

    /// Push an unsolicited state report to every authenticated connection.
    func pushState() {
        queue.sync {
            for c in connections where sessions[ObjectIdentifier(c)] != nil {
                sendEncrypted(frame: stateFrame(), on: c)
            }
        }
    }

    // MARK: Connections

    private func accept(_ c: NWConnection) {
        connections.append(c)
        var buffer: [UInt8] = []
        func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    buffer += [UInt8](data)
                    for p in V3Codec.extractPackets(from: &buffer) { self.handle(packet: p, on: c) }
                }
                if error == nil, !complete { receive() }
            }
        }
        c.start(queue: queue)
        receive()
    }

    private func send(raw: [UInt8], on c: NWConnection) {
        c.send(content: Data(raw), completion: .contentProcessed { _ in })
    }

    private func handle(packet: [UInt8], on c: NWConnection) {
        let type = packet[5] & 0xF
        let id = ObjectIdentifier(c)
        if type == 0 { // handshake
            let presented = Array(packet[8...])
            guard presented == token else {
                send(raw: [0x83, 0x70, 0x00, 0x08, 0x20, 0x0F] + [UInt8](repeating: 0, count: 8), on: c)
                return
            }
            let plain = Crypto.randomBytes(32)
            let encrypted = [UInt8](try! Crypto.aesCBCEncryptZeroIV(key: key, data: plain))
            let body = encrypted + [UInt8](Crypto.sha256(plain))
            sessions[id] = (Crypto.xor(plain, key), 0)
            send(raw: [0x83, 0x70, 0x00, 0x40, 0x20, 0x01, 0x00, 0x00] + body, on: c)
            return
        }
        guard type == 6, let session = sessions[id], packet.count > 38 else { return }
        let header = Array(packet[0..<6])
        let encrypted = Data(packet[6..<(packet.count - 32)])
        guard let decryptedData = try? Crypto.aesCBCDecryptZeroIV(key: session.localKey, data: encrypted) else { return }
        let decrypted = [UInt8](decryptedData)
        let pad = Int(header[5] >> 4)
        let lanPacket = Array(decrypted[2..<(decrypted.count - pad)])
        // A real unit ignores packets addressed to another device id (LAN header bytes 20..<28, little endian).
        guard lanPacket.count >= 28 else { return }
        let addressed = lanPacket[20..<28].enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
        guard addressed == deviceId else { return }
        guard let frame = try? LanPacket.decode(lanPacket), frame.count > 13 else { return }
        // Command frame: header(10) + payload + messageId + crc8 + checksum
        let payload = Array(frame[10..<(frame.count - 3)])
        payloads.append(payload)
        if dropRequests { return }

        var reply: [UInt8]?
        switch payload[0] {
        case 0x41 where payload.count > 3 && payload[1] == 0x21:
            let group = payload[3] & 0xF
            reply = group == 4 ? energyFrame() : (group == 5 ? humidityFrame() : nil)
        case 0x41:
            reply = stateFrame()
        case 0xB5:
            reply = capabilitiesFrame()
        case 0x40:
            applySetState(payload)
            reply = stateFrame()
        case 0xB1:
            reply = propertiesFrame(payload, ack: false)
        case 0xB0:
            reply = propertiesFrame(payload, ack: true)
        default:
            reply = nil
        }
        if let reply { sendEncrypted(frame: reply, on: c) }
    }

    private func sendEncrypted(frame: [UInt8], on c: NWConnection) {
        let id = ObjectIdentifier(c)
        guard var session = sessions[id] else { return }
        let lanPacket = try! LanPacket.encode(deviceId: deviceId, frame: frame)
        let pid = session.packetId
        session.packetId &+= 1
        sessions[id] = session
        let remainder = (lanPacket.count + 2) % 16
        let pad = remainder != 0 ? 16 - remainder : 0
        let length = lanPacket.count + pad + 32
        let header: [UInt8] = [0x83, 0x70, UInt8(length >> 8), UInt8(length & 0xFF), 0x20, UInt8(pad << 4) | 0x3]
        let payload = [UInt8(pid >> 8), UInt8(pid & 0xFF)] + lanPacket + [UInt8](repeating: 0, count: pad)
        let hash = [UInt8](Crypto.sha256(Data(header + payload)))
        let encrypted = [UInt8](try! Crypto.aesCBCEncryptZeroIV(key: session.localKey, data: Data(payload)))
        send(raw: header + encrypted + hash, on: c)
    }

    // MARK: Appliance behaviour

    private func responseFrame(type: UInt8, body: [UInt8]) -> [UInt8] {
        let data = body + [CRC8.calculate(body)]
        var frame: [UInt8] = [0xAA, UInt8(data.count + 10), 0xAC, 0, 0, 0, 0, 0, 0, type]
        frame += data
        frame.append(ACFrame.checksum(frame[1...]))
        return frame
    }

    private func stateFrame() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 22)
        b[0] = 0xC0
        b[1] = state.power ? 1 : 0
        let whole = Int(state.temperature)
        b[2] = UInt8((state.mode & 7) << 5) | UInt8((whole - 16) & 0xF) | (state.temperature - Double(whole) > 0 ? 0x10 : 0)
        b[3] = state.fan
        b[4] = 0x7F; b[5] = 0x7F
        b[7] = state.swing & 0xF
        b[9] = state.eco ? 0x10 : 0
        b[11] = UInt8(Int(state.indoor * 2) + 50)
        b[12] = 0xFF
        b[14] = 0x00 // display on
        b[19] = state.humidity
        return responseFrame(type: 0x03, body: b)
    }

    private func applySetState(_ p: [UInt8]) {
        guard p.count >= 20 else { return }
        state.power = (p[1] & 0x1) != 0
        let alt = Int(p[18] & 0x1F)
        var temp = alt != 0 ? Double(alt + 12) : Double(Int(p[2] & 0xF) + 16)
        if p[2] & 0x10 != 0 { temp += 0.5 }
        state.temperature = temp
        state.mode = (p[2] >> 5) & 0x7
        state.fan = p[3]
        state.swing = p[7] & 0xF
        state.eco = (p[9] & 0x80) != 0
    }

    private func capabilitiesFrame() -> [UInt8] {
        let body: [UInt8] = [0xB5, 6,
                             0x14, 0x02, 1, 1,   // modes: all
                             0x10, 0x02, 1, 1,   // fan: custom
                             0x12, 0x02, 1, 1,   // eco
                             0x1A, 0x02, 1, 1,   // turbo
                             0x15, 0x02, 1, 1,   // swing: both
                             0x16, 0x02, 1, 2,   // energy stats
                             0x00, 0x00]
        return responseFrame(type: 0x03, body: body)
    }

    private func energyFrame() -> [UInt8] {
        // total 1234.56 kWh, current run 5.00 kWh, 850 W
        let body: [UInt8] = [0xC1, 0, 0, 0x44, 0x00, 0x12, 0x34, 0x56, 0, 0, 0, 0, 0x00, 0x00, 0x05, 0x00, 0x00, 0x85, 0x00]
        return responseFrame(type: 0x03, body: body)
    }

    private func humidityFrame() -> [UInt8] {
        let body: [UInt8] = [0xC1, 0, 0, 0x45, state.humidity, 0, 0, 0, 10, 0, 0]
        return responseFrame(type: 0x03, body: body)
    }

    private func propertiesFrame(_ request: [UInt8], ack: Bool) -> [UInt8] {
        var body: [UInt8] = [ack ? 0xB0 : 0xB1, request[1]]
        var i = 2
        for _ in 0..<Int(request[1]) {
            guard i + 1 < request.count else { break }
            let lo = request[i], hi = request[i + 1]
            var value: UInt8 = 0
            if ack {
                let size = Int(request[i + 2])
                value = size > 0 && i + 3 < request.count ? request[i + 3] : 0
                i += 3 + size
            } else {
                i += 2
            }
            body += [lo, hi, 0x00, 1, value]
        }
        return responseFrame(type: ack ? 0x02 : 0x03, body: body)
    }
}

final class FakeDeviceTests: XCTestCase {
    static let token = [UInt8](repeating: 0xAB, count: 64)
    static let key = Data((0..<32).map { UInt8($0 * 7 + 1) })
    static let deviceId: UInt64 = 0x1234_5678_9ABC   // any 48-bit value; the fake unit answers only to this id

    private func makeClient(_ fake: FakeMideaDevice, token: [UInt8]? = nil) async -> AirConditioner {
        let ac = AirConditioner(ip: "127.0.0.1", port: fake.port, id: fake.deviceId)
        await ac.setCredentials(token: Data(token ?? Self.token), key: Self.key)
        return ac
    }

    func testAuthenticateCapabilitiesAndRefresh() async throws {
        let fake = try FakeMideaDevice(token: Self.token, key: Self.key, deviceId: Self.deviceId)
        XCTAssertGreaterThan(fake.port, 0)
        let ac = await makeClient(fake)
        try await ac.authenticate()
        try await ac.getCapabilities()
        let caps = await ac.capabilities
        XCTAssertTrue(caps.modes.contains(.cool))
        XCTAssertTrue(caps.modes.contains(.heat))
        XCTAssertTrue(caps.eco)
        XCTAssertTrue(caps.turbo)
        XCTAssertTrue(caps.energyStats)
        XCTAssertEqual(caps.swingModes, [.off, .horizontal, .vertical, .both])
        let state = try await ac.refresh()
        XCTAssertTrue(state.power)
        XCTAssertEqual(state.targetTemperature, 23)
        XCTAssertEqual(state.mode, .cool)
        XCTAssertEqual(state.indoorTemperature, 24)
        XCTAssertEqual(state.realTimePower, 850)
        XCTAssertEqual(state.totalEnergy ?? 0, 1234.56, accuracy: 0.001)
        await ac.disconnect()
    }

    func testWrongTokenIsRejected() async throws {
        let fake = try FakeMideaDevice(token: Self.token, key: Self.key, deviceId: Self.deviceId)
        let ac = await makeClient(fake, token: [UInt8](repeating: 0x11, count: 64))
        do {
            try await ac.authenticate()
            XCTFail("expected rejection")
        } catch let error as LanError {
            XCTAssertEqual(error, .deviceRejected)
        }
    }

    func testApplyChangesDeviceState() async throws {
        let fake = try FakeMideaDevice(token: Self.token, key: Self.key, deviceId: Self.deviceId)
        let ac = await makeClient(fake)
        try await ac.authenticate()
        try await ac.getCapabilities()
        var desired = try await ac.refresh()
        desired.power = false
        desired.targetTemperature = 25.5
        desired.mode = .heat
        desired.fanSpeed = 60
        desired.swingMode = .both
        desired.eco = true
        let reported = try await ac.apply(desired)
        XCTAssertFalse(reported.power)
        XCTAssertEqual(reported.targetTemperature, 25.5)
        XCTAssertEqual(reported.mode, .heat)
        XCTAssertEqual(reported.fanSpeed, 60)
        XCTAssertEqual(reported.swingMode, .both)
        XCTAssertTrue(reported.eco)
        let device = fake.currentState()
        XCTAssertFalse(device.power)
        XCTAssertEqual(device.temperature, 25.5)
        XCTAssertEqual(device.mode, 4)
        await ac.disconnect()
    }

    func testUnsolicitedReportReachesObserver() async throws {
        let fake = try FakeMideaDevice(token: Self.token, key: Self.key, deviceId: Self.deviceId)
        let ac = await makeClient(fake)
        let expectation = XCTestExpectation(description: "observer")
        expectation.assertForOverFulfill = false
        await ac.setStateObserver { state in
            if state.targetTemperature == 19 { expectation.fulfill() }
        }
        try await ac.authenticate()
        _ = try await ac.refresh()
        var s = fake.currentState()
        s.temperature = 19
        fake.setState(s)
        fake.pushState()
        await fulfillment(of: [expectation], timeout: 3)
        let latest = await ac.state
        XCTAssertEqual(latest.targetTemperature, 19)
        await ac.disconnect()
    }

    func testReconnectsAfterDeviceClosesConnection() async throws {
        let fake = try FakeMideaDevice(token: Self.token, key: Self.key, deviceId: Self.deviceId)
        let ac = await makeClient(fake)
        try await ac.authenticate()
        _ = try await ac.refresh()
        fake.closeAll()
        try await Task.sleep(for: .milliseconds(300))
        let state = try await ac.refresh()
        XCTAssertEqual(state.targetTemperature, 23)
        await ac.disconnect()
    }

    func testTimesOutWhenDeviceStaysSilent() async throws {
        let fake = try FakeMideaDevice(token: Self.token, key: Self.key, deviceId: Self.deviceId)
        let ac = await makeClient(fake)
        try await ac.authenticate()
        fake.setDropRequests(true)
        do {
            _ = try await ac.refresh()
            XCTFail("expected timeout")
        } catch let error as LanError {
            XCTAssertEqual(error, .timeout)
        }
        let online = await ac.online
        XCTAssertFalse(online)
    }

    func testPacketsForAnotherDeviceIdAreIgnored() async throws {
        let fake = try FakeMideaDevice(token: Self.token, key: Self.key, deviceId: Self.deviceId)
        let ac = AirConditioner(ip: "127.0.0.1", port: fake.port, id: Self.deviceId &+ 1)
        await ac.setCredentials(token: Data(Self.token), key: Self.key)
        try await ac.authenticate()
        do {
            _ = try await ac.refresh()
            XCTFail("a unit must not answer a packet addressed to another device id")
        } catch let error as LanError {
            XCTAssertEqual(error, .timeout)
        }
        await ac.disconnect()
    }
}
