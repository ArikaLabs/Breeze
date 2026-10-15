import Foundation

/// High level control of one Midea air conditioner over the LAN.
public actor AirConditioner {
    public let ip: String
    public let port: UInt16
    public let id: UInt64

    private let lan: LanClient
    private var messageId: UInt8 = 0

    public private(set) var state = ACState()
    public private(set) var capabilities = ACCapabilities()
    public private(set) var capabilitiesLoaded = false
    public private(set) var online = false
    private var supportedProperties: Set<PropertyId> = []
    private var stateObserver: (@Sendable (ACState) -> Void)?

    public init(ip: String, port: UInt16 = 6444, id: UInt64, token: Data? = nil, key: Data? = nil) {
        self.ip = ip
        self.port = port
        self.id = id
        self.lan = LanClient(host: ip, port: port, deviceId: id)
        if let token, let key { Task { await lan.setCredentials(token: token, key: key) } }
    }

    public func setCredentials(token: Data, key: Data) async {
        await lan.setCredentials(token: token, key: key)
    }

    public func setCredentials(tokenHex: String, keyHex: String) async throws {
        guard let t = Data(hex: tokenHex), let k = Data(hex: keyHex) else { throw LanError.missingCredentials }
        await lan.setCredentials(token: t, key: k)
    }

    /// Called whenever the unit reports a state change on its own (remote control, app, timers).
    public func setStateObserver(_ observer: (@Sendable (ACState) -> Void)?) async {
        stateObserver = observer
        await installUnsolicitedHandler()
    }

    private func installUnsolicitedHandler() async {
        await lan.setUnsolicitedHandler { [weak self] frame in
            Task { await self?.handleUnsolicited(frame) }
        }
    }

    private func handleUnsolicited(_ frame: [UInt8]) {
        guard let response = try? ACResponse.parse(frame: frame) else { return }
        switch response {
        case .state, .properties, .group4, .group5:
            apply(response)
            stateObserver?(state)
        case .capabilities, .other:
            break
        }
    }

    /// Handshake with the device. Throws `LanError.deviceRejected` for a wrong token/key.
    public func authenticate() async throws {
        await installUnsolicitedHandler()
        try await lan.authenticate()
        online = true
    }

    public func disconnect() async {
        await lan.disconnect()
    }

    /// Try each token/key until the unit accepts one. Returns the working credentials.
    public func authenticate(trying candidates: [DeviceCredentials]) async throws -> DeviceCredentials {
        var lastError: Error = LanError.missingCredentials
        for creds in candidates {
            do {
                try await setCredentials(tokenHex: creds.token, keyHex: creds.key)
                try await authenticate()
                return creds
            } catch {
                lastError = error
                await lan.disconnect()
                if case LanError.deviceRejected = error { continue }
                if case LanError.authenticationFailed = error { continue }
                throw error
            }
        }
        throw lastError
    }

    private func nextMessageId() -> UInt8 {
        messageId = messageId &+ 1
        return messageId
    }

    private func send(_ command: ACCommand) async throws -> [ACResponse] {
        let frame = command.encode(messageId: nextMessageId())
        let frames: [[UInt8]]
        do {
            frames = try await lan.send(frame: frame)
            online = true
        } catch {
            online = false
            throw error
        }
        return frames.compactMap { try? ACResponse.parse(frame: $0) }
    }

    private func firstResponse<T>(_ command: ACCommand, _ pick: (ACResponse) -> T?) async throws -> T? {
        for r in try await send(command) { if let v = pick(r) { return v } }
        return nil
    }

    // MARK: Capabilities

    public func getCapabilities() async throws {
        guard var caps = try await firstResponse(.getCapabilities(additional: false), { if case .capabilities(let c) = $0 { return c } else { return nil } }) else {
            throw LanError.protocolError("No capabilities response")
        }
        if caps.additionalCapabilities,
           let more = try await firstResponse(.getCapabilities(additional: true), { if case .capabilities(let c) = $0 { return c } else { return nil } }) {
            caps.merge(more)
        }
        capabilities = caps.capabilities(base: capabilities)
        capabilitiesLoaded = true
        updateSupportedProperties()
        MideaLog.log("[\(ip)] capabilities: modes=\(capabilities.modes.map(\.name)) ieco=\(capabilities.ieco) flash=\(capabilities.flash) energy=\(capabilities.energyStats)")
    }

    private func updateSupportedProperties() {
        var props: Set<PropertyId> = []
        let c = capabilities
        if c.breezeAway { props.insert(.breezeAway) }
        if c.breezeControl { props.insert(.breezeControl) }
        if c.breezeless { props.insert(.breezeless) }
        if c.cascade { props.insert(.cascade) }
        if c.flash { props.insert(.flash) }
        if c.freshAir { props.insert(.freshAir) }
        if c.ieco { props.insert(.ieco) }
        if c.outSilent { props.insert(.outSilent) }
        if c.selfClean { props.insert(.selfClean) }
        if c.sound { props.insert(.sound) }
        if c.swingHorizontalAngle { props.insert(.swingLRAngle) }
        if c.swingVerticalAngle { props.insert(.swingUDAngle) }
        supportedProperties = props
    }

    // MARK: State

    private func apply(_ response: ACResponse) {
        switch response {
        case .state(let r):
            state.power = r.power
            state.targetTemperature = r.targetTemperature
            state.mode = OperationalMode(rawValue: r.mode) ?? state.mode
            state.fanSpeed = r.fanSpeed
            state.swingMode = SwingMode(rawValue: r.swingMode) ?? .off
            state.eco = r.eco
            state.turbo = r.turbo
            if let f = r.freezeProtection { state.freezeProtection = f }
            state.sleep = r.sleep
            state.indoorTemperature = r.indoorTemperature
            state.outdoorTemperature = r.outdoorTemperature
            state.displayOn = r.displayOn
            state.fahrenheit = r.fahrenheit
            state.filterAlert = r.filterAlert
            state.followMe = r.followMe
            state.purifier = r.purifier
            if let h = r.targetHumidity { state.targetHumidity = h }
            state.auxMode = r.independentAuxHeat ? .auxOnly : (r.auxHeat ? .auxHeat : .off)
            state.errorCode = r.errorCode
        case .properties(let p):
            if let v = p.values[.swingLRAngle] { state.horizontalSwingAngle = SwingAngle(rawValue: UInt8(clamping: v)) ?? .off }
            if let v = p.values[.swingUDAngle] { state.verticalSwingAngle = SwingAngle(rawValue: UInt8(clamping: v)) ?? .off }
            if let v = p.values[.flash] { state.flash = v != 0 }
            if let v = p.values[.breezeControl] {
                state.breezeMode = BreezeMode(rawValue: UInt8(clamping: v)) ?? .off
            } else {
                if let v = p.values[.breezeAway] { state.breezeMode = v != 0 ? .breezeAway : .off }
                if let v = p.values[.breezeless] { state.breezeMode = v != 0 ? .breezeless : .off }
            }
            if let v = p.values[.ieco] { state.ieco = v != 0 }
            if let v = p.values[.sound] { state.sound = v != 0 }
        case .group4(let e):
            state.realTimePower = e.realTimePower
            state.totalEnergy = e.totalEnergy
            state.currentRunEnergy = e.currentRunEnergy
        case .group5(let g):
            state.indoorHumidity = g.humidity
        case .capabilities, .other:
            break
        }
    }

    /// Query the device and return the fresh state.
    @discardableResult
    public func refresh() async throws -> ACState {
        var responses = try await send(.getState)
        if capabilities.humidity {
            responses += (try? await send(.getGroupData(5))) ?? []
        }
        if capabilities.energyStats {
            responses += (try? await send(.getGroupData(4))) ?? []
        }
        if !supportedProperties.isEmpty {
            responses += (try? await send(.getProperties(Array(supportedProperties).sorted { $0.rawValue < $1.rawValue }))) ?? []
        }
        guard responses.contains(where: { if case .state = $0 { return true } else { return false } }) else {
            throw LanError.protocolError("No state response")
        }
        for r in responses { apply(r) }
        return state
    }

    /// Push a desired state to the device and return what the device reports back.
    @discardableResult
    public func apply(_ desired: ACState) async throws -> ACState {
        var p = SetStateParameters()
        p.beep = desired.sound
        p.power = desired.power
        p.targetTemperature = desired.targetTemperature
        p.mode = desired.mode.rawValue
        p.fanSpeed = UInt8(clamping: desired.fanSpeed)
        p.swingMode = desired.swingMode.rawValue
        p.eco = desired.eco
        p.turbo = desired.turbo
        p.freezeProtection = desired.freezeProtection
        p.sleep = desired.sleep
        p.fahrenheit = desired.fahrenheit
        p.followMe = desired.followMe
        p.purifier = desired.purifier
        p.targetHumidity = desired.targetHumidity
        p.auxHeat = desired.auxMode == .auxHeat
        p.independentAuxHeat = desired.auxMode == .auxOnly

        let previous = state
        for r in try await send(.setState(p)) { apply(r) }

        // Property based features, only when changed and supported.
        var props: [(PropertyId, [UInt8])] = []
        if supportedProperties.contains(.flash), desired.flash != previous.flash {
            props.append((.flash, [desired.flash ? 1 : 0]))
        }
        if supportedProperties.contains(.ieco), desired.ieco != previous.ieco {
            props.append((.ieco, [0, UInt8(capabilities.iecoNumber), desired.ieco ? 1 : 0] + [UInt8](repeating: 0, count: 10)))
        }
        if desired.breezeMode != previous.breezeMode {
            if supportedProperties.contains(.breezeControl) {
                props.append((.breezeControl, [desired.breezeMode.rawValue]))
            } else {
                if supportedProperties.contains(.breezeAway) {
                    props.append((.breezeAway, [desired.breezeMode == .breezeAway ? 2 : 1]))
                }
                if supportedProperties.contains(.breezeless) {
                    props.append((.breezeless, [desired.breezeMode == .breezeless ? 1 : 0]))
                }
            }
        }
        if supportedProperties.contains(.swingLRAngle), desired.horizontalSwingAngle != previous.horizontalSwingAngle {
            props.append((.swingLRAngle, [desired.horizontalSwingAngle.rawValue]))
        }
        if supportedProperties.contains(.swingUDAngle), desired.verticalSwingAngle != previous.verticalSwingAngle {
            props.append((.swingUDAngle, [desired.verticalSwingAngle.rawValue]))
        }
        if !props.isEmpty {
            props.append((.buzzer, [desired.sound ? 1 : 0]))
            for r in try await send(.setProperties(props)) { apply(r) }
        }
        state.sound = desired.sound
        return state
    }

    /// Start the unit's self-cleaning cycle (property 0x0039). The unit runs it on its own and stops.
    public func startSelfClean() async throws {
        let beep: UInt8 = state.sound ? 1 : 0
        for r in try await send(.setProperties([(.selfClean, [1]), (.buzzer, [beep])])) { apply(r) }
    }

    public func toggleDisplay() async throws {
        _ = try await send(.toggleDisplay(beep: state.sound))
        try await refresh()
    }
}
