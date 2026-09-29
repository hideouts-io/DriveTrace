import Foundation
import Testing
@testable import DriveCore
@testable import DriveExplorer

actor FixtureResponses {
    var requests: [URLRequest] = []
    var responses: [(Int, String)] = []
    func prepare(_ values: [(Int, String)]) { requests = []; responses = values }
    func next(_ request: URLRequest) throws -> (Int, String) {
        requests.append(request)
        guard !responses.isEmpty else { throw MonitorError.invalid("Unexpected fixture request: \(request.url!.path)") }
        return responses.removeFirst()
    }
    func allRequests() -> [URLRequest] { requests }
}
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = FixtureResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            do {
                let (status, body) = try await Self.fixture.next(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json", "Retry-After":"0"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
actor FixtureTokens: TokenProvider {
    var refreshes = 0
    func accessToken(forceRefresh: Bool) async throws -> String { if forceRefresh { refreshes += 1 }; return "synthetic-test-token" }
    func refreshCount() -> Int { refreshes }
}
func fixtureClient(_ tokens: FixtureTokens) -> GoogleClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
    return GoogleClient(tokens: tokens, session: URLSession(configuration: configuration))
}
@Suite(.serialized) struct GoogleIntegrationTests {
    @Test func fullSyncPaginatesAndResumes() async throws {
        await FixtureProtocol.fixture.prepare([
            (200, #"{"drives":[]}"#),
            (200, #"{"startPageToken":"initial"}"#),
            (200, #"{"files":[{"id":"a","name":"Alpha","mimeType":"text/plain"}],"nextPageToken":"files2"}"#),
            (200, #"{"files":[{"id":"b","name":"Beta","mimeType":"text/plain"}]}"#),
            (200, #"{"changes":[],"nextPageToken":"changes2"}"#),
            (200, #"{"changes":[],"newStartPageToken":"durable"}"#),
            (200, #"{"activities":[],"nextPageToken":"activities2"}"#),
            (200, #"{"activities":[]}"#)
        ])
        let client = fixtureClient(FixtureTokens()); let (db, _) = try temporaryDatabase()
        let result = try await synchronize(client: client, database: db) { _ in }
        #expect(result.gaps.isEmpty); #expect(try await db.files().count == 2); #expect(try await db.cursor("user") == "durable")
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 8)
        #expect(requests[4].url?.query?.contains("pageToken=initial") == true)
        #expect(try await db.setting("activity.watermark.user") != nil)
        await FixtureProtocol.fixture.prepare([(200, #"{"drives":[]}"#), (200, #"{"changes":[],"newStartPageToken":"resumed"}"#), (200, #"{"activities":[]}"#)])
        _ = try await synchronize(client: client, database: db) { _ in }
        #expect(try await db.cursor("user") == "resumed")
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)
        try await db.close()
    }
    @Test func repeatedPageDoesNotPromotePartialIndex() async throws {
        await FixtureProtocol.fixture.prepare([
            (200, #"{"drives":[]}"#), (200, #"{"startPageToken":"initial"}"#),
            (200, #"{"files":[],"nextPageToken":"repeat"}"#), (200, #"{"files":[],"nextPageToken":"repeat"}"#),
            (200, #"{"activities":[]}"#)
        ])
        let (db, _) = try temporaryDatabase()
        let result = try await synchronize(client: fixtureClient(FixtureTokens()), database: db) { _ in }
        #expect(result.gaps.count == 1); #expect(result.gaps[0].contains("repeated")); #expect(try await db.cursor("user") == nil)
        try await db.close()
    }
    @Test func incompleteSearchPreservesPreviousEvidence() async throws {
        await FixtureProtocol.fixture.prepare([(200, #"{"drives":[]}"#), (200, #"{"startPageToken":"initial"}"#), (200, #"{"files":[],"incompleteSearch":true}"#), (403, #"{"error":{"message":"Activity disabled"}}"#)])
        let (db, _) = try temporaryDatabase()
        let result = try await synchronize(client: fixtureClient(FixtureTokens()), database: db) { _ in }
        #expect(result.gaps.count == 2); #expect(try await db.cursor("user") == nil)
        #expect(try await db.setting("activity.watermark.user") == nil)
        try await db.close()
    }
    @Test func authAndRateLimitRetriesThenSucceeds() async throws {
        await FixtureProtocol.fixture.prepare([(401, #"{"error":"expired"}"#), (429, #"{"error":"limited"}"#), (200, #"{"drives":[]}"#)])
        let tokens = FixtureTokens()
        _ = try await fixtureClient(tokens).drives(page: nil)
        #expect(await tokens.refreshCount() == 1)
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)
    }
    @Test func exhaustedRetriesSurfaceLastError() async throws {
        await FixtureProtocol.fixture.prepare(Array(repeating: (503, #"{"error":"fixture-unavailable"}"#), count: 4))
        await #expect(throws: MonitorError.self) { try await fixtureClient(FixtureTokens()).drives(page: nil) }
        #expect(await FixtureProtocol.fixture.allRequests().count == 4)
    }
    @Test func cancelledSyncDoesNotRequestPages() async throws {
        let (db, _) = try temporaryDatabase()
        await FixtureProtocol.fixture.prepare([])
        let task = Task { try Task.checkCancellation(); return try await synchronize(client: fixtureClient(FixtureTokens()), database: db) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await db.cursor("user") == nil)
        try await db.close()
    }
}
@Test func desktopOAuthConfigurationAndPKCE() throws {
    let configuration = try OAuthConfiguration.load(Data(#"{"installed":{"client_id":"synthetic.apps.googleusercontent.com","client_secret":"test-only"}}"#.utf8))
    #expect(configuration.installed.client_id.hasSuffix(".apps.googleusercontent.com"))
    #expect(throws: DecodingError.self) { try OAuthConfiguration.load(Data(#"{"web":{"client_id":"wrong.apps.googleusercontent.com"}}"#.utf8)) }
    let verifier = try randomURLToken(); #expect(verifier.count == 43)
    let url = authorizationURL(clientID: "synthetic", redirect: "http://127.0.0.1:1234/oauth/callback", state: "state-value", verifier: verifier)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
    #expect(items.first { $0.name == "state" }?.value == "state-value")
    #expect(!url.absoluteString.contains(verifier))
    #expect(items.first { $0.name == "scope" }?.value?.contains("drive.metadata.readonly") == true)
}
@Test func loopbackRejectsWrongStateThenAcceptsValidCallback() async throws {
    let loopback = Loopback(state: "expected-state")
    let redirect = try await loopback.start()
    let (wrong, wrongResponse) = try await URLSession.shared.data(from: URL(string: redirect + "?state=wrong&code=fake")!)
    #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 400)
    #expect(String(decoding: wrong, as: UTF8.self).contains("State mismatch"))
    let receiver = Task { try await loopback.code() }
    _ = try await URLSession.shared.data(from: URL(string: redirect + "?state=expected-state&code=synthetic-code")!)
    #expect(try await receiver.value == "synthetic-code")
}
@Test func loopbackCancellationFinishes() async throws {
    let loopback = Loopback(state: "cancel-state")
    _ = try await loopback.start()
    let receiver = Task { try await loopback.code() }
    await loopback.cancel()
    await #expect(throws: CancellationError.self) { try await receiver.value }
}
@Test func allUnknownStorageRemainsUnknown() {
    let document = DriveFile(id: "one", name: "Google document", mimeType: "application/vnd.google-apps.document")
    let groups = storageGroups([document]) { $0.mimeType }
    #expect(groups.first?.bytes == nil)
    #expect(groups.first?.unknown == 1)
    #expect(sumKnown([]) == nil)
    #expect(sumKnown([0]) == 0)
}
