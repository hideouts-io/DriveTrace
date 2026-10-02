import Foundation
import DriveCore

let requiredDriveScopes: [String] = [
    "https://www.googleapis.com/auth/drive.metadata.readonly",
    "https://www.googleapis.com/auth/drive.activity.readonly"
]

enum DriveAccess: String, CaseIterable, Identifiable {
    case metadata, management
    var id: String { rawValue }
    var title: String { self == .metadata ? "Metadata and activity only" : "View files and Move to Trash" }
    var scopes: [String] {
        self == .metadata ? requiredDriveScopes : ["https://www.googleapis.com/auth/drive", "https://www.googleapis.com/auth/drive.activity.readonly"]
    }
}

struct TokenResponse: Decodable, Sendable {
    let access_token: String
    let expires_in: Int
    let refresh_token: String?
    let scope: String
    let token_type: String

    /// Validate Google's token envelope before persisting or using any credentials.
    /// Error messages deliberately exclude the credential-bearing response body.
    static func load(_ data: Data) throws -> TokenResponse {
        let response: TokenResponse
        do { response = try JSONDecoder().decode(Self.self, from: data) }
        catch is DecodingError {
            throw MonitorError.authentication("Google's token response is missing or has invalid access_token, expires_in, scope or token_type fields. Sign in again; no replacement token was saved. Do not share the response body, which can contain credentials.")
        }
        guard !response.access_token.isEmpty, response.access_token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw MonitorError.authentication("Google returned an empty access token or a token containing whitespace. Sign in again; no replacement token was saved.")
        }
        guard response.expires_in > 0 else {
            throw MonitorError.authentication("Google returned a nonpositive token lifetime. Sign in again; no replacement token was saved.")
        }
        guard response.token_type.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw MonitorError.authentication("Google returned an unsupported token type; this app requires Bearer authorization. Sign in again; no replacement token was saved.")
        }
        if let refresh = response.refresh_token, refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MonitorError.authentication("Google returned an empty refresh token. Sign in again; no replacement token was saved.")
        }
        let granted = Set(response.scope.split(separator: " ").map(String.init))
        let metadataScopes: Set<String> = ["https://www.googleapis.com/auth/drive.metadata.readonly", "https://www.googleapis.com/auth/drive.readonly", "https://www.googleapis.com/auth/drive"]
        let missing = requiredDriveScopes.filter { scope in
            scope.hasSuffix("/drive.metadata.readonly") ? granted.isDisjoint(with: metadataScopes) : !granted.contains(scope)
        }
        guard missing.isEmpty else {
            throw MonitorError.authentication("Google did not grant the required permissions: \(missing.joined(separator: ", ")). Sign in again and select the requested Drive access and Drive activity permissions on the consent screen. No replacement token was saved. Organization policy may require your Workspace administrator's help.")
        }
        return response
    }

    func offlineToken(now: Date, access: DriveAccess) throws -> OAuthToken {
        if access == .management, !scope.split(separator: " ").contains("https://www.googleapis.com/auth/drive") {
            throw MonitorError.authentication("Google did not grant file management access. Select the Drive file permission during sign-in to enable previews and Move to Trash. Your previous saved sign-in was retained.")
        }
        guard let refresh_token else {
            throw MonitorError.authentication("Google did not return an offline refresh token. Sign in again and grant consent; no replacement token was saved.")
        }
        return OAuthToken(access: access_token, refresh: refresh_token, expires: now.addingTimeInterval(Double(expires_in)), scopes: scope.split(separator: " ").map(String.init))
    }

    /// Google can omit refresh_token when renewing an existing offline grant.
    func renewedToken(previous: OAuthToken, now: Date) -> OAuthToken {
        OAuthToken(access: access_token, refresh: refresh_token ?? previous.refresh, expires: now.addingTimeInterval(Double(expires_in)), scopes: scope.split(separator: " ").map(String.init))
    }
}
