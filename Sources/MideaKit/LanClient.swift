import Foundation
import Network

/// TCP client for a single V3 appliance. Serialises requests, handles the
/// 0x8370 handshake and transparently reconnects.
actor LanClient {
    let host: String
    let port: UInt16
    let deviceId: UInt64

    private var connection: NWConnection?
    private var codec = V3Codec()
    private var token: Data?
    private var key: Data?
    private var authExpiry: Date?
    private var alive = false
    private var generation = 0
    private var lastError: Error?

    private var received: [[UInt8]] = []
    private var inFlight = false
    private var unsolicitedHandler: (@Sendable ([UInt8]) -> Void)?
    private var waiter: (id: UInt64, continuation: CheckedContinuation<[UInt8], Error>)?
    private var waiterSeq: UInt64 = 0
    private var consumer: Task<Void, Never>?

    static let authenticationLifetime: TimeInterval = 12 * 3600
    static let responseTimeout: TimeInterval = 2
    static let retries = 3

    init(host: String, port: UInt16, deviceId: UInt64) {
        self.host = host
        self.port = port
        self.deviceId = deviceId
    }

    var hasCredentials: Bool { token != nil && key != nil }

    /// Frames the unit sends on its own (e.g. after the IR remote is used) are delivered here
    /// whenever no request is waiting for a reply.
    func setUnsolicitedHandler(_ handler: (@Sendable ([UInt8]) -> Void)?) {
        unsolicitedHandler = handler
    }

    func setCredentials(token: Data, key: Data) {
        if self.token != token || self.key != key {
            self.token = token
            self.key = key
            authExpiry = nil
            codec.localKey = nil
        }
    }

    var isAuthenticated: Bool {
        guard alive, connection != nil, codec.localKey != nil, let authExpiry else { return false }
        return authExpiry > Date()
    }

    // MARK: Connection management

    private func connect() async throws {
        disconnect()
        generation += 1
        let gen = generation
        codec = V3Codec()
        received.removeAll()

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LanError.connectFailed("bad port") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
            tcp.noDelay = true
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let queue = DispatchQueue(label: "breeze.lan.\(host)")
        let (stream, streamContinuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        let ready = OnceContinuation<Void>()

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.resume(.success(()))
            case .failed(let error):
                ready.resume(.failure(LanError.connectFailed(error.localizedDescription)))
                streamContinuation.finish(throwing: LanError.connectFailed(error.localizedDescription))
            case .cancelled:
                ready.resume(.failure(LanError.connectionClosed))
                streamContinuation.finish(throwing: LanError.connectionClosed)
            case .waiting(let error):
                ready.resume(.failure(LanError.connectFailed(error.localizedDescription)))
            default:
                break
            }
        }

        var buffer: [UInt8] = []
        func receiveNext() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer += data.bytes
                    for packet in V3Codec.extractPackets(from: &buffer) {
                        streamContinuation.yield(packet)
                    }
                }
                if let error {
                    streamContinuation.finish(throwing: LanError.connectFailed(error.localizedDescription))
                    return
                }
                if isComplete {
                    streamContinuation.finish(throwing: LanError.connectionClosed)
                    return
                }
                receiveNext()
            }
        }

        connection = conn
        conn.start(queue: queue)

        let timeoutTask = Task { try? await Task.sleep(for: .seconds(5)); ready.resume(.failure(LanError.timeout)) }
        do {
            try await ready.value()
        } catch {
            timeoutTask.cancel()
            conn.cancel()
            connection = nil
            throw error
        }
        timeoutTask.cancel()
        alive = true
        lastError = nil
        receiveNext()

        consumer = Task { [weak self] in
            do {
                for try await packet in stream {
                    await self?.enqueue(packet, generation: gen)
                }
                await self?.connectionEnded(generation: gen, error: LanError.connectionClosed)
            } catch {
                await self?.connectionEnded(generation: gen, error: error)
            }
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        consumer?.cancel()
        consumer = nil
        alive = false
        codec.localKey = nil
        authExpiry = nil
        if let w = waiter {
            waiter = nil
            w.continuation.resume(throwing: LanError.connectionClosed)
        }
    }

    private func enqueue(_ packet: [UInt8], generation gen: Int) {
        guard gen == generation else { return }
        if let w = waiter {
            waiter = nil
            w.continuation.resume(returning: packet)
            return
        }
        if !inFlight, codec.localKey != nil, let handler = unsolicitedHandler,
           let frame = try? decodeFrames(packet) {
            MideaLog.log("[\(host)] unsolicited frame \(frame.hex)")
            handler(frame)
            return
        }
        received.append(packet)
    }

    private func connectionEnded(generation gen: Int, error: Error) {
        guard gen == generation else { return }
        MideaLog.log("[\(host)] connection ended: \(error)")
        alive = false
        lastError = error
        if let w = waiter {
            waiter = nil
            w.continuation.resume(throwing: error)
        }
    }

    private func nextPacket(timeout: TimeInterval) async throws -> [UInt8] {
        if !received.isEmpty { return received.removeFirst() }
        guard alive else { throw lastError ?? LanError.notConnected }
        waiterSeq += 1
        let id = waiterSeq
        return try await withCheckedThrowingContinuation { continuation in
            waiter = (id, continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeoutWaiter(id)
            }
        }
    }

    private func timeoutWaiter(_ id: UInt64) {
        guard let w = waiter, w.id == id else { return }
        waiter = nil
        w.continuation.resume(throwing: LanError.timeout)
    }

    private func write(_ bytes: [UInt8]) async throws {
        guard let connection, alive else { throw LanError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: LanError.connectFailed(error.localizedDescription)) }
                else { continuation.resume(returning: ()) }
            })
        }
    }

    // MARK: Protocol

    /// Perform the token/key handshake, connecting first if necessary.
    func authenticate() async throws {
        guard let token, let key else { throw LanError.missingCredentials }
        inFlight = true
        defer { inFlight = false }
        if !alive || connection == nil { try await connect() }
        received.removeAll()
        MideaLog.log("[\(host)] authenticating")

        var attempts = Self.retries
        var response: [UInt8]?
        while attempts > 0 {
            let wire = codec.encodeHandshake(token: token.bytes)
            try await write(wire)
            do {
                let packet = try await nextPacket(timeout: Self.responseTimeout)
                switch try codec.decode(packet) {
                case .handshakeResponse(let payload): response = payload
                case .error: disconnect(); throw LanError.deviceRejected
                case .encryptedResponse: disconnect(); throw LanError.authenticationFailed("Unexpected encrypted response")
                }
                break
            } catch LanError.timeout {
                attempts -= 1
                if attempts == 0 { disconnect(); throw LanError.timeout }
            } catch {
                disconnect()
                throw error
            }
        }
        guard let response else { throw LanError.authenticationFailed("No handshake response") }
        do {
            codec.localKey = try V3Codec.deriveLocalKey(key: key, response: response)
        } catch {
            disconnect()
            throw error
        }
        authExpiry = Date().addingTimeInterval(Self.authenticationLifetime)
        MideaLog.log("[\(host)] authenticated")
        // The module needs a moment after the handshake before it answers commands.
        try? await Task.sleep(for: .milliseconds(800))
    }

    private func decodeFrames(_ packet: [UInt8]) throws -> [UInt8]? {
        switch try codec.decode(packet) {
        case .encryptedResponse(let lanPacket):
            return try LanPacket.decode(lanPacket)
        case .error:
            throw LanError.deviceRejected
        case .handshakeResponse:
            return nil
        }
    }

    /// Send one appliance frame and return every frame received in reply.
    func send(frame: [UInt8]) async throws -> [[UInt8]] {
        if !isAuthenticated { try await authenticate() }
        inFlight = true
        defer { inFlight = false }
        let packet = try LanPacket.encode(deviceId: deviceId, frame: frame)

        var frames: [[UInt8]] = []
        // Anything that arrived unsolicited since the last call.
        for p in received { if let f = try? decodeFrames(p) { frames.append(f) } }
        received.removeAll()

        var attempts = Self.retries
        while attempts > 0 {
            let wire = try codec.encodeEncryptedRequest(packet)
            try await write(wire)
            do {
                let packet = try await nextPacket(timeout: Self.responseTimeout)
                if let f = try decodeFrames(packet) { frames.append(f) }
                break
            } catch LanError.timeout {
                attempts -= 1
                MideaLog.log("[\(host)] no reply, \(attempts) retries left")
                if attempts == 0 { disconnect(); throw LanError.timeout }
            } catch {
                MideaLog.log("[\(host)] send failed: \(error)")
                disconnect()
                throw error
            }
        }
        // Drain anything else already queued.
        for p in received { if let f = try? decodeFrames(p) { frames.append(f) } }
        received.removeAll()
        return frames
    }
}

/// Resume-once wrapper so NWConnection state callbacks can't double-resume a continuation.
final class OnceContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func resume(_ r: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = r
        if let c = continuation {
            continuation = nil
            c.resume(with: r)
        }
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let r = result {
                lock.unlock()
                c.resume(with: r)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}
