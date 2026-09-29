import Foundation
import Security
import CryptoKit
import OSLog
import DriveCore

struct OAuthConfiguration: Codable, Sendable {
    let installed: DesktopClient
    struct DesktopClient: Codable, Sendable { let client_id: String; let client_secret: String? }
    static func load(_ data: Data) throws -> OAuthConfiguration {
        guard data.count <= 1_048_576 else { throw MonitorError.authentication("This JSON exceeds 1 MiB. Download the Desktop OAuth client JSON from Google Auth platform → Clients; do not import an export or database.") }
        let result: OAuthConfiguration
        do { result = try JSONDecoder().decode(Self.self, from: data) }
        catch is DecodingError { throw MonitorError.authentication("This is not a valid Desktop OAuth client JSON. In Google Auth platform → Clients, create a client with application type Desktop app and download its JSON. Web clients, service-account keys and token files cannot be imported. The existing configuration was not changed.") }
        guard result.installed.client_id.range(of: "^[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$", options: .regularExpression) != nil else { throw MonitorError.authentication("The Desktop client ID is invalid. Download a fresh JSON from Google Auth platform → Clients. Do not edit the file or paste its contents into chat.") }
        return result
    }
}
struct OAuthToken: Codable, Sendable {
    let access: String; let refresh: String; let expires: Date
}
struct TokenResponse: Decodable, Sendable {
    let access_token: String; let expires_in: Int; let refresh_token: String?
}

actor Credentials: TokenProvider {
    private let service = "local.driveexplorer.oauth"
    private var configuration: OAuthConfiguration?
    private var token: OAuthToken?
    private var refreshTask: Task<OAuthToken, Error>?
    init() {}
    private func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MonitorError.authentication("Keychain read failed (\(status)). Unlock your login keychain and try again.") }
        return data
    }
    private func write(_ account: String, data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw MonitorError.authentication("Keychain save failed (\(added)).") }
        } else if status != errSecSuccess { throw MonitorError.authentication("Keychain update failed (\(status)).") }
    }
    func restore() throws -> Bool {
        if let data = try read("configuration") { configuration = try OAuthConfiguration.load(data) }
        if let data = try read("token") { token = try JSONDecoder().decode(OAuthToken.self, from: data) }
        return token != nil
    }
    func hasConfiguration() -> Bool { configuration != nil }
    func configure(_ data: Data) throws {
        let value = try OAuthConfiguration.load(data)
        if let old = configuration, old.installed.client_id != value.installed.client_id { try disconnect() }
        try write("configuration", data: data); configuration = value
    }
    func clientID() throws -> String {
        guard let configuration else { throw MonitorError.authentication("Import a Desktop OAuth client JSON in Settings before connecting.") }
        return configuration.installed.client_id
    }
    func exchange(code: String, verifier: String, redirect: String) async throws {
        guard let configuration else { throw MonitorError.authentication("OAuth configuration is missing.") }
        var fields = ["client_id": configuration.installed.client_id, "code": code, "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"]
        if let secret = configuration.installed.client_secret { fields["client_secret"] = secret }
        let response = try await Self.fetch(fields)
        guard let refresh = response.refresh_token else { throw MonitorError.authentication("Google did not return an offline refresh token. Reconnect and grant consent.") }
        let value = OAuthToken(access: response.access_token, refresh: refresh, expires: Date().addingTimeInterval(Double(response.expires_in)))
        try write("token", data: JSONEncoder().encode(value)); token = value
    }
    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let token, let configuration else { throw MonitorError.authentication("Connect your Google account in Settings.") }
        if !forceRefresh && token.expires.timeIntervalSinceNow > 60 { return token.access }
        if let refreshTask { return try await refreshTask.value.access }
        let task = Task<OAuthToken, Error> {
            var fields = ["client_id": configuration.installed.client_id, "refresh_token": token.refresh, "grant_type": "refresh_token"]
            if let secret = configuration.installed.client_secret { fields["client_secret"] = secret }
            let response = try await Self.fetch(fields)
            return OAuthToken(access: response.access_token, refresh: response.refresh_token ?? token.refresh, expires: Date().addingTimeInterval(Double(response.expires_in)))
        }
        refreshTask = task
        defer { refreshTask = nil }
        let refreshed = try await task.value
        try write("token", data: JSONEncoder().encode(refreshed)); self.token = refreshed
        return refreshed.access
    }
    private static func fetch(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!); request.httpMethod = "POST"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let logger = Logger(subsystem: "local.driveexplorer", category: "OAuth")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let data: Data; let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch let error as URLError {
                guard attempt < 3, [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) else { throw error }
                logger.warning("OAuth network retry attempt=\(attempt + 1) code=\(error.errorCode)")
                try await Task.sleep(for: .seconds(pow(2, Double(attempt)))); continue
            }
            guard let http = response as? HTTPURLResponse else { throw MonitorError.authentication("Token endpoint returned a non-HTTP response.") }
            if http.statusCode == 200 { return try JSONDecoder().decode(TokenResponse.self, from: data) }
            if attempt < 3, [429, 500, 502, 503, 504].contains(http.statusCode) {
                logger.warning("OAuth service retry attempt=\(attempt + 1) status=\(http.statusCode)")
                try await Task.sleep(for: .seconds(pow(2, Double(attempt)))); continue
            }
            struct OAuthFailure: Decodable { let error: String; let error_description: String? }
            let failure = try JSONDecoder().decode(OAuthFailure.self, from: data)
            throw MonitorError.authentication("Google OAuth failed (HTTP \(http.statusCode), \(failure.error)): \(failure.error_description ?? "No description returned.") \(oauthRemedy(failure.error))")
        }
        throw MonitorError.authentication("OAuth request ended without a token response.")
    }

    func disconnect() throws {
        refreshTask?.cancel(); refreshTask = nil
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MonitorError.authentication("Token deletion failed (\(status)).") }
        token = nil
    }
}
func oauthRemedy(_ code: String) -> String {
    switch code {
    case "invalid_grant": "Sign in again. The grant may have expired or been revoked; External projects in Testing normally expire Drive refresh tokens after seven days."
    case "invalid_client", "deleted_client", "unauthorized_client": "Download and import a current Desktop app client JSON from the same Google Cloud project where both Drive APIs are enabled."
    case "access_denied": "Check that this account is listed under Google Auth platform → Audience → Test users, then retry consent. Your Workspace administrator may also restrict access."
    case "admin_policy_enforced", "org_internal": "Use an account allowed by this project's audience and ask your Workspace administrator about app access. This app cannot override organization policy."
    default: "Open Connect Google Drive → Troubleshooting, check the project configuration, then retry sign-in."
    }
}
func randomURLToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MonitorError.authentication("Secure random generation failed.") }
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func authorizationURL(clientID: String, redirect: String, state: String, verifier: String) -> URL {
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    url.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": "https://www.googleapis.com/auth/drive.metadata.readonly https://www.googleapis.com/auth/drive.activity.readonly", "access_type": "offline", "prompt": "consent", "state": state, "code_challenge": challenge, "code_challenge_method": "S256"].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    return url.url!
}
