import Foundation
import Testing
@testable import DriveCore
@testable import DriveExplorer

private let completeTokenResponse = #"{"access_token":"synthetic-access","expires_in":3600,"refresh_token":"synthetic-refresh","scope":"https://www.googleapis.com/auth/drive.metadata.readonly https://www.googleapis.com/auth/drive.activity.readonly","token_type":"Bearer","unrelated_field":"ignored"}"#

@Test func tokenResponseRequiresBothReadOnlyGrants() throws {
    let response = try TokenResponse.load(Data(completeTokenResponse.utf8))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let token = try response.offlineToken(now: now)
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
    let previous = OAuthToken(access: "previous-access", refresh: "previous-refresh", expires: now)
    let withoutRefresh = completeTokenResponse.replacingOccurrences(of: #""refresh_token":"synthetic-refresh","#, with: "")
    let renewal = try TokenResponse.load(Data(withoutRefresh.utf8))
    #expect(throws: MonitorError.self) { try renewal.offlineToken(now: now) }
    let retained = renewal.renewedToken(previous: previous, now: now)
    #expect(retained.refresh == previous.refresh)
    #expect(retained.access == "synthetic-access")
    #expect(retained.expires == now.addingTimeInterval(3600))
    let rotated = try TokenResponse.load(Data(completeTokenResponse.utf8)).renewedToken(previous: previous, now: now)
    #expect(rotated.refresh == "synthetic-refresh")
    #expect(previous.refresh == "previous-refresh")
}
