import Foundation
import Testing
@testable import DriveCore
@testable import DriveExplorer

private let completeTokenResponse = #"{"access_token":"synthetic-access","expires_in":3600,"refresh_token":"synthetic-refresh","scope":"https://www.googleapis.com/auth/drive.metadata.readonly https://www.googleapis.com/auth/drive.activity.readonly","token_type":"Bearer","unrelated_field":"ignored"}"#

@Test func tokenResponseRequiresBothReadOnlyGrants() throws {
    let response = try TokenResponse.load(Data(completeTokenResponse.utf8))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = try response.offlineToken(now: now, access: .metadata)
    #expect(token.access == "synthetic-access")
    #expect(token.refresh == "synthetic-refresh")
    #expect(token.expires == now.addingTimeInterval(3600))
    for scope in requiredDriveScopes {
        let partial = completeTokenResponse.replacingOccurrences(of: scope, with: "")
        do {
            _ = try TokenResponse.load(Data(partial.utf8))
            Issue.record("Partial permission grant was accepted")
        } catch let error as MonitorError {
            #expect(error.localizedDescription.contains(scope))
            #expect(!error.localizedDescription.contains("synthetic-access"))
            #expect(!error.localizedDescription.contains("synthetic-refresh"))
        }
    }
    let invalidResponses = [
        "{", "{}",
        completeTokenResponse.replacingOccurrences(of: "synthetic-access", with: " "),
        completeTokenResponse.replacingOccurrences(of: "synthetic-refresh", with: ""),
        completeTokenResponse.replacingOccurrences(of: "3600", with: "0"),
        completeTokenResponse.replacingOccurrences(of: "3600", with: "-1"),
        completeTokenResponse.replacingOccurrences(of: "\"Bearer\"", with: "\"unsupported\""),
        completeTokenResponse.replacingOccurrences(of: "\"scope\"", with: "\"missing_scope\""),
        completeTokenResponse.replacingOccurrences(of: "drive.activity.readonly", with: "DRIVE.ACTIVITY.READONLY")
    ]
    for invalid in invalidResponses {
        #expect(throws: MonitorError.self) { try TokenResponse.load(Data(invalid.utf8)) }
    }
}

@Test func tokenRenewalRetainsOrRotatesOfflineGrant() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let previous = OAuthToken(access: "previous-access", refresh: "previous-refresh", expires: now, scopes: nil)
    let withoutRefresh = completeTokenResponse.replacingOccurrences(of: #""refresh_token":"synthetic-refresh","#, with: "")
    let renewal = try TokenResponse.load(Data(withoutRefresh.utf8))
    #expect(throws: MonitorError.self) { try renewal.offlineToken(now: now, access: .metadata) }
    let retained = renewal.renewedToken(previous: previous, now: now)
    #expect(retained.refresh == previous.refresh)
    #expect(retained.access == "synthetic-access")
    #expect(retained.expires == now.addingTimeInterval(3600))
    let rotated = try TokenResponse.load(Data(completeTokenResponse.utf8)).renewedToken(previous: previous, now: now)
    #expect(rotated.refresh == "synthetic-refresh")
    #expect(previous.refresh == "previous-refresh")
}

@Test func managementGrantIsExplicitAndLegacyTokensStayRestricted() throws {
    let partial = try TokenResponse.load(Data(completeTokenResponse.utf8))
    #expect(throws: MonitorError.self) { try partial.offlineToken(now: Date(), access: .management) }
    let broader = completeTokenResponse.replacingOccurrences(of: "drive.metadata.readonly", with: "drive")
    let token = try TokenResponse.load(Data(broader.utf8)).offlineToken(now: Date(), access: .management)
    #expect(token.scopes?.contains("https://www.googleapis.com/auth/drive") == true)
    let legacy = OAuthToken(access: "synthetic", refresh: "synthetic", expires: Date(), scopes: nil)
    let restored = try JSONDecoder().decode(OAuthToken.self, from: JSONEncoder().encode(legacy))
    #expect(restored.scopes == nil)
    let url = authorizationURL(clientID: "synthetic", redirect: "http://127.0.0.1:1234/oauth/callback", state: "test", verifier: "test", access: .management)
    let scopes = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
    #expect(scopes == "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/drive.activity.readonly")
}

@Test func previewStorageUsesPrivateTemporaryPathsAndCleansUp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PreviewStore(root: root)
    let preview = try await store.save(PreviewContent(data: Data("synthetic preview".utf8), fileExtension: "txt"), name: "../../private-name.txt")
    #expect(preview.url.deletingLastPathComponent() == root)
    #expect(!preview.url.lastPathComponent.contains("private-name"))
    #expect(try Data(contentsOf: preview.url) == Data("synthetic preview".utf8))
    #expect((try FileManager.default.attributesOfItem(atPath: preview.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try await store.remove(preview.url)
    #expect(!FileManager.default.fileExists(atPath: preview.url.path))
    try await store.clear()
}
