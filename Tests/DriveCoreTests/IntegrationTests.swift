import Foundation
import Testing
import UserNotifications
@testable import DriveCore
@testable import DriveExplorer

@Test func notificationPermissionMustAllowDelivery() throws {
    try requireNotificationAuthorization(.authorized)
    try requireNotificationAuthorization(.provisional)
    for status: UNAuthorizationStatus in [.notDetermined, .denied] {
        #expect(throws: MonitorError.self) { try requireNotificationAuthorization(status) }
    }
}

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
            (403, #"{"error":{"message":"Root unavailable"}}"#),
            (200, #"{"changes":[],"newStartPageToken":"team-resumed"}"#),
            (200, #"{"activities":[]}"#), (200, #"{"activities":[]}"#)
        ])
        let second = try await synchronize(client: client, database: db) { _ in }
        #expect(second.gaps.count == 1); #expect(second.gaps[0].contains("Root unavailable"))
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
    @Test func documentDownloadUsesExportAndRejectsRestrictedContent() async throws {
        let metadata = #"{"id":"export-test","name":"Report","mimeType":"application/vnd.google-apps.document","capabilities":{"canDownload":true}}"#
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
    let groups = storageGroups([document]) { $0.mimeType }
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
    #expect(try availableDownloadName("Report.txt", occupied: ["report.txt"]) == "Report (2).txt")
    #expect(throws: MonitorError.self) { try availableDownloadName("..", occupied: []) }
    try FileManager.default.removeItem(at: directory)
}
