import Foundation
import Testing
import UserNotifications
@testable import DriveCore
@testable import DriveTrace

@Test func notificationPermissionMustAllowDelivery() throws {
    try requireNotificationAuthorization(.authorized)
    try requireNotificationAuthorization(.provisional)
    for status: UNAuthorizationStatus in [.notDetermined, .denied] {
        #expect(throws: MonitorError.self) { try requireNotificationAuthorization(status) }
    }
}

actor FixtureResponses {
    var requests: [URLRequest] = []
    var responses: [Result<(Int, String, [String: String]), URLError>] = []
    func prepare(_ values: [(Int, String)]) { requests = []; responses = values.map { .success(($0.0, $0.1, ["Content-Type": "application/json", "Retry-After": "0"])) } }
    func prepareWithHeaders(_ values: [(Int, String, [String: String])]) { requests = []; responses = values.map { .success($0) } }
    func prepareWithFailures(_ values: [Result<(Int, String, [String: String]), URLError>]) { requests = []; responses = values }
    func next(_ request: URLRequest) throws -> (Int, String, [String: String]) {
        requests.append(request)
        guard !responses.isEmpty else { throw MonitorError.invalid("Unexpected fixture request: \(request.url!.path)") }
        return try responses.removeFirst().get()
    }
    func allRequests() -> [URLRequest] { requests }
}
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = FixtureResponses()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @Sendable [self] in
            do {
                let (status, body, headers) = try await Self.fixture.next(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
actor FixtureTokens: TokenProvider {
    var refreshes = 0
    var scopes: Set<String> = []
    func grantedScopes() -> Set<String> { scopes }
    func grantManagement() { scopes = ["https://www.googleapis.com/auth/drive"] }
    func accessToken(forceRefresh: Bool) async throws -> String { if forceRefresh { refreshes += 1 }; return "synthetic-test-token" }
    func refreshCount() -> Int { refreshes }
}
func fixtureClient(_ tokens: FixtureTokens) -> GoogleClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
    return GoogleClient(tokens: tokens, session: URLSession(configuration: configuration))
}
@Suite(.serialized) struct GoogleIntegrationTests {
    @Test @MainActor func searchEligibilityPreservesLocalFiltersAndRejectsUnsupportedRequests() async throws {
        let model = AppModel(); model.connected = true; model.client = fixtureClient(FixtureTokens())
        var size = FileFilter(); size.minimumBytes = 1
        var ext = FileFilter(); ext.ext = "txt"
        var identity = FileFilter(); identity.fileID = "first"
        var discovered = FileFilter(); discovered.discoveredAfter = "2026-09-01T00:00:00Z"
        var storage = FileFilter(); storage.storage = .mimeFamily("chemical")
        await FixtureProtocol.fixture.prepare([])
        for filter in [size, ext, identity, discovered, storage] {
            model.filter = filter
            #expect(model.filterValidationError == nil); #expect(model.googleSearchValidationError != nil)
            model.queryGoogle()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.busy); #expect(model.error != nil); #expect(model.serverResults == nil)
            #expect(model.filter == filter)
        }
        #expect(await FixtureProtocol.fixture.allRequests().isEmpty)
        model.minimumSizeInput = "invalid"
        #expect(model.googleSearchValidationError == model.filterValidationError)
        model.minimumSizeInput = ""
        var supported = FileFilter(); supported.text = "Report"; supported.mime = "text/plain"; supported.createdAfter = "2026-09-01T00:00:00Z"
        model.filter = supported
        #expect(model.googleSearchValidationError == nil)
        await FixtureProtocol.fixture.prepare([(200, #"{"files":[{"id":"first","name":"Report A","mimeType":"text/plain","createdTime":"2026-09-02T00:00:00Z"}],"nextPageToken":"second-page"}"#), (200, #"{"files":[{"id":"second","name":"Report B","mimeType":"text/plain","createdTime":"2026-09-02T00:00:00Z"}]}"#)])
        model.queryGoogle()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while (model.busy || model.searching) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.busy); #expect(!model.searching); #expect(model.error == nil)
        #expect(model.serverResults?.map(\.id) == ["first", "second"])
        #expect(model.results.map(\.id) == ["first", "second"])
        #expect(model.filter == supported)
        #expect(await FixtureProtocol.fixture.allRequests().count == 2)
    }
    @Test func fullSyncPaginatesAndResumes() async throws {
        await FixtureProtocol.fixture.prepare([
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
        #expect(requests.count == 7)
        #expect(requests.allSatisfy { $0.url?.path != "/drive/v3/drives" })
        #expect(requests[3].url?.query?.contains("pageToken=initial") == true)
        #expect(try await db.setting("activity.watermark.user") != nil)
        await FixtureProtocol.fixture.prepare([(200, #"{"changes":[],"newStartPageToken":"resumed"}"#), (200, #"{"activities":[]}"#)])
        _ = try await synchronize(client: client, database: db) { _ in }
        #expect(try await db.cursor("user") == "resumed")
        #expect(await FixtureProtocol.fixture.allRequests().count == 2)
        try await db.close()
    }
    @Test func metadataDiscoveryRetainsKnownDrivesWhenRootBecomesUnavailable() async throws {
        await FixtureProtocol.fixture.prepare([
            (200, #"{"startPageToken":"user-start"}"#),
            (200, #"{"files":[{"id":"shared-file","name":"Shared file","mimeType":"text/plain","driveId":"team"}]}"#),
            (200, #"{"changes":[],"newStartPageToken":"user-next"}"#),
            (200, #"{"id":"team","name":"Team","mimeType":"application/vnd.google-apps.folder"}"#),
            (200, #"{"startPageToken":"team-start"}"#),
            (200, #"{"files":[]}"#),
            (200, #"{"changes":[],"newStartPageToken":"team-next"}"#),
            (200, #"{"activities":[]}"#), (200, #"{"activities":[]}"#)
        ])
        let (db, _) = try temporaryDatabase(); let client = fixtureClient(FixtureTokens())
        let first = try await synchronize(client: client, database: db) { _ in }
        #expect(first.gaps.isEmpty); #expect(first.drives.map(\.name) == ["Team"])
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 9)
        #expect(requests.allSatisfy { $0.url?.path != "/drive/v3/drives" })
        #expect(requests[5].url?.query?.contains("corpora=drive") == true)
        #expect(requests[5].url?.query?.contains("driveId=team") == true)
        await FixtureProtocol.fixture.prepare([
            (200, #"{"changes":[{"changeType":"file","time":"2026-09-29T12:00:00Z","fileId":"shared-file","removed":true}],"newStartPageToken":"user-resumed"}"#),
            (403, #"{"error":{"code":403,"message":"Root unavailable","errors":[{"reason":"insufficientFilePermissions","domain":"global"}]}}"#),
            (200, #"{"changes":[],"newStartPageToken":"team-resumed"}"#),
            (200, #"{"activities":[]}"#), (200, #"{"activities":[]}"#)
        ])
        let second = try await synchronize(client: client, database: db) { _ in }
        #expect(second.gaps.count == 1); #expect(second.gaps[0].contains("insufficientFilePermissions")); #expect(!second.gaps[0].contains("Root unavailable"))
        #expect(second.drives.map(\.id) == ["team"]); #expect(try await db.files().isEmpty)
        #expect(try await db.cursor("user") == "user-resumed")
        #expect(try await db.cursor("team") == "team-resumed")
        #expect(await FixtureProtocol.fixture.allRequests().count == 5)
        try await db.close()
    }
    @Test func repeatedPageDoesNotPromotePartialIndex() async throws {
        await FixtureProtocol.fixture.prepare([
            (200, #"{"startPageToken":"initial"}"#),
            (200, #"{"files":[],"nextPageToken":"repeat"}"#), (200, #"{"files":[],"nextPageToken":"repeat"}"#),
            (200, #"{"activities":[]}"#)
        ])
        let (db, _) = try temporaryDatabase()
        let result = try await synchronize(client: fixtureClient(FixtureTokens()), database: db) { _ in }
        #expect(result.gaps.count == 1); #expect(result.gaps[0].contains("repeated")); #expect(try await db.cursor("user") == nil)
        try await db.close()
    }
    @Test func incompleteSearchPreservesPreviousEvidence() async throws {
        await FixtureProtocol.fixture.prepare([(200, #"{"startPageToken":"initial"}"#), (200, #"{"files":[],"incompleteSearch":true}"#), (403, #"{"error":{"message":"Activity disabled"}}"#)])
        let (db, _) = try temporaryDatabase()
        let result = try await synchronize(client: fixtureClient(FixtureTokens()), database: db) { _ in }
        #expect(result.gaps.count == 2); #expect(try await db.cursor("user") == nil)
        #expect(try await db.setting("activity.watermark.user") == nil)
        try await db.close()
    }
    @Test func authAndRateLimitRetriesThenSucceeds() async throws {
        await FixtureProtocol.fixture.prepare([(401, #"{"error":"expired"}"#), (429, #"{"error":"limited"}"#), (200, #"{"files":[]}"#)])
        let tokens = FixtureTokens()
        _ = try await fixtureClient(tokens).files(query: "", drive: nil, page: nil)
        #expect(await tokens.refreshCount() == 1)
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)
    }
    @Test func exhaustedRetriesSurfaceLastError() async throws {
        await FixtureProtocol.fixture.prepare(Array(repeating: (503, #"{"error":"fixture-unavailable"}"#), count: 4))
        await #expect(throws: MonitorError.self) { try await fixtureClient(FixtureTokens()).files(query: "", drive: nil, page: nil) }
        #expect(await FixtureProtocol.fixture.allRequests().count == 4)
    }
    @Test func repeatedAuthenticationFailureRefreshesOnlyOnce() async throws {
        await FixtureProtocol.fixture.prepareWithHeaders([(401, "expired-once", ["Retry-After": "0"]), (401, #"{"error":{"code":401,"message":"still-unauthorized","errors":[{"reason":"authError","domain":"global"}]}}"#, ["Retry-After": "0"])])
        let tokens = FixtureTokens()
        do {
            _ = try await fixtureClient(tokens).files(query: "", drive: nil, page: nil)
            Issue.record("A second authentication rejection must stop after one token refresh.")
        } catch let MonitorError.http(status, message) {
            #expect(status == 401); #expect(message.contains("authError")); #expect(!message.contains("still-unauthorized"))
        }
        #expect(await tokens.refreshCount() == 1)
        #expect(await FixtureProtocol.fixture.allRequests().count == 2)
    }
    @Test func networkRetryAfterAuthenticationRefreshDoesNotRefreshAgain() async throws {
        let readTokens = FixtureTokens()
        await FixtureProtocol.fixture.prepareWithFailures([.success((401, "expired-read", ["Retry-After": "0"])), .failure(URLError(.timedOut)), .success((200, #"{"files":[]}"#, [:]))])
        _ = try await fixtureClient(readTokens).files(query: "", drive: nil, page: nil)
        #expect(await readTokens.refreshCount() == 1)
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)

        let metadata = #"{"id":"refresh-test","name":"Refresh.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let downloadTokens = FixtureTokens(); await downloadTokens.grantManagement()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await FixtureProtocol.fixture.prepareWithFailures([.success((200, metadata, [:])), .success((401, "expired-download", ["Retry-After": "0"])), .failure(URLError(.timedOut)), .success((200, "hello", [:]))])
        try await fixtureClient(downloadTokens).download(file: file, to: destination)
        #expect(await downloadTokens.refreshCount() == 1)
        #expect(await FixtureProtocol.fixture.allRequests().count == 4)
        #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        try FileManager.default.removeItem(at: destination)

        let previewTokens = FixtureTokens(); await previewTokens.grantManagement()
        await FixtureProtocol.fixture.prepareWithFailures([.success((401, "expired-preview", ["Retry-After": "0"])), .failure(URLError(.timedOut)), .success((200, "hello", [:]))])
        let preview = try await fixtureClient(previewTokens).previewContent(file: file)
        #expect(await previewTokens.refreshCount() == 1)
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)
        #expect(preview.data == Data("hello".utf8))
    }
    @Test func batchTrashReportsPartialFailureAndContinuesReviewedItems() async throws {
        let firstJSON = #"{"id":"first","name":"First.txt","mimeType":"text/plain","capabilities":{"canTrash":true}}"#
        let deniedJSON = firstJSON.replacingOccurrences(of: "first", with: "denied")
        let lastJSON = firstJSON.replacingOccurrences(of: "first", with: "last")
        let files = try [firstJSON, deniedJSON, lastJSON].map { try JSONDecoder().decode(DriveFile.self, from: Data($0.utf8)) }
        let firstTrashed = firstJSON.replacingOccurrences(of: "\"capabilities\"", with: "\"trashed\":true,\"capabilities\"")
        let lastTrashed = lastJSON.replacingOccurrences(of: "\"capabilities\"", with: "\"trashed\":true,\"capabilities\"")
        await FixtureProtocol.fixture.prepare([(200, firstJSON), (200, firstTrashed), (200, deniedJSON), (403, #"{"error":{"code":403,"message":"Shared Drive policy denies trash","errors":[{"reason":"domainPolicy","domain":"global"}]}}"#), (200, lastJSON), (200, lastTrashed)])
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let report = await fixtureClient(tokens).trashBatch(confirmed: files) { _ in }
        #expect(report.completed == 2); #expect(report.failed == 1); #expect(report.remaining == 0); #expect(!report.cancelled)
        #expect(report.summary.hasPrefix("Finished with gaps"))
        #expect(report.results[1].failure?.contains("domainPolicy") == true)
        #expect(report.results[1].failure?.contains("Shared Drive policy denies trash") == false)
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 6)
        #expect(requests.filter { $0.httpMethod == "PATCH" }.count == 3)
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }
    @Test func cancelledBatchTrashRetainsConfirmedResultAndStopsFurtherRequests() async throws {
        let original = #"{"id":"first","name":"First.txt","mimeType":"text/plain","capabilities":{"canTrash":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(original.utf8))
        let second = DriveFile(id: "second", name: "Second.txt", mimeType: "text/plain")
        await FixtureProtocol.fixture.prepare([(200, original), (200, original.replacingOccurrences(of: "\"capabilities\"", with: "\"trashed\":true,\"capabilities\""))])
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let task = Task {
            await fixtureClient(tokens).trashBatch(confirmed: [file, second]) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let report = await task.value
        #expect(report.cancelled); #expect(report.completed == 1); #expect(report.remaining == 1); #expect(report.failed == 0)
        #expect(await FixtureProtocol.fixture.allRequests().count == 2)
    }
    @Test func confirmedTrashRecordsObservationWithoutInventingActivity() async throws {
        let original = #"{"id":"trash-test","name":"Test.txt","mimeType":"text/plain","parents":["folder"],"capabilities":{"canTrash":true}}"#
        let trashed = #"{"id":"trash-test","name":"Test.txt","mimeType":"text/plain","parents":["folder"],"trashed":true,"capabilities":{"canTrash":false}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(original.utf8))
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepare([(200, original), (200, trashed)])
        let result = try await fixtureClient(tokens).moveToTrash(confirmed: file)
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 2); #expect(requests[1].httpMethod == "PATCH")
        #expect(requests[1].url?.query?.contains("supportsAllDrives=true") == true)
        #expect(result.trashed == true)
        let (db, _) = try temporaryDatabase()
        try await db.stage([file], stream: "user")
        try await db.promote(stream: "user", cursor: "unchanged-cursor", detected: "2026-09-29T00:00:00Z")
        try await db.recordFileActionResult(result, detected: "2026-09-29T01:00:00Z")
        #expect(try await db.file(file.id)?.trashed == true)
        #expect(try await db.cursor("user") == "unchanged-cursor")
        #expect(try await db.events(fileID: file.id, limit: 10).isEmpty)
        #expect(try await db.snapshotRecords(file.id).count == 2)
        try await db.close()
    }
    @Test func trashRequiresGrantCapabilityAndUnchangedTarget() async throws {
        let original = #"{"id":"trash-test","name":"Test.txt","mimeType":"text/plain","parents":["folder"],"capabilities":{"canTrash":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(original.utf8))
        await FixtureProtocol.fixture.prepare([(200, original)])
        await #expect(throws: MonitorError.self) { try await fixtureClient(FixtureTokens()).moveToTrash(confirmed: file) }
        #expect(await FixtureProtocol.fixture.allRequests().count == 1)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        for denied in [original.replacingOccurrences(of: "true", with: "false"), original.replacingOccurrences(of: "Test.txt", with: "Renamed.txt")] {
            await FixtureProtocol.fixture.prepare([(200, denied)])
            await #expect(throws: MonitorError.self) { try await fixtureClient(tokens).moveToTrash(confirmed: file) }
            #expect(await FixtureProtocol.fixture.allRequests().count == 1)
        }
    }
    @Test func transientTrashFailureDoesNotReplayThePatch() async throws {
        let metadata = #"{"id":"retry-trash","name":"Disposable.txt","mimeType":"text/plain","capabilities":{"canTrash":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepareWithHeaders([(200, metadata, [:]), (503, #"{"error":{"code":503,"message":"mutation-unconfirmed","errors":[{"reason":"backendError","domain":"global"}]}}"#, ["Retry-After": "0"])])
        do {
            _ = try await fixtureClient(tokens).moveToTrash(confirmed: file)
            Issue.record("A transient mutation failure must remain unconfirmed instead of replaying its PATCH.")
        } catch let MonitorError.http(status, message) {
            #expect(status == 503); #expect(message.contains("backendError")); #expect(!message.contains("mutation-unconfirmed"))
        }
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 2)
        #expect(requests.filter { $0.httpMethod == "PATCH" }.count == 1)
    }
    @Test func previewDownloadsOnlyWithExplicitGrantAndCapability() async throws {
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(#"{"id":"preview-test","name":"Test.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#.utf8))
        await FixtureProtocol.fixture.prepare([])
        await #expect(throws: MonitorError.self) { try await fixtureClient(FixtureTokens()).previewContent(file: file) }
        #expect(await FixtureProtocol.fixture.allRequests().isEmpty)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepare([(200, "hello")])
        let content = try await fixtureClient(tokens).previewContent(file: file)
        #expect(content.data == Data("hello".utf8)); #expect(content.fileExtension == "txt")
        #expect(await FixtureProtocol.fixture.allRequests().first?.url?.query?.contains("alt=media") == true)
        var large = file; large.size = "20971521"
        await FixtureProtocol.fixture.prepare([])
        await #expect(throws: MonitorError.self) { try await fixtureClient(tokens).previewContent(file: large) }
        #expect(await FixtureProtocol.fixture.allRequests().isEmpty)
    }
    @Test func fileDownloadSavesOriginalAndPreservesDestinationOnFailure() async throws {
        let metadata = #"{"id":"download-test","name":"Test.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("saved.txt")
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "hello")])
        try await fixtureClient(tokens).download(file: file, to: destination)
        #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        #expect(await FixtureProtocol.fixture.allRequests().last?.url?.query?.contains("alt=media") == true)
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "again")])
        try await fixtureClient(tokens).download(file: file, to: destination)
        #expect(try Data(contentsOf: destination) == Data("again".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int == 0o600)
        await FixtureProtocol.fixture.prepare([(200, metadata), (403, #"{"error":{"message":"Download restricted"}}"#)])
        await #expect(throws: MonitorError.self) { try await fixtureClient(tokens).download(file: file, to: destination) }
        #expect(try Data(contentsOf: destination) == Data("again".utf8))
        await FixtureProtocol.fixture.prepare([(200, metadata)])
        await #expect(throws: MonitorError.self) { try await fixtureClient(FixtureTokens()).download(file: file, to: destination) }
        #expect(await FixtureProtocol.fixture.allRequests().count == 1)
        try FileManager.default.removeItem(at: directory)
    }
    @Test func googleReadRejectsInvalidRetryHeaderWithoutAnotherRequest() async throws {
        await FixtureProtocol.fixture.prepareWithHeaders([(503, "retry-header-test", ["Retry-After": "NaN"])])
        do {
            _ = try await fixtureClient(FixtureTokens()).files(query: "", drive: nil, page: nil)
            Issue.record("A malformed retry delay must fail before another Google request.")
        } catch let MonitorError.http(status, message) {
            #expect(status == 503); #expect(message.contains("Retry-After"))
        }
        #expect(await FixtureProtocol.fixture.allRequests().count == 1)
    }
    @Test func googleReadAndDownloadRejectRetryWaitBeyondBudget() async throws {
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        await FixtureProtocol.fixture.prepareWithHeaders([(429, "read-limited", ["Retry-After": "120"])])
        do {
            _ = try await client.files(query: "", drive: nil, page: nil)
            Issue.record("A read must stop instead of shortening Google's requested retry wait.")
        } catch let MonitorError.http(status, message) {
            #expect(status == 429); #expect(message.contains("60-second automatic retry wait budget"))
        }
        #expect(await FixtureProtocol.fixture.allRequests().count == 1)
        let metadata = #"{"id":"retry-test","name":"Retry.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("existing".utf8).write(to: destination)
        await FixtureProtocol.fixture.prepareWithHeaders([(200, metadata, [:]), (503, "download-limited", ["Retry-After": "120"])])
        do {
            try await client.download(file: file, to: destination)
            Issue.record("A download must stop instead of shortening Google's requested retry wait.")
        } catch let MonitorError.http(status, message) {
            #expect(status == 503); #expect(message.contains("60-second automatic retry wait budget"))
        }
        #expect(await FixtureProtocol.fixture.allRequests().count == 2)
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
        try FileManager.default.removeItem(at: destination)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let plan = DownloadPlan(items: [DownloadItem(file: file, components: ["limited.txt"]), DownloadItem(file: file, components: ["complete.txt"])], issues: [])
        await FixtureProtocol.fixture.prepareWithHeaders([(200, metadata, [:]), (429, "batch-limited", ["Retry-After": "120"]), (200, metadata, [:]), (200, "hello", [:])])
        let report = try await client.downloadBatch(plan: plan, parent: parent, progress: { _ in })
        #expect(report.completed == 1); #expect(report.failures == 1); #expect(report.remaining == 0)
        #expect(report.results.first?.message?.contains("60-second automatic retry wait budget") == true)
        #expect(await FixtureProtocol.fixture.allRequests().count == 4)
        #expect(!FileManager.default.fileExists(atPath: report.directory.appendingPathComponent("Files/limited.txt").path))
        #expect(try Data(contentsOf: report.directory.appendingPathComponent("Files/complete.txt")) == Data("hello".utf8))
        let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: report.directory.appendingPathComponent("download-report.json")))
        #expect(saved.completed == 1); #expect(saved.failures == 1); #expect(saved.remaining == 0)
        try FileManager.default.removeItem(at: parent)
    }
    @Test func cancelledDownloadDoesNotRetryRateLimitedResponse() async throws {
        let metadata = #"{"id":"retry-test","name":"Retry.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("existing".utf8).write(to: destination)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        await FixtureProtocol.fixture.prepareWithHeaders([(200, metadata, [:]), (429, "cancel-during-retry", ["Retry-After": "30"]), (200, "hello", [:])])
        let task = Task { try await client.download(file: file, to: destination) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var requested: Int = 0
        while requested < 2 && ContinuousClock.now < deadline {
            requested = await FixtureProtocol.fixture.allRequests().count
            if requested < 2 { await Task.yield() }
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancellation after a rate-limited response must stop the download.")
        } catch is CancellationError {
            #expect(task.isCancelled)
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(requested == 2)
        #expect(await FixtureProtocol.fixture.allRequests().count == 2)
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
        try FileManager.default.removeItem(at: destination)
    }
    @Test func downloadRetriesTransientResponseAndSavesSuccessfulBytes() async throws {
        let metadata = #"{"id":"retry-test","name":"Retry.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepareWithHeaders([(200, metadata, [:]), (503, "transient-download", ["Retry-After": "0"]), (200, "hello", [:])])
        try await fixtureClient(tokens).download(file: file, to: destination)
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)
        #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        try FileManager.default.removeItem(at: destination)
    }
    @Test func downloadExhaustionPreservesDestinationAndSurfacesLastHTTPFailure() async throws {
        let metadata = #"{"id":"retry-test","name":"Retry.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("existing".utf8).write(to: destination)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepareWithHeaders([(200, metadata, [:]), (503, "first-failure", ["Retry-After": "0"]), (503, "second-failure", ["Retry-After": "0"]), (503, "third-failure", ["Retry-After": "0"]), (504, #"{"error":{"code":504,"message":"last-download-failure","errors":[{"reason":"backendError","domain":"global"}]}}"#, ["Retry-After": "0"])])
        do {
            try await fixtureClient(tokens).download(file: file, to: destination)
            Issue.record("Exhausted retries must surface the last HTTP failure.")
        } catch let MonitorError.http(status, message) {
            #expect(status == 504); #expect(message.contains("backendError")); #expect(!message.contains("last-download-failure"))
        }
        #expect(await FixtureProtocol.fixture.allRequests().count == 5)
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
        try FileManager.default.removeItem(at: destination)
    }
    @Test func previewRejectsInvalidRetryHeaderWithoutAnotherRequest() async throws {
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(#"{"id":"retry-test","name":"Retry.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#.utf8))
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepareWithHeaders([(503, "preview-header-test", ["Retry-After": "NaN"])])
        do {
            _ = try await fixtureClient(tokens).previewContent(file: file)
            Issue.record("A malformed preview retry delay must fail before another Google request.")
        } catch let MonitorError.http(status, message) {
            #expect(status == 503); #expect(message.contains("Retry-After"))
        }
        #expect(await FixtureProtocol.fixture.allRequests().count == 1)
    }
    @Test func binarySizeMismatchPreservesDestinationAndReportsBatchFailure() async throws {
        let metadata = #"{"id":"size-test","name":"Size.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: destination)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        for body in ["hi", "too long"] {
            await FixtureProtocol.fixture.prepare([(200, metadata), (200, body)])
            await #expect(throws: MonitorError.self) { try await client.download(file: file, to: destination) }
            #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        }
        for size in ["invalid", "-1", "9223372036854775808"] {
            let invalid = metadata.replacingOccurrences(of: #""size":"5""#, with: "\"size\":\"\(size)\"")
            await FixtureProtocol.fixture.prepare([(200, invalid), (200, "hello")])
            await #expect(throws: MonitorError.self) { try await client.download(file: file, to: destination) }
            #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        }
        let plan = DownloadPlan(items: [DownloadItem(file: file, components: ["short.txt"]), DownloadItem(file: file, components: ["complete.txt"])], issues: [])
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "hi"), (200, metadata), (200, "hello")])
        let report = try await client.downloadBatch(plan: plan, parent: directory, progress: { _ in })
        #expect(report.completed == 1); #expect(report.failures == 1); #expect(report.remaining == 0)
        #expect(report.summary.hasPrefix("Finished with gaps"))
        #expect(report.results.first?.message?.contains("expected 5 bytes, received 2") == true)
        #expect(!FileManager.default.fileExists(atPath: report.directory.appendingPathComponent("Files/short.txt").path))
        #expect(try Data(contentsOf: report.directory.appendingPathComponent("Files/complete.txt")) == Data("hello".utf8))
        let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: report.directory.appendingPathComponent("download-report.json")))
        #expect(saved.failures == 1); #expect(saved.completed == 1)
        try FileManager.default.removeItem(at: directory)
    }
    @Test func checksumMismatchPreservesDestinationAndReportsBatchFailure() async throws {
        let metadata = #"{"id":"checksum-test","name":"Hash.txt","mimeType":"text/plain","size":"5","sha256Checksum":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: destination)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "wrong")])
        await #expect(throws: MonitorError.self) { try await client.download(file: file, to: destination) }
        #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        let plan = DownloadPlan(items: [DownloadItem(file: file, components: ["damaged.txt"]), DownloadItem(file: file, components: ["correct.txt"])], issues: [])
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "wrong"), (200, metadata), (200, "hello")])
        let report = try await client.downloadBatch(plan: plan, parent: directory, progress: { _ in })
        #expect(report.completed == 1); #expect(report.failures == 1); #expect(report.remaining == 0)
        #expect(report.results.first?.message?.contains("SHA-256 mismatch") == true)
        #expect(!FileManager.default.fileExists(atPath: report.directory.appendingPathComponent("Files/damaged.txt").path))
        #expect(try Data(contentsOf: report.directory.appendingPathComponent("Files/correct.txt")) == Data("hello".utf8))
        let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: report.directory.appendingPathComponent("download-report.json")))
        #expect(saved.failures == 1); #expect(saved.completed == 1)
        try FileManager.default.removeItem(at: directory)
    }
    @Test func documentDownloadUsesExportAndRejectsRestrictedContent() async throws {
        let metadata = #"{"id":"export-test","name":"Report","mimeType":"application/vnd.google-apps.document","size":"999","capabilities":{"canDownload":true}}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        #expect(try fileDownload(file).name == "Report.docx")
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "synthetic export")])
        try await fixtureClient(tokens).download(file: file, to: destination)
        #expect(try Data(contentsOf: destination) == Data("synthetic export".utf8))
        let request = try #require(await FixtureProtocol.fixture.allRequests().last)
        #expect(request.url?.path.hasSuffix("/export") == true)
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        var large = try JSONDecoder().decode(DriveFile.self, from: Data(#"{"id":"large","name":"../unsafe:name","mimeType":"text/plain","size":"20971521","capabilities":{"canDownload":true}}"#.utf8))
        #expect(try fileDownload(large).name == ".._unsafe_name")
        large.capabilities = nil
        #expect(throws: MonitorError.self) { try fileDownload(large) }
        try FileManager.default.removeItem(at: destination)
    }
    @Test func nestedBatchPreservesStructureAndReportsPartialFailures() async throws {
        let folder = #"{"id":"folder","name":"Project","mimeType":"application/vnd.google-apps.folder"}"#
        let first = #"{"id":"a","name":"Report.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        let second = #"{"id":"c","name":"report.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        let nested = #"{"id":"n","name":"Nested.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        let subfolder = #"{"id":"b","name":"Subfolder","mimeType":"application/vnd.google-apps.folder"}"#
        let shortcut = #"{"id":"d","name":"Link","mimeType":"application/vnd.google-apps.shortcut","shortcutDetails":{"targetId":"a"}}"#
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        await FixtureProtocol.fixture.prepare([(200, folder), (200, "{\"files\":[" + first + "," + subfolder + "],\"nextPageToken\":\"next\"}"), (200, "{\"files\":[" + second + "," + shortcut + "]}"), (200, "{\"files\":[" + nested + "]}")])
        let plan = try await client.planDownloads(ids: ["folder"], progress: { _ in })
        #expect(plan.items.map { $0.components.joined(separator: "/") } == ["Project", "Project/Report.txt", "Project/Subfolder", "Project/Subfolder/Nested.txt", "Project/report (2).txt"])
        #expect(plan.issues.count == 1)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await FixtureProtocol.fixture.prepare([(200, first), (200, "first"), (403, "restricted"), (200, second), (200, "second")])
        let report = try await client.downloadBatch(plan: plan, parent: parent, progress: { _ in })
        #expect(report.completed == 2); #expect(report.failures == 2); #expect(report.remaining == 0); #expect(!report.cancelled)
        #expect(report.summary.hasPrefix("Finished with gaps"))
        #expect(try String(contentsOf: report.directory.appendingPathComponent("Files/Project/Report.txt"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: report.directory.appendingPathComponent("Files/Project/report (2).txt"), encoding: .utf8) == "second")
        #expect(FileManager.default.fileExists(atPath: report.directory.appendingPathComponent("Files/Project/Subfolder").path))
        let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: report.directory.appendingPathComponent("download-report.json")))
        #expect(saved.completed == report.completed); #expect(saved.failures == report.failures)
        try FileManager.default.removeItem(at: parent)
    }
    @Test func folderDiscoveryRejectsIncompleteAndRepeatedPages() async throws {
        let folder = #"{"id":"folder","name":"Folder","mimeType":"application/vnd.google-apps.folder"}"#
        for pages in [[(200, folder), (200, #"{"incompleteSearch":true}"#)], [(200, folder), (200, #"{"nextPageToken":"again"}"#), (200, #"{"nextPageToken":"again"}"#)]] {
            await FixtureProtocol.fixture.prepare(pages)
            let plan = try await fixtureClient(FixtureTokens()).planDownloads(ids: ["folder"], progress: { _ in })
            #expect(plan.items.count == 1); #expect(plan.issues.count == 1)
        }
    }
    @Test func folderBatchPreservesUnicodeFilenameCollisionsWithoutOverwrites() async throws {
        let folder = #"{"id":"folder","name":"Project","mimeType":"application/vnd.google-apps.folder"}"#
        let names: [String] = ["Σ.txt", "ς.txt", "ß.txt", "ss.txt", "ſ.txt", "s.txt", "Café.txt", "Cafe\u{0301}.txt"]
        let expectedNames: [String] = ["Σ.txt", "ς (2).txt", "ß.txt", "ss (2).txt", "ſ.txt", "s (2).txt", "Café.txt", "Cafe\u{0301} (2).txt"]
        let metadata: [String] = try names.enumerated().map { index, name in
            var file = DriveFile(id: "file-\(index)", name: name, mimeType: "text/plain")
            file.capabilities = FileCapabilities(canDownload: true, canTrash: nil)
            return try encoded(file)
        }
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        await FixtureProtocol.fixture.prepare([(200, folder), (200, "{\"files\":[" + metadata.joined(separator: ",") + "]}")])
        let plan = try await client.planDownloads(ids: ["folder"], progress: { _ in })
        #expect(plan.issues.isEmpty)
        #expect(plan.items.map { $0.components.joined(separator: "/") } == ["Project"] + expectedNames.map { "Project/" + $0 })
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let responses: [(Int, String)] = metadata.enumerated().flatMap { index, value in [(200, value), (200, "content \(index)")] }
        await FixtureProtocol.fixture.prepare(responses)
        let report = try await client.downloadBatch(plan: plan, parent: parent, progress: { _ in })
        #expect(report.completed == names.count); #expect(report.failures == 0); #expect(report.remaining == 0)
        let output = report.directory.appendingPathComponent("Files/Project")
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).count == names.count)
        for (index, name) in expectedNames.enumerated() {
            #expect(try String(contentsOf: output.appendingPathComponent(name), encoding: .utf8) == "content \(index)")
        }
        try FileManager.default.removeItem(at: parent)
    }
    @Test func cancelledBatchRetainsCompletedFilesAndReportsUnattemptedItems() async throws {
        let metadata = #"{"id":"first","name":"First.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        let first = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let second = DriveFile(id: "second", name: "Second.txt", mimeType: "text/plain")
        let plan = DownloadPlan(items: [DownloadItem(file: first, components: [first.name]), DownloadItem(file: second, components: [second.name])], issues: [])
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "complete")])
        let task = Task {
            try await fixtureClient(tokens).downloadBatch(plan: plan, parent: parent) { progress in
                if progress.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = try await task.value
        #expect(report.cancelled); #expect(report.completed == 1); #expect(report.remaining == 1)
        #expect(try String(contentsOf: report.directory.appendingPathComponent("Files/First.txt"), encoding: .utf8) == "complete")
        #expect(!FileManager.default.fileExists(atPath: report.directory.appendingPathComponent("Files/Second.txt").path))
        #expect(report.unattempted == ["Second.txt"])
        let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: report.directory.appendingPathComponent("download-report.json")))
        #expect(saved.unattempted == report.unattempted)
        try FileManager.default.removeItem(at: parent)
    }
    @Test func reportSaveFailureRetainsOutcomesAndDoesNotOverwriteExistingContent() async throws {
        let metadata = #"{"id":"first","name":"Saved.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        let first = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let denied = DriveFile(id: "denied", name: "Denied.txt", mimeType: "text/plain")
        let last = DriveFile(id: "last", name: "Unattempted", mimeType: "application/vnd.google-apps.folder")
        let plan = DownloadPlan(items: [DownloadItem(file: first, components: [first.name]), DownloadItem(file: denied, components: [denied.name]), DownloadItem(file: last, components: [last.name])], issues: [DownloadIssue(path: "Shortcut", reason: "Shortcut skipped")])
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "saved bytes"), (403, "restricted")])
        let task = Task {
            do {
                _ = try await fixtureClient(tokens).downloadBatch(plan: plan, parent: parent) { value in
                    if value.completed == 0 {
                        do {
                            let directories = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                            let directory = try #require(directories.first)
                            try Data("existing report content".utf8).write(to: directory.appendingPathComponent("download-report.json"), options: .withoutOverwriting)
                        } catch { Issue.record(error) }
                    }
                    if value.completed == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                throw MonitorError.invalid("The occupied report path should reject report persistence.")
            } catch let failure as BatchDownloadReportSaveError { return failure }
        }
        let failure = try await task.value
        let report = failure.report
        #expect(report.cancelled); #expect(report.completed == 1); #expect(report.failures == 2)
        #expect(report.results.map(\.outcome) == [.downloaded, .failed])
        #expect(report.unattempted == ["Unattempted"])
        #expect(try String(contentsOf: report.directory.appendingPathComponent("Files/Saved.txt"), encoding: .utf8) == "saved bytes")
        #expect(try String(contentsOf: report.directory.appendingPathComponent("download-report.json"), encoding: .utf8) == "existing report content")
        #expect((failure.cause as NSError).code == NSFileWriteFileExistsError)
        #expect(failure.localizedDescription.contains("saving download-report.json failed"))
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)

        let original = BatchDownloadPresentation(id: UUID(), status: "Downloading…", progress: BatchProgress(current: last.name, discovered: 3, completed: 2, failed: 2), report: nil, reportSaveError: nil, finished: false)
        let presentation = original.reportingFailure(failure)
        #expect(presentation.id == original.id); #expect(presentation.finished)
        #expect(presentation.report?.completed == 1); #expect(presentation.report?.unattempted == report.unattempted)
        #expect(presentation.reportSaveError == failure.localizedDescription)
        #expect(presentation.status.contains("Report save failed"))
        #expect(original.report == nil); #expect(!original.finished)
        try FileManager.default.removeItem(at: parent)
    }
    @Test func cancellationBeforeFolderCreationReportsEveryUnattemptedPath() async throws {
        let folder = DriveFile(id: "folder", name: "Empty", mimeType: "application/vnd.google-apps.folder")
        let plan = DownloadPlan(items: [DownloadItem(file: folder, components: ["Empty"])], issues: [])
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await FixtureProtocol.fixture.prepare([])
        let task = Task {
            try await fixtureClient(FixtureTokens()).downloadBatch(plan: plan, parent: parent) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let report = try await task.value
        #expect(report.cancelled); #expect(report.results.isEmpty); #expect(report.unattempted == ["Empty"])
        #expect(!FileManager.default.fileExists(atPath: report.directory.appendingPathComponent("Files/Empty").path))
        #expect(await FixtureProtocol.fixture.allRequests().isEmpty)
        try FileManager.default.removeItem(at: parent)
    }
    @Test func folderBatchExportsDocumentsAndPreservesEmptyFolders() async throws {
        let folder = #"{"id":"folder","name":"Project","mimeType":"application/vnd.google-apps.folder"}"#
        let empty = #"{"id":"empty","name":"Empty","mimeType":"application/vnd.google-apps.folder"}"#
        let document = #"{"id":"a","name":"Report","mimeType":"application/vnd.google-apps.document","capabilities":{"canDownload":true}}"#
        let binary = #"{"id":"b","name":"Report.docx","mimeType":"application/octet-stream","capabilities":{"canDownload":true}}"#
        let sheet = #"{"id":"c","name":"Budget","mimeType":"application/vnd.google-apps.spreadsheet","capabilities":{"canDownload":true}}"#
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        await FixtureProtocol.fixture.prepare([(200, folder), (200, "{\"files\":[" + [document, binary, sheet, empty].joined(separator: ",") + "]}"), (200, #"{"files":[]}"#)])
        let plan = try await client.planDownloads(ids: ["folder"], progress: { _ in })
        #expect(plan.issues.isEmpty)
        #expect(plan.items.map { $0.components.joined(separator: "/") } == ["Project", "Project/Report.docx", "Project/Report (2).docx", "Project/Budget.xlsx", "Project/Empty"])
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await FixtureProtocol.fixture.prepare([(200, document), (200, "synthetic docx"), (200, binary), (200, "original binary"), (200, sheet), (403, #"{"error":{"code":403,"message":"private export detail","errors":[{"reason":"exportSizeLimitExceeded","domain":"global"}]}}"#)])
        let report = try await client.downloadBatch(plan: plan, parent: parent, progress: { _ in })
        #expect(report.completed == 2); #expect(report.failures == 1); #expect(report.unattempted.isEmpty)
        #expect(try String(contentsOf: report.directory.appendingPathComponent("Files/Project/Report.docx"), encoding: .utf8) == "synthetic docx")
        #expect(try String(contentsOf: report.directory.appendingPathComponent("Files/Project/Report (2).docx"), encoding: .utf8) == "original binary")
        #expect(try FileManager.default.contentsOfDirectory(atPath: report.directory.appendingPathComponent("Files/Project/Empty").path).isEmpty)
        #expect(report.results.first { $0.outcome == .failed }?.message?.contains("exportSizeLimitExceeded") == true)
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests[1].url?.path == "/drive/v3/files/a/export")
        #expect(requests[3].url?.path == "/drive/v3/files/b")
        #expect(requests[5].url?.path == "/drive/v3/files/c/export")
        let exportQuery = URLComponents(url: requests[5].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(exportQuery?.first { $0.name == "mimeType" }?.value == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        try FileManager.default.removeItem(at: parent)
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
    #expect(throws: MonitorError.self) { try OAuthConfiguration.load(Data(#"{"web":{"client_id":"wrong.apps.googleusercontent.com"}}"#.utf8)) }
    for invalid in ["{", #"{"type":"service_account"}"#, #"{"installed":{"client_id":".apps.googleusercontent.com"}}"#, #"{"installed":{"client_id":"https://bad.apps.googleusercontent.com"}}"#, #"{"installed":{"client_id":42}}"#] {
        #expect(throws: MonitorError.self) { try OAuthConfiguration.load(Data(invalid.utf8)) }
    }
    let withoutSecret = try OAuthConfiguration.load(Data(#"{"installed":{"client_id":"123-synthetic.apps.googleusercontent.com","extra":"ignored"}}"#.utf8))
    #expect(withoutSecret.installed.client_secret == nil)
    #expect(throws: MonitorError.self) { try OAuthConfiguration.load(Data(repeating: 32, count: 1_048_577)) }
    let verifier = try randomURLToken(); #expect(verifier.count == 43)
    let url = authorizationURL(clientID: "synthetic", redirect: "http://127.0.0.1:1234/oauth/callback", state: "state-value", verifier: verifier, access: .metadata)
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
    let groups = storageGroups([document], key: storageType, label: { storageTitle($0, index: [:], drives: []) })
    #expect(groups.first?.bytes == nil)
    #expect(groups.first?.unknown == 1)
    #expect(sumKnown([]) == nil)
    #expect(sumKnown([0]) == 0)
}

@Test func fileTablePagesCoverEveryMatchWithoutChangingOrdering() {
    let source = Array(0..<230004)
    let pages = (0..<461).flatMap { page in Array(source[filePageRange(total: source.count, page: page)]) }
    #expect(pages == source)
    #expect(filePageRange(total: 0, page: 12).isEmpty)
    #expect(filePageRange(total: 4, page: 99) == 0..<4)
    #expect(filePageRange(total: 1000, page: 1) == 500..<1000)
    #expect(filePageRange(total: Int.max, page: Int.max).upperBound == Int.max)
}

/// A failed confirmation must keep the item reviewable and surface the reason without touching Google.
@Test @MainActor func failedTrashConfirmationKeepsReviewOpen() async throws {
    let model = AppModel()
    let file = try JSONDecoder().decode(DriveFile.self, from: Data(#"{"id":"trash-review","name":"Review.txt","mimeType":"text/plain"}"#.utf8))
    model.pendingTrash = file
    model.confirmTrash(file)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.busy)
    #expect(model.pendingTrash?.id == file.id)
    #expect(model.error?.contains("connected Google account") == true)
    #expect(model.operationNotice == nil)
}

@Test func cancelledDownloadSavePreservesExistingFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source")
    let destination = directory.appendingPathComponent("destination")
    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try saveDownloadedFile(source, to: destination)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    try FileManager.default.removeItem(at: directory)
}

@Test func batchFileCommitNeverOverwritesExistingPaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source")
    let destination = directory.appendingPathComponent("destination")
    try Data("new".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination)
    #expect(throws: (any Error).self) { try saveNewDownloadedFile(source, to: destination) }
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    let link = directory.appendingPathComponent("existing-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    #expect(throws: MonitorError.self) { try saveNewDownloadedFile(source, to: link) }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination.path)
    #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    let dangling = directory.appendingPathComponent("dangling-link")
    try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "missing-target")
    #expect(throws: MonitorError.self) { try saveNewDownloadedFile(source, to: dangling) }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path) == "missing-target")
    let fresh = directory.appendingPathComponent("fresh")
    try saveNewDownloadedFile(source, to: fresh)
    #expect(try Data(contentsOf: fresh) == Data("new".utf8))
    #expect(try FileManager.default.attributesOfItem(atPath: fresh.path)[.referenceCount] as? Int == 1)
    try validateBatchDestination(directory)
    #expect(throws: MonitorError.self) { try validateBatchDestination(source) }
    #expect(try availableDownloadName("Report.txt", occupiedKeys: ["report.txt"]) == "Report (2).txt")
    #expect(throws: MonitorError.self) { try availableDownloadName("..", occupiedKeys: []) }
    try FileManager.default.removeItem(at: directory)
}
