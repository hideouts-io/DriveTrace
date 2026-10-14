import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

private struct SingleFileResponse: Sendable {
    let status: Int
    let body: String
}

/// A separate transport keeps these serialized cases independent of the integration suite's response queue.
private actor SingleFileResponses {
    private var responses: [SingleFileResponse] = []
    private var requests: [URLRequest] = []
    private var heldRequest: Int?
    private var heldID: UUID?
    private var continuation: CheckedContinuation<Void, Never>?

    func prepare(_ values: [SingleFileResponse], heldRequest: Int?) throws {
        guard continuation == nil else { throw MonitorError.invalid("The previous single-file response remains held.") }
        responses = values; requests = []; self.heldRequest = heldRequest; heldID = nil
    }
    func next(_ request: URLRequest, id: UUID) async throws -> SingleFileResponse {
        guard let url = request.url, url.scheme == "https", url.host == "www.googleapis.com",
              url.path == "/drive/v3/files/single-file", request.httpMethod == "GET" else {
            throw MonitorError.invalid("The single-file fixture received an unexpected request target or method.")
        }
        requests.append(request)
        guard !responses.isEmpty else { throw MonitorError.invalid("Unexpected single-file fixture request.") }
        let response = responses.removeFirst()
        if requests.count == heldRequest {
            heldID = id
            await withCheckedContinuation { continuation = $0 }
        }
        return response
    }
    func release() { continuation?.resume(); continuation = nil; heldID = nil }
    func cancel(_ id: UUID) { if heldID == id { release() } }
    func allRequests() -> [URLRequest] { requests }
}

private final class SingleFileProtocol: URLProtocol, @unchecked Sendable {
    static let responses = SingleFileResponses()
    private let requestID = UUID()
    private var loading: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        loading = Task { @Sendable [self] in
            do {
                let result = try await Self.responses.next(request, id: requestID)
                try Task.checkCancellation()
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "0"]) else {
                    throw MonitorError.invalid("The single-file fixture could not create its HTTP response.")
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(result.body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {
        loading?.cancel()
        let id = requestID
        let responses = Self.responses
        Task { @Sendable [responses, id] in await responses.cancel(id) }
    }
}

private actor SingleFileTokens: TokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "single-file-synthetic-token" }
    func grantedScopes() -> Set<String> { ["https://www.googleapis.com/auth/drive"] }
}

private let singleFileMetadata = #"{"id":"single-file","name":"Selected.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#

/// Real task-owned files and synthetic HTTP only; no app startup, account restoration, or credential writes.
@Suite(.serialized) struct SingleFileRecoveryTests {
    @Test @MainActor func committedDownloadPublishesSavedNoticeAndExactBytes() async throws {
        let directory = try singleFileDirectory()
        defer { removeSingleFileDirectory(directory) }
        let destination = directory.appendingPathComponent("Selected.txt")
        let model = AppModel(previewStore: PreviewStore(root: directory.appendingPathComponent("previews", isDirectory: true)))
        let (client, session) = singleFileClient()
        defer { session.invalidateAndCancel() }
        try await SingleFileProtocol.responses.prepare([
            SingleFileResponse(status: 200, body: singleFileMetadata),
            SingleFileResponse(status: 200, body: "hello")
        ], heldRequest: nil)

        try await model.saveFileDownload(singleFileFixture(), client: client, destination: destination)

        #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        #expect(model.operationNotice == "Download saved to \(destination.path).")
        #expect(model.error == nil)
        let permissions = try #require(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)
        let requests = await SingleFileProtocol.responses.allRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.last?.url?.query?.contains("alt=media") == true)
    }

    @Test @MainActor func realStagingCleanupFailureKeepsSavedPresentationAndOriginalCause() async throws {
        let manager = FileManager.default
        let directory = try singleFileDirectory()
        var staging: URL?
        defer {
            do {
                if let staging {
                    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
                    try manager.removeItem(at: staging)
                }
                try manager.removeItem(at: directory)
            } catch { Issue.record(error) }
        }
        let destination = directory.appendingPathComponent("Selected.txt")
        let source = directory.appendingPathComponent("source")
        let bytes = Data("committed single-file content".utf8)
        try bytes.write(to: source, options: .withoutOverwriting)
        let model = AppModel(previewStore: PreviewStore(root: directory.appendingPathComponent("previews", isDirectory: true)))
        model.operationNotice = "Earlier operation"
        try await SingleFileProtocol.responses.prepare([], heldRequest: nil)

        do {
            try stageDownloadedFile(source, destination: destination) { staged in
                let temporary = staged.deletingLastPathComponent()
                staging = temporary
                try manager.moveItem(at: staged, to: destination)
                try Data("task-owned cleanup obstruction".utf8).write(to: temporary.appendingPathComponent("obstruction"), options: .withoutOverwriting)
                try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: temporary.path)
            }
            Issue.record("The committed single-file download must expose the inaccessible staging cleanup failure.")
        } catch let warning as SavedDownloadCleanupError {
            // Feed the actual filesystem failure through the production presentation boundary; no HTTP failure is fabricated.
            model.showSavedDownloadCleanup(warning)
            #expect(warning.destination == destination)
            #expect(warning.failures.count == 1)
            let failure = try #require(warning.failures.first)
            #expect(failure.temporary == staging)
            #expect((failure.cause as NSError).domain == NSCocoaErrorDomain)
            #expect((failure.cause as NSError).code == NSFileWriteNoPermissionError)
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(try Data(contentsOf: source) == bytes)
            #expect(model.operationNotice == "Download saved to \(destination.path). Temporary cleanup needs attention.")
            #expect(model.error == warning.localizedDescription)
            #expect(model.error?.contains(try #require(staging).path) == true)
            #expect(model.error?.contains("Review the saved file before downloading again") == true)
            #expect(await SingleFileProtocol.responses.allRequests().isEmpty)
        }
    }

    @Test @MainActor func deniedDownloadPreservesExistingDestinationAndSurfacesRecovery() async throws {
        let directory = try singleFileDirectory()
        defer { removeSingleFileDirectory(directory) }
        let destination = directory.appendingPathComponent("Selected.txt")
        let existing = Data("existing local content".utf8)
        try existing.write(to: destination, options: .withoutOverwriting)
        let model = AppModel(previewStore: PreviewStore(root: directory.appendingPathComponent("previews", isDirectory: true)))
        let (client, session) = singleFileClient()
        defer { session.invalidateAndCancel() }
        try await SingleFileProtocol.responses.prepare([
            SingleFileResponse(status: 200, body: singleFileMetadata),
            SingleFileResponse(status: 403, body: #"{"error":{"code":403,"errors":[{"domain":"global","reason":"insufficientFilePermissions"}]}}"#)
        ], heldRequest: nil)

        do {
            try await model.saveFileDownload(singleFileFixture(), client: client, destination: destination)
            Issue.record("A denied download must not publish a saved outcome.")
        } catch let failure as FileDownloadFailure {
            #expect(failure.destination == destination)
            #expect(failure.localizedDescription.contains("HTTP 403"))
            #expect(failure.localizedDescription.contains("insufficientFilePermissions"))
            #expect(failure.localizedDescription.contains(destination.path))
            #expect(failure.localizedDescription.contains("choose Download to retry"))
        }
        #expect(try Data(contentsOf: destination) == existing)
        #expect(model.operationNotice == nil)
        #expect(await SingleFileProtocol.responses.allRequests().count == 2)
    }

    @Test @MainActor func cancellingHeldDownloadPreservesExistingDestination() async throws {
        let directory = try singleFileDirectory()
        defer { removeSingleFileDirectory(directory) }
        let destination = directory.appendingPathComponent("Selected.txt")
        let existing = Data("keep this file on cancellation".utf8)
        try existing.write(to: destination, options: .withoutOverwriting)
        let model = AppModel(previewStore: PreviewStore(root: directory.appendingPathComponent("previews", isDirectory: true)))
        let (client, session) = singleFileClient()
        try await SingleFileProtocol.responses.prepare([
            SingleFileResponse(status: 200, body: singleFileMetadata),
            SingleFileResponse(status: 200, body: "hello")
        ], heldRequest: 2)
        let completion = SingleFileCompletion()
        let task = Task {
            do { try await model.saveFileDownload(singleFileFixture(), client: client, destination: destination); await completion.finish(.success(())) }
            catch { await completion.finish(.failure(error)) }
        }
        do {
            try await waitForSingleFileRequests(2)
            task.cancel()
            let result = try await waitForSingleFileCompletion(completion)
            switch result {
            case .success: Issue.record("A cancelled held download must not commit its destination.")
            case .failure(let error): #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            #expect(try Data(contentsOf: destination) == existing)
            #expect(model.operationNotice == nil)
            #expect(await SingleFileProtocol.responses.allRequests().count == 2)
        } catch {
            let cause = error
            task.cancel(); session.invalidateAndCancel()
            await SingleFileProtocol.responses.release()
            do { _ = try await waitForSingleFileCompletion(completion); await task.value }
            catch { throw MonitorError.invalid("The single-file cancellation check failed: \(cause.localizedDescription). Task-owned cleanup also failed: \(error.localizedDescription)") }
            throw cause
        }
        await task.value
        session.invalidateAndCancel()
        await SingleFileProtocol.responses.release()
    }

    @Test @MainActor func immediateFileActionCancellationReturnsUsableStateWithoutCredentials() async throws {
        let directory = try singleFileDirectory()
        defer { removeSingleFileDirectory(directory) }
        let model = AppModel(previewStore: PreviewStore(root: directory.appendingPathComponent("previews", isDirectory: true)))
        let file = try singleFileFixture()
        #expect(!(await model.credentials.hasConfiguration()))
        #expect(await model.credentials.grantedScopes().isEmpty)
        let previous = try await model.previewStore.save(PreviewContent(data: Data("previous preview".utf8), fileExtension: "txt"), name: "Previous")
        model.preview = previous

        model.downloadFile(file)
        #expect(model.busy)
        // Cancellation precedes the operation's first MainActor turn and any account or panel work.
        model.cancel()
        try await finishSingleFileModelOperation(model)
        #expect(model.operationNotice?.contains("Download cancelled before a destination was confirmed") == true)
        #expect(model.operationNotice?.contains("Choose Download") == true)
        #expect(model.preview?.id == previous.id)
        #expect(model.error == nil)

        model.showPreview(file)
        #expect(model.busy)
        model.cancel()
        try await finishSingleFileModelOperation(model)
        #expect(model.operationNotice?.contains("Preview cancelled") == true)
        #expect(model.operationNotice?.contains("previously displayed preview remains available") == true)
        #expect(model.operationNotice?.contains("Choose Preview file") == true)
        #expect(model.preview?.id == previous.id)
        #expect(try Data(contentsOf: previous.url) == Data("previous preview".utf8))
        #expect(model.error == nil)
        #expect(!(await model.credentials.hasConfiguration()))
        #expect(await model.credentials.grantedScopes().isEmpty)
    }

    @Test @MainActor func previewPublicationRejectsCancelledAndRestoredSelectionRequests() async throws {
        let directory = try singleFileDirectory()
        defer { removeSingleFileDirectory(directory) }
        let previewDirectory = directory.appendingPathComponent("previews", isDirectory: true)
        let model = AppModel(previewStore: PreviewStore(root: previewDirectory))
        model.selectedFiles = ["first"]
        let content = PreviewContent(data: Data("valid preview".utf8), fileExtension: "txt")
        try await model.publishPreview(content, name: "First preview", generation: model.previewGeneration)
        let previous = try #require(model.preview)
        #expect(try Data(contentsOf: previous.url) == content.data)
        let permissions = try #require(try FileManager.default.attributesOfItem(atPath: previous.url.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await model.publishPreview(PreviewContent(data: Data("must not publish".utf8), fileExtension: "txt"), name: "Cancelled", generation: model.previewGeneration)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(model.preview?.id == previous.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: previewDirectory.path).count == 1)

        let staleGeneration = model.previewGeneration
        model.selectedFiles = ["second"]
        model.selectedFiles = ["first"]
        #expect(model.previewGeneration > staleGeneration)
        await #expect(throws: PreviewSupersededError.self) {
            try await model.publishPreview(PreviewContent(data: Data("stale selection".utf8), fileExtension: "txt"), name: "Stale", generation: staleGeneration)
        }
        #expect(model.preview?.id == previous.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: previewDirectory.path).count == 1)

        let current = PreviewContent(data: Data("current preview".utf8), fileExtension: "txt")
        try await model.publishPreview(current, name: "Current", generation: model.previewGeneration)
        let published = try #require(model.preview)
        #expect(published.id != previous.id)
        #expect(published.name == "Current")
        #expect(try Data(contentsOf: published.url) == current.data)
        #expect(try Data(contentsOf: previous.url) == content.data)
    }

    @Test @MainActor func deniedPreviewStorageKeepsEarlierPreviewAndSupportsRetry() async throws {
        let directory = try singleFileDirectory()
        defer { removeSingleFileDirectory(directory) }
        let manager = FileManager.default
        let parent = directory.appendingPathComponent("preview-parent", isDirectory: true)
        let previewDirectory = parent.appendingPathComponent("previews", isDirectory: true)
        let model = AppModel(previewStore: PreviewStore(root: previewDirectory))
        let earlier = PreviewContent(data: Data("earlier accessible preview".utf8), fileExtension: "txt")
        try await model.publishPreview(earlier, name: "Earlier", generation: model.previewGeneration)
        let previous = try #require(model.preview)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer {
            do { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
            catch { Issue.record(error) }
        }

        do {
            try await model.publishPreview(PreviewContent(data: Data("unpublished".utf8), fileExtension: "txt"), name: "Denied", generation: model.previewGeneration)
            Issue.record("Saving through the inaccessible parent must fail without replacing the earlier preview.")
        } catch {
            #expect(error.localizedDescription.contains("could not be saved"))
            #expect(error.localizedDescription.contains(previewDirectory.path))
            #expect(error.localizedDescription.contains("permissions"))
            #expect(error.localizedDescription.contains("request the preview again"))
        }
        #expect(model.preview?.id == previous.id)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        #expect(try Data(contentsOf: previous.url) == earlier.data)
        #expect(try manager.contentsOfDirectory(atPath: previewDirectory.path).count == 1)
        let retry = PreviewContent(data: Data("retry after correcting permissions".utf8), fileExtension: "txt")
        try await model.publishPreview(retry, name: "Retried", generation: model.previewGeneration)
        let published = try #require(model.preview)
        #expect(published.id != previous.id)
        #expect(try Data(contentsOf: published.url) == retry.data)
    }
}

private func singleFileFixture() throws -> DriveFile {
    try JSONDecoder().decode(DriveFile.self, from: Data(singleFileMetadata.utf8))
}

private func singleFileClient() -> (GoogleClient, URLSession) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SingleFileProtocol.self]
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    let session = URLSession(configuration: configuration)
    return (GoogleClient(tokens: SingleFileTokens(), session: session), session)
}

private func singleFileDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

private func removeSingleFileDirectory(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record(error) }
}

private actor SingleFileCompletion {
    private var value: Result<Void, Error>?
    func finish(_ result: Result<Void, Error>) { value = result }
    func result() -> Result<Void, Error>? { value }
}

private func waitForSingleFileCompletion(_ completion: SingleFileCompletion) async throws -> Result<Void, Error> {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
        if let result = await completion.result() { return result }
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The single-file operation did not finish before the test deadline.") }
        await Task.yield()
    }
}

private func waitForSingleFileRequests(_ count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await SingleFileProtocol.responses.allRequests().count < count {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The single-file transfer did not reach its held response before the test deadline.") }
        await Task.yield()
    }
}

@MainActor private func waitForSingleFileModelOperation(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.busy {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The cancelled file action did not finish before the test deadline.") }
        await Task.yield()
    }
    #expect(model.progress.isEmpty)
}

@MainActor private func finishSingleFileModelOperation(_ model: AppModel) async throws {
    do { try await waitForSingleFileModelOperation(model) }
    catch {
        let cause = error
        model.cancel()
        do { try await waitForSingleFileModelOperation(model) }
        catch { throw MonitorError.invalid("The file-action cancellation test failed: \(cause.localizedDescription). Task-owned operation cleanup also failed: \(error.localizedDescription)") }
        throw cause
    }
}
