import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

private struct GoogleSearchResponse: Sendable {
    let status: Int
    let body: String
}
private actor GoogleSearchResponses {
    private var responses: [GoogleSearchResponse] = []
    private var requests: [URLRequest] = []
    private var heldRequest: Int?
    private var heldID: UUID?
    private var continuation: CheckedContinuation<Void, Never>?
    func prepare(_ values: [GoogleSearchResponse]) { responses = values; requests = []; heldRequest = nil }
    func holdResponse(_ request: Int) { heldRequest = request }
    func next(_ request: URLRequest, id: UUID) async throws -> GoogleSearchResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw MonitorError.invalid("Unexpected Google-search fixture request.") }
        let response = responses.removeFirst()
        if requests.count == heldRequest { heldID = id; await withCheckedContinuation { continuation = $0 } }
        return response
    }
    func releaseHeldResponse() { continuation?.resume(); continuation = nil; heldID = nil }
    func cancelResponse(_ id: UUID) { if id == heldID { releaseHeldResponse() } }
    func allRequests() -> [URLRequest] { requests }
}
private final class GoogleSearchProtocol: URLProtocol, @unchecked Sendable {
    static let responses = GoogleSearchResponses()
    private let requestID = UUID()
    private var loading: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        loading = Task { @Sendable [self] in
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
        let responses = Self.responses
        Task { @Sendable [responses, id] in await responses.cancelResponse(id) }
    }
}
private actor DeferredFailingTokens: TokenProvider {
    private var continuation: CheckedContinuation<String, any Error>?
    func grantedScopes() -> Set<String> { [] }
    func accessToken(forceRefresh: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func hasPendingRequest() -> Bool { continuation != nil }
    func fail(_ failure: MonitorError) throws {
        guard let pending = continuation else { throw MonitorError.invalid("No deferred token request is available to fail.") }
        continuation = nil; pending.resume(throwing: failure)
    }
}
private func searchClient(_ tokens: any TokenProvider) -> GoogleClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GoogleSearchProtocol.self]
    return GoogleClient(tokens: tokens, session: URLSession(configuration: configuration))
}
@MainActor private func searchModel(_ retained: [DriveFile]) -> AppModel {
    let model = AppModel(); model.connected = true
    model.client = searchClient(FixtureTokens())
    model.files = retained; model.results = retained; model.serverResults = retained; model.serverCoverage = "Previous Google results"
    return model
}
@MainActor private func waitForSearch(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.busy || model.searching {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Google-search fixture did not complete before the test deadline.") }
        await Task.yield()
    }
}
private func waitForRequest(_ count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await GoogleSearchProtocol.responses.allRequests().count < count {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Google-search fixture did not receive the expected request before the test deadline.") }
        await Task.yield()
    }
}
private func waitForTokenRequest(_ tokens: DeferredFailingTokens) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await tokens.hasPendingRequest()) {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Google-search fixture did not start token renewal before the test deadline.") }
        await Task.yield()
    }
}
private func queryValues(_ request: URLRequest) throws -> [String: String] {
    let url = try #require(request.url)
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}
@Suite(.serialized) struct GoogleSearchTests {
    @Test @MainActor func completeSearchKeepsPaginationContextAndCurrentSort() async throws {
        await GoogleSearchProtocol.responses.prepare([
            GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"z","name":"Zulu","mimeType":"text/plain","driveId":"team-a"}],"nextPageToken":"page2"}"#),
            GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"a","name":"Alpha","mimeType":"text/plain","driveId":"team-a"}]}"#)
        ])
        await GoogleSearchProtocol.responses.holdResponse(2)
        let model = searchModel([]); defer { model.cancel() }
        model.filter.text = "invoice"; model.filter.drive = "team-a"
        model.queryGoogle(); try await waitForRequest(2)
        model.ascending = false; model.updateResults()
        await GoogleSearchProtocol.responses.releaseHeldResponse(); try await waitForSearch(model)
        #expect(model.error == nil); #expect(model.results.map(\.id) == ["z", "a"])
        #expect(model.serverResults?.count == 2)
        let requests = await GoogleSearchProtocol.responses.allRequests()
        #expect(requests.count == 2)
        for request in requests {
            let values = try queryValues(request)
            #expect(values["q"] == "name contains 'invoice' and trashed = false")
            #expect(values["driveId"] == "team-a")
        }
        #expect(try queryValues(requests[1])["pageToken"] == "page2")
    }
    @Test @MainActor func googleOnlyRowsHaveAnExplicitPrimaryAction() async throws {
        await GoogleSearchProtocol.responses.prepare([
            GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"remote-file","name":"Remote file","mimeType":"text/plain","webViewLink":"https://example.test/file"},{"id":"remote-folder","name":"Remote folder","mimeType":"application/vnd.google-apps.folder","webViewLink":"https://example.test/folder"}]}"#)
        ])
        let model = searchModel([]); defer { model.cancel() }
        model.queryGoogle(); try await waitForSearch(model)
        #expect(model.index.isEmpty)
        #expect(model.results.map(\.id) == ["remote-file", "remote-folder"])
        #expect(model.results[1].isFolder)

        model.activateResult("remote-file")
        #expect(model.error == "Google returned an unsupported web link. Inspect the file metadata before opening it.")
        model.error = nil
        model.activateResult("remote-folder")
        #expect(model.error == "Google returned an unsupported web link. Inspect the file metadata before opening it.")
        #expect(model.selection == "all")
        #expect(model.serverResults?.count == 2)
        model.error = nil
        model.activateResult("missing")
        #expect(model.error == "The selected result is no longer visible. Refresh the results and try again.")
    }
    @Test @MainActor func changingAndRestoringFilterCancelsObsoleteSearch() async throws {
        await GoogleSearchProtocol.responses.prepare([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"remote","name":"Remote","mimeType":"text/plain"}]}"#)])
        await GoogleSearchProtocol.responses.holdResponse(1)
        let retained = sample("local", name: "Local", size: nil)
        let model = searchModel([retained]); defer { model.cancel() }
        model.queryGoogle(); try await waitForRequest(1)
        model.filter.drive = "changed-drive"; model.filter.drive = ""
        model.serverResults = nil; model.updateResults()
        await GoogleSearchProtocol.responses.releaseHeldResponse(); try await waitForSearch(model)
        #expect(model.serverResults == nil); #expect(model.results.map(\.id) == ["local"])
        #expect(model.error == nil); #expect(model.operationNotice?.contains("filters, view or workspace changed") == true)
    }
    @Test @MainActor func invalidRawSizeInputCancelsObsoleteSearch() async throws {
        await GoogleSearchProtocol.responses.prepare([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"remote","name":"Remote","mimeType":"text/plain"}]}"#)])
        await GoogleSearchProtocol.responses.holdResponse(1)
        let retained = sample("local", name: "Local", size: nil)
        let model = searchModel([retained]); defer { model.cancel() }
        model.queryGoogle(); try await waitForRequest(1)
        model.minimumSizeInput = "invalid"; model.updateSizes()
        await GoogleSearchProtocol.responses.releaseHeldResponse(); try await waitForSearch(model)
        #expect(model.filter.minimumBytes == nil); #expect(model.filterValidationError != nil)
        #expect(model.minimumSizeInput == "invalid"); #expect(model.serverResults == nil); #expect(model.results.isEmpty)
        #expect(model.error == nil); #expect(model.operationNotice?.contains("filters, view or workspace changed") == true)
    }
    @Test @MainActor func changingAndRestoringNavigationCancelsObsoleteSearch() async throws {
        await GoogleSearchProtocol.responses.prepare([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"remote","name":"Remote","mimeType":"text/plain"}]}"#)])
        await GoogleSearchProtocol.responses.holdResponse(1)
        let retained = sample("local", name: "Local", size: nil)
        let model = searchModel([retained]); defer { model.cancel() }
        model.queryGoogle(); try await waitForRequest(1)
        model.navigate("my"); model.navigate("all")
        await GoogleSearchProtocol.responses.releaseHeldResponse(); try await waitForSearch(model)
        #expect(model.serverResults == nil); #expect(model.results.map(\.id) == ["local"])
        #expect(model.error == nil); #expect(model.operationNotice?.contains("filters, view or workspace changed") == true)
    }
    @Test @MainActor func changingAndRestoringWorkspaceCancelsObsoleteSearch() async throws {
        await GoogleSearchProtocol.responses.prepare([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"remote","name":"Remote","mimeType":"text/plain"}]}"#)])
        await GoogleSearchProtocol.responses.holdResponse(1)
        let retained = sample("local", name: "Local", size: nil)
        let model = searchModel([retained]); defer { model.cancel() }
        model.queryGoogle(); try await waitForRequest(1)
        model.isDemo = true; model.isDemo = false
        await GoogleSearchProtocol.responses.releaseHeldResponse(); try await waitForSearch(model)
        #expect(model.serverResults?.map(\.id) == ["local"]); #expect(model.results.map(\.id) == ["local"])
        #expect(model.error == nil); #expect(model.operationNotice?.contains("filters, view or workspace changed") == true)
    }
    @Test @MainActor func changingAndRestoringDatabaseCancelsObsoleteSearch() async throws {
        await GoogleSearchProtocol.responses.prepare([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"remote","name":"Remote","mimeType":"text/plain"}]}"#)])
        await GoogleSearchProtocol.responses.holdResponse(1)
        let model = searchModel([sample("old", name: "Previous", size: nil)]); defer { model.cancel() }
        let database = try Database(path: ":memory:")
        model.queryGoogle(); try await waitForRequest(1)
        model.database = database; model.database = nil
        await GoogleSearchProtocol.responses.releaseHeldResponse(); try await waitForSearch(model)
        #expect(model.serverResults?.map(\.id) == ["old"]); #expect(model.results.map(\.id) == ["old"])
        #expect(model.error == nil); #expect(model.operationNotice?.contains("filters, view or workspace changed") == true)
        try await database.close()
    }
    @Test @MainActor func malformedPaginationPreservesPreviousValidResults() async throws {
        let scenarios: [([GoogleSearchResponse], String)] = [
            ([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"a","name":"Alpha","mimeType":"text/plain"},{"id":"a","name":"Alpha again","mimeType":"text/plain"}]}"#)], "duplicate file ID"),
            ([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"a","name":"Alpha","mimeType":"text/plain"}],"nextPageToken":"page2"}"#), GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"a","name":"Alpha again","mimeType":"text/plain"}]}"#)], "duplicate file ID"),
            ([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"a","name":"Alpha","mimeType":"text/plain"}],"nextPageToken":"page2"}"#), GoogleSearchResponse(status: 403, body: #"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions","domain":"global"}]}}"#)], "403"),
            ([GoogleSearchResponse(status: 200, body: #"{"files":[],"nextPageToken":"repeat"}"#), GoogleSearchResponse(status: 200, body: #"{"files":[],"nextPageToken":"repeat"}"#)], "repeated a cursor"),
            ([GoogleSearchResponse(status: 200, body: #"{"files":[],"incompleteSearch":true}"#)], "incomplete search"),
            ([GoogleSearchResponse(status: 403, body: #"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#)], "403")
        ]
        for (responses, explanation) in scenarios {
            await GoogleSearchProtocol.responses.prepare(responses)
            let model = searchModel([sample("old", name: "Previous", size: nil)])
            model.queryGoogle(); try await waitForSearch(model)
            #expect(model.error?.contains(explanation) == true)
            #expect(model.serverResults?.map(\.id) == ["old"]); #expect(model.results.map(\.id) == ["old"])
            #expect(model.serverCoverage == "Previous Google results")
            #expect(await GoogleSearchProtocol.responses.allRequests().count == responses.count)
        }
    }
    @Test @MainActor func explicitCancellationKeepsPreviousResultsAndUsesSearchNotice() async throws {
        await GoogleSearchProtocol.responses.prepare([GoogleSearchResponse(status: 200, body: #"{"files":[{"id":"remote","name":"Remote","mimeType":"text/plain"}]}"#)])
        await GoogleSearchProtocol.responses.holdResponse(1)
        let model = searchModel([sample("old", name: "Previous", size: nil)]); defer { model.cancel() }
        model.queryGoogle(); try await waitForRequest(1); model.cancel()
        await GoogleSearchProtocol.responses.releaseHeldResponse(); try await waitForSearch(model)
        #expect(model.error == nil); #expect(model.results.map(\.id) == ["old"])
        #expect(model.serverResults?.map(\.id) == ["old"])
        #expect(model.operationNotice == "Google search cancelled. Previous results were retained.")
    }
    @Test @MainActor func tokenFailureAfterContextCancellationCannotOverwriteCurrentError() async throws {
        await GoogleSearchProtocol.responses.prepare([])
        let tokens = DeferredFailingTokens()
        let model = searchModel([sample("old", name: "Previous", size: nil)]); defer { model.cancel() }
        model.client = searchClient(tokens)
        model.queryGoogle(); try await waitForTokenRequest(tokens)
        try await tokens.fail(.authentication("Synthetic token refresh failed.")); try await waitForSearch(model)
        #expect(model.error == "Synthetic token refresh failed.")
        #expect(model.results.map(\.id) == ["old"])

        model.queryGoogle(); try await waitForTokenRequest(tokens)
        model.filter.text = "changed"; model.filter.text = ""
        model.error = "Current view failure."
        try await tokens.fail(.authentication("Obsolete synthetic token refresh failed.")); try await waitForSearch(model)
        #expect(model.error == "Current view failure.")
        #expect(model.serverResults?.map(\.id) == ["old"]); #expect(model.results.map(\.id) == ["old"])
        #expect(model.operationNotice?.contains("filters, view or workspace changed") == true)
        #expect(await GoogleSearchProtocol.responses.allRequests().isEmpty)
    }
}
