import Foundation

public enum CloudError: Error, LocalizedError {
    case api(code: Int, message: String)
    case network(String)
    case invalidResponse(String)
    case noTokenForDevice

    public var errorDescription: String? {
        switch self {
        case .api(let code, let message):
            switch code {
            case 3102: return "Account or password incorrect (\(code))."
            case 3201: return "This appliance is not registered to that account (\(code)). Pair it in the MSmartHome app first."
            case 9999: return "Midea cloud returned 'system error' (\(code))."
            default: return "\(message) (\(code))"
            }
        case .network(let s): return "Network error: \(s)"
        case .invalidResponse(let s): return "Unexpected cloud response: \(s)"
        case .noTokenForDevice: return "The cloud returned no token for this appliance."
        }
    }
}

public struct DeviceCredentials: Equatable, Codable, Sendable {
    public var token: String
    public var key: String
    public init(token: String, key: String) { self.token = token; self.key = key }
}

/// Minimal client for the Midea "MSmartHome" (SmartHome) cloud, used only to obtain
/// the per-device token and key that the local V3 protocol needs.
public actor SmartHomeCloud {
    static let baseURL = "https://mp-prod.appsmb.com"
    static let appId = "1010"
    static let hmacKey = "PROD_VnoClJI9aikS8dyy"
    static let iotKey = "meicloud"
    static let loginKey = "ac21b9f9cbfe4ca5a88562ef25e2b768"

    private let account: String
    private let password: String
    private let clientDeviceId: String
    private let session: URLSession
    private var loginId: String?
    private var accessToken = ""

    public init(account: String, password: String, session: URLSession = .shared) {
        self.account = account
        self.password = password
        self.session = session
        self.clientDeviceId = Crypto.randomBytes(8).hex
    }

    public var isLoggedIn: Bool { !accessToken.isEmpty }

    // MARK: Signing helpers (pure, exposed for tests)

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.string(from: date)
    }

    static func sign(body: String, random: String) -> String {
        let msg = iotKey + body + random
        return Crypto.hmacSHA256(key: Data(hmacKey.utf8), message: Data(msg.utf8)).hex
    }

    static func encryptPassword(loginId: String, password: String) -> String {
        let m1 = Crypto.sha256(Data(password.utf8)).hex
        return Crypto.sha256(Data((loginId + m1 + loginKey).utf8)).hex
    }

    static func encryptIAMPassword(loginId: String, password: String) -> String {
        let m1 = Crypto.md5(Data(password.utf8)).hex
        let m2 = Crypto.md5(Data(m1.utf8)).hex
        return Crypto.sha256(Data((loginId + m2 + loginKey).utf8)).hex
    }

    private func baseBody() -> [String: Any] {
        [
            "appId": Self.appId,
            "src": Self.appId,
            "format": 2,
            "clientType": 1,
            "language": "en_US",
            "deviceId": clientDeviceId,
            "stamp": Self.timestamp(),
            "reqId": Crypto.randomBytes(16).hex,
        ]
    }

    private func request(_ endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let bodyString = String(decoding: bodyData, as: UTF8.self)
        let random = Crypto.randomBytes(16).hex
        var req = URLRequest(url: URL(string: "\(Self.baseURL)/mas/v5/app/proxy?alias=\(endpoint)")!)
        req.httpMethod = "POST"
        req.httpBody = bodyData
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "secretVersion")
        req.setValue(Self.sign(body: bodyString, random: random), forHTTPHeaderField: "sign")
        req.setValue(random, forHTTPHeaderField: "random")
        req.setValue(accessToken, forHTTPHeaderField: "accessToken")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        let code: Int
        if let c = json["code"] as? Int { code = c }
        else if let s = json["code"] as? String, let c = Int(s) { code = c }
        else { throw CloudError.invalidResponse("missing code") }
        guard code == 0 else {
            throw CloudError.api(code: code, message: json["msg"] as? String ?? "error")
        }
        return (json["data"] as? [String: Any]) ?? [:]
    }

    private func fetchLoginId() async throws -> String {
        var body = baseBody()
        body["loginAccount"] = account
        let data = try await request("/v1/user/login/id/get", body: body)
        guard let id = data["loginId"] as? String else { throw CloudError.invalidResponse("missing loginId") }
        return id
    }

    public func login() async throws {
        if isLoggedIn { return }
        let loginId = try await fetchLoginId()
        self.loginId = loginId
        let body: [String: Any] = [
            "data": ["platform": 2, "deviceId": clientDeviceId],
            "iotData": [
                "appId": Self.appId,
                "src": Self.appId,
                "clientType": 1,
                "loginAccount": account,
                "iampwd": Self.encryptIAMPassword(loginId: loginId, password: password),
                "password": Self.encryptPassword(loginId: loginId, password: password),
                "pushToken": Crypto.randomBytes(120).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
                "stamp": Self.timestamp(),
                "reqId": Crypto.randomBytes(16).hex,
            ],
        ]
        let data = try await request("/mj/user/login", body: body)
        guard let mdata = data["mdata"] as? [String: Any], let token = mdata["accessToken"] as? String else {
            throw CloudError.invalidResponse("missing accessToken")
        }
        accessToken = token
    }

    /// Fetch the token and key for a udpid. Requires the appliance to be bound to the account.
    public func getToken(udpid: String, applianceId: UInt64) async throws -> DeviceCredentials {
        try await login()
        var body = baseBody()
        body["udpid"] = udpid
        body["applianceCodes"] = String(applianceId)
        let data = try await request("/v1/iot/secure/getToken", body: body)
        guard let list = data["tokenlist"] as? [[String: Any]] else { throw CloudError.invalidResponse("missing tokenlist") }
        for entry in list {
            if (entry["udpId"] as? String)?.lowercased() == udpid.lowercased(),
               let token = entry["token"] as? String, let key = entry["key"] as? String {
                return DeviceCredentials(token: token.lowercased(), key: key.lowercased())
            }
        }
        throw CloudError.noTokenForDevice
    }

    /// The cloud issues a token for whichever udpid encoding it is given, but the unit only
    /// accepts the one matching its own ID encoding. Return both candidates, little endian first.
    public func fetchCredentialCandidates(deviceId: UInt64) async throws -> [DeviceCredentials] {
        var candidates: [DeviceCredentials] = []
        var lastError: Error = CloudError.noTokenForDevice
        for little in [true, false] {
            let udpid = MideaSecurity.udpid(deviceId: deviceId, littleEndian: little)
            do {
                candidates.append(try await getToken(udpid: udpid, applianceId: deviceId))
            } catch {
                lastError = error
                if case CloudError.api(let code, _) = error, code == 3201 || code == 3102 { throw error }
            }
        }
        if candidates.isEmpty { throw lastError }
        return candidates
    }

    /// First candidate only; prefer `fetchCredentialCandidates` + `AirConditioner.authenticate(trying:)`.
    public func fetchCredentials(deviceId: UInt64) async throws -> DeviceCredentials {
        guard let first = try await fetchCredentialCandidates(deviceId: deviceId).first else { throw CloudError.noTokenForDevice }
        return first
    }

    /// Appliances bound to the account (name, id, type) so devices can be labelled.
    public func listAppliances() async throws -> [CloudAppliance] {
        try await login()
        let data = try await request("/v1/appliance/user/list/get", body: baseBody())
        var result: [CloudAppliance] = []
        for app in (data["list"] as? [[String: Any]]) ?? [] {
            guard let idValue = app["id"], let id = UInt64("\(idValue)") else { continue }
            let name = (app["name"] as? String) ?? "Appliance"
            let typeString = ((app["type"] as? String) ?? "0").replacingOccurrences(of: "0x", with: "")
            let type = UInt8(typeString, radix: 16) ?? 0
            let status = app["onlineStatus"].map { "\($0)" } ?? ""
            result.append(CloudAppliance(id: id, name: name, type: type, online: status == "1", room: nil))
        }
        return result
    }
}

public struct CloudAppliance: Equatable, Codable, Sendable, Identifiable {
    public var id: UInt64
    public var name: String
    public var type: UInt8
    public var online: Bool
    public var room: String?
}
