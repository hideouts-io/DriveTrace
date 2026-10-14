import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

private struct SyncFixtureResponse: Sendable {
    let status: Int
    let body: String
}

private actor SyncFixtureResponses {
    private var responses: [Result<SyncFixtureResponse, URLError>] = []
    private var requests: [URLRequest] = []
    private var heldRequest: Int?
    private var heldID: UUID?
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare(_ values: [Result<SyncFixtureResponse, URLError>]) throws {
        guard continuation == nil else { throw MonitorError.invalid("The prior synchronization fixture response is still held.") }
        responses = values; requests = []; heldRequest = nil; heldID = nil
    }
    func holdResponse(_ request: Int) { heldRequest = request }
    func next(_ request: URLRequest, id: UUID) async throws -> SyncFixtureResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw MonitorError.invalid("Unexpected synchronization fixture request.") }
        let response = responses.removeFirst()
        if requests.count == heldRequest {
            heldID = id
            await withCheckedContinuation { continuation = $0 }
        }
        return try response.get()
    }
    func releaseHeldResponse() { continuation?.resume(); continuation = nil; heldID = nil }
    func cancelResponse(_ id: UUID) { if heldID == id { releaseHeldResponse() } }
    func allRequests() -> [URLRequest] { requests }
}

private final class SyncFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let responses = SyncFixtureResponses()
    private let requestID = UUID()
    private var loading: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        loading = Task {
            do {
                let result = try await Self.responses.next(request, id: requestID)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(result.body.utf8)); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {
        loading?.cancel()
        let id = requestID
        Task { await Self.responses.cancelResponse(id) }
    }
}

@MainActor private func waitForSyncFixture(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.busy || model.searching {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Synchronization fixture did not complete before the test deadline.") }
        await Task.yield()
    }
}

private func waitForSyncRequests(_ count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await SyncFixtureProtocol.responses.allRequests().count < count {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Synchronization fixture did not receive the expected request before the test deadline.") }
        await Task.yield()
    }
}

private func savedAccountCachePreference() throws -> String? {
    guard let existing = UserDefaults.standard.object(forKey: "accountCache") else { return nil }
    guard let value = existing as? String else { throw MonitorError.invalid("The accountCache preference is not a string; the synchronization test refused to modify it.") }
    return value
}

extension GoogleIntegrationTests {
    @Test @MainActor func syncCancellationRetainsCommittedPagesAndSupportsContinuation() async throws {
        let originalAccount = try savedAccountCachePreference()
        let root = DriveFile(id: "synthetic-sync-root", name: "Synthetic root", mimeType: "application/vnd.google-apps.folder")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drivetrace-sync-cancellation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("drive.sqlite").path
        var database = try Database(path: path)
        var databaseOpen = true
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SyncFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = AppModel()
        model.client = GoogleClient(tokens: FixtureTokens(), session: session)
        model.database = database
        let previous = sample("previous", name: "Previous", size: nil)
        model.files = [previous]; model.results = [previous]
        UserDefaults.standard.set(digest(root.id), forKey: "accountCache")
        defer {
            model.cancel()
            if let originalAccount { UserDefaults.standard.set(originalAccount, forKey: "accountCache") }
            else { UserDefaults.standard.removeObject(forKey: "accountCache") }
        }
        do {
            let earlierSync = "2026-10-01T00:00:00Z"
            try await database.beginBaseline(stream: "user")
            try await database.stage([previous], stream: "user")
            try await database.promote(stream: "user", cursor: "initial-cursor", detected: earlierSync)
            try await database.setSetting("lastSync", value: earlierSync)

            // Cancellation before the runner starts must not imply a page was saved.
            try await SyncFixtureProtocol.responses.prepare([])
            model.syncVerified = true; model.sync(); model.cancel()
            try await waitForSyncFixture(model)
            #expect(await SyncFixtureProtocol.responses.allRequests().isEmpty)
            #expect(try await database.files() == [previous]); #expect(try await database.cursor("user") == "initial-cursor")
            #expect(try await database.setting("lastSync") == earlierSync)
            #expect(!model.syncVerified); #expect(model.error == nil); #expect(model.progress.isEmpty)
            #expect(model.operationNotice?.contains("Any committed observations") == true)

            // URLSession's cancelled error is also cancellation, even without cancelling the runner task.
            try await SyncFixtureProtocol.responses.prepare([.failure(URLError(.cancelled))])
            model.syncVerified = true; model.sync(); try await waitForSyncFixture(model)
            #expect(await SyncFixtureProtocol.responses.allRequests().count == 1)
            #expect(try await database.files() == [previous]); #expect(try await database.cursor("user") == "initial-cursor")
            #expect(try await database.setting("lastSync") == earlierSync)
            #expect(!model.syncVerified); #expect(model.error == nil)
            #expect(model.operationNotice?.contains("Choose Refresh to continue.") == true)

            let rootBody = try encoded(root)
            let firstPage = #"{"changes":[{"changeType":"file","time":"2026-10-08T00:00:00Z","fileId":"first","file":{"id":"first","name":"First","mimeType":"text/plain","trashed":false}}],"nextPageToken":"second-cursor"}"#
            let finalPage = #"{"changes":[{"changeType":"file","time":"2026-10-08T01:00:00Z","fileId":"second","file":{"id":"second","name":"Second","mimeType":"text/plain","trashed":false}}],"newStartPageToken":"final-cursor"}"#
            try await SyncFixtureProtocol.responses.prepare([
                .success(SyncFixtureResponse(status: 200, body: rootBody)),
                .success(SyncFixtureResponse(status: 200, body: firstPage)),
                .success(SyncFixtureResponse(status: 200, body: finalPage))
            ])
            await SyncFixtureProtocol.responses.holdResponse(3)
            model.syncVerified = true; model.sync(); try await waitForSyncRequests(3)
            #expect(try await database.file("first")?.name == "First")
            #expect(try await database.cursor("user") == "second-cursor")
            model.cancel(); try await waitForSyncFixture(model)
            await SyncFixtureProtocol.responses.releaseHeldResponse()
            #expect(await SyncFixtureProtocol.responses.allRequests().count == 3)
            #expect(try await database.file("second") == nil)
            #expect(try await database.setting("lastSync") == earlierSync)
            #expect(try await database.setting("activity.watermark.user") == nil)
            #expect(model.files == [previous]); #expect(model.results == [previous])
            #expect(!model.syncVerified); #expect(!model.busy); #expect(model.error == nil); #expect(model.progress.isEmpty)
            #expect(model.operationNotice?.contains("displayed results may be older") == true)
            #expect(model.operationNotice?.contains("An interrupted initial scan restarts.") == true)
            let cancelledRequests = await SyncFixtureProtocol.responses.allRequests()
            #expect(cancelledRequests.map { $0.url?.path } == ["/drive/v3/files/root", "/drive/v3/changes", "/drive/v3/changes"])

            try await database.close(); databaseOpen = false
            database = try Database(path: path); databaseOpen = true; model.database = database
            #expect(try await database.file("first")?.name == "First")
            #expect(try await database.file("second") == nil)
            #expect(try await database.cursor("user") == "second-cursor")
            #expect(try await database.setting("lastSync") == earlierSync)

            // Authorization failures still surface as errors, not cancellation notices.
            try await SyncFixtureProtocol.responses.prepare([.success(SyncFixtureResponse(status: 403, body: #"{"error":{"code":403,"errors":[{"domain":"global","reason":"insufficientFilePermissions"}]}}"#))])
            model.sync(); try await waitForSyncFixture(model)
            #expect(model.error?.contains("HTTP 403") == true); #expect(model.error?.contains("insufficientFilePermissions") == true)
            #expect(model.operationNotice == nil); #expect(!model.syncVerified)
            #expect(try await database.cursor("user") == "second-cursor")

            try await SyncFixtureProtocol.responses.prepare([
                .success(SyncFixtureResponse(status: 200, body: rootBody)),
                .success(SyncFixtureResponse(status: 200, body: finalPage)),
                .success(SyncFixtureResponse(status: 200, body: #"{"activities":[]}"#))
            ])
            model.sync(); try await waitForSyncFixture(model)
            let resumedRequests = await SyncFixtureProtocol.responses.allRequests()
            #expect(resumedRequests.count == 3)
            let resumedURL = try #require(resumedRequests[1].url)
            let query = try #require(URLComponents(url: resumedURL, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.first { $0.name == "pageToken" }?.value == "second-cursor")
            #expect(try await database.cursor("user") == "final-cursor")
            #expect(try await database.setting("lastSync") != earlierSync)
            #expect(try await database.setting("activity.watermark.user") != nil)
            #expect(Set(model.files.map(\.id)) == ["previous", "first", "second"])
            #expect(Set(model.results.map(\.id)) == ["previous", "first", "second"])
            #expect(model.syncVerified); #expect(model.error == nil); #expect(model.operationNotice == nil)
        } catch {
            let cause = error
            model.cancel()
            session.invalidateAndCancel()
            await SyncFixtureProtocol.responses.releaseHeldResponse()
            do {
                try await waitForSyncFixture(model)
                if databaseOpen { try await database.close() }
                try FileManager.default.removeItem(at: directory)
            } catch { throw MonitorError.invalid("Synchronization test failed: \(cause.localizedDescription). Task-owned cleanup also failed: \(error.localizedDescription)") }
            throw cause
        }
        session.invalidateAndCancel()
        try await database.close()
        try FileManager.default.removeItem(at: directory)
    }
}
