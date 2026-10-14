import Foundation
import Network
import CryptoKit
import Darwin
import Testing
@testable import DriveCore

@Suite(.serialized) struct StreamingDownloadTests {
    @Test func substantialDownloadStreamsExactPrivateContent() async throws {
        let size = 128 * 1_048_576
        let file = streamFixtureFile(id: "substantial", name: "Substantial.bin", bytes: size)
        let fixture = try await StreamingFixture.open(files: [file], responses: [file.id: .complete(size)])
        defer { fixture.session.invalidateAndCancel() }
        do {
            let destination = fixture.directory.appendingPathComponent(file.name)
            try await fixture.client.downloadNewFile(file: file, to: destination)
            #expect(try streamFileDigest(destination) == file.sha256Checksum)
            #expect(try streamFileAttributes(destination).st_size == Int64(size))
            #expect(try streamFileAttributes(destination).st_mode & 0o777 == 0o600)
            let snapshot = await fixture.server.snapshot()
            #expect(snapshot.paths == ["/media/substantial"])
            #expect(snapshot.sent[file.id] == size)
            #expect(snapshot.authorizations.allSatisfy { $0 == nil })
            #expect(snapshot.failures.isEmpty)
            #expect(await fixture.router.requests() == ["metadata:substantial", "media:substantial"])
            print("Streaming fixture: 128 MiB saved with exact SHA-256, 64 KiB server chunks and mode 0600.")
        } catch {
            try await fixture.close(after: error)
            throw error
        }
        try await fixture.close()
    }

    @Test func activeNetworkCancellationPreservesAnExistingDestination() async throws {
        let file = streamFixtureFile(id: "held", name: "Held.bin", bytes: 128 * 1_048_576)
        let fixture = try await StreamingFixture.open(files: [file], responses: [file.id: .held(4 * 1_048_576)])
        defer { fixture.session.invalidateAndCancel() }
        let destination = fixture.directory.appendingPathComponent(file.name)
        let original = Data("Existing destination must survive cancellation".utf8)
        do { try original.write(to: destination) }
        catch { try await fixture.close(after: error); throw error }
        let completion = StreamingCompletion()
        let task = Task {
            do { try await fixture.client.download(file: file, to: destination); await completion.finish() }
            catch { await completion.finish(); throw error }
        }
        do {
            try await waitForStreamCondition("held body to reach the active network transfer", seconds: 5) {
                await fixture.server.snapshot().sent[file.id] == 4 * 1_048_576
            }
            #expect(!(await completion.finished()))
            let start = ContinuousClock.now
            task.cancel()
            try await waitForStreamCondition("cancelled download to finish", seconds: 5) { await completion.finished() }
            let elapsed = start.duration(to: .now)
            #expect(elapsed < .seconds(3))
            do { try await task.value; Issue.record("An active cancelled transfer must not succeed.") }
            catch is CancellationError {}
            catch let error as URLError { #expect(error.code == .cancelled) }
            #expect(try Data(contentsOf: destination) == original)
            #expect(await fixture.server.snapshot().paths == ["/media/held"])
            #expect(await fixture.server.snapshot().failures.isEmpty)
            #expect(await fixture.router.requests() == ["metadata:held", "media:held"])
            print("Streaming fixture: active transfer cancellation completed in \(elapsed), existing destination preserved.")
        } catch {
            task.cancel()
            try await fixture.close(after: error)
            throw error
        }
        try await fixture.close()
    }

    @Test func activeBatchCancellationRetainsSavedAndUnattemptedPaths() async throws {
        let first = streamFixtureFile(id: "completed", name: "Completed.bin", bytes: 1_048_576)
        let second = streamFixtureFile(id: "pending", name: "Pending.bin", bytes: 128 * 1_048_576)
        let last = streamFixtureFile(id: "unattempted", name: "Unattempted.bin", bytes: 1_048_576)
        let files = [first, second, last]
        let fixture = try await StreamingFixture.open(files: files, responses: [first.id: .complete(1_048_576), second.id: .held(4 * 1_048_576), last.id: .complete(1_048_576)])
        defer { fixture.session.invalidateAndCancel() }
        let plan = DownloadPlan(items: files.map { DownloadItem(file: $0, components: [$0.name]) }, issues: [])
        let completion = StreamingCompletion()
        let task = Task {
            do {
                let report = try await fixture.client.downloadBatch(plan: plan, parent: fixture.directory) { _ in }
                await completion.finish()
                return report
            } catch { await completion.finish(); throw error }
        }
        do {
            try await waitForStreamCondition("second batch body to reach the active network transfer", seconds: 5) {
                await fixture.server.snapshot().sent[second.id] == 4 * 1_048_576
            }
            #expect(!(await completion.finished()))
            let start = ContinuousClock.now
            task.cancel()
            try await waitForStreamCondition("cancelled batch and automatic report to finish", seconds: 5) { await completion.finished() }
            let elapsed = start.duration(to: .now)
            #expect(elapsed < .seconds(3))
            let report = try await task.value
            #expect(report.cancelled)
            #expect(report.completed == 1)
            #expect(report.failures == 0)
            #expect(report.remaining == 2)
            #expect(report.results.map(\.path) == [first.name])
            #expect(report.unattempted == [second.name, last.name])
            let contents = report.directory.appendingPathComponent("Files")
            #expect(try streamFileDigest(contents.appendingPathComponent(first.name)) == first.sha256Checksum)
            #expect(try FileManager.default.contentsOfDirectory(atPath: contents.path) == [first.name])
            let reportURL = report.directory.appendingPathComponent("download-report.json")
            let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: reportURL))
            #expect(saved.cancelled && saved.completed == 1 && saved.remaining == 2)
            #expect(saved.unattempted == report.unattempted)
            #expect(try streamFileAttributes(reportURL).st_mode & 0o777 == 0o600)
            #expect(await fixture.server.snapshot().paths == ["/media/completed", "/media/pending"])
            #expect(await fixture.server.snapshot().failures.isEmpty)
            #expect(await fixture.router.requests() == ["metadata:completed", "media:completed", "metadata:pending", "media:pending"])
            print("Streaming fixture: active batch cancellation completed in \(elapsed), one saved and two unattempted paths retained.")
        } catch {
            task.cancel()
            try await fixture.close(after: error)
            throw error
        }
        try await fixture.close()
    }

    @Test func shortSuccessfulBodyFailsWithoutReplacingOrRetrying() async throws {
        let file = streamFixtureFile(id: "short", name: "Short.bin", bytes: 1_048_576)
        let fixture = try await StreamingFixture.open(files: [file], responses: [file.id: .complete(65_536)])
        defer { fixture.session.invalidateAndCancel() }
        do {
            let destination = fixture.directory.appendingPathComponent(file.name)
            let original = Data("Existing destination must survive a short HTTP body".utf8)
            try original.write(to: destination)
            do { try await fixture.client.download(file: file, to: destination); Issue.record("A short body must fail size validation.") }
            catch let error as MonitorError { #expect(error.localizedDescription.contains("size mismatch")) }
            #expect(try Data(contentsOf: destination) == original)
            #expect(await fixture.server.snapshot().paths == ["/media/short"])
            #expect(await fixture.server.snapshot().failures.isEmpty)
            #expect(await fixture.router.requests() == ["metadata:short", "media:short"])
        } catch {
            try await fixture.close(after: error)
            throw error
        }
        try await fixture.close()
    }

    @Test func interruptedNetworkBodyExhaustsOnlyTheBoundedReadRetries() async throws {
        let file = streamFixtureFile(id: "interrupted", name: "Interrupted.bin", bytes: 1_048_576)
        let fixture = try await StreamingFixture.open(files: [file], responses: [file.id: .interrupted(65_536)])
        defer { fixture.session.invalidateAndCancel() }
        let destination = fixture.directory.appendingPathComponent(file.name)
        let original = Data("Existing destination must survive premature TCP EOF".utf8)
        do { try original.write(to: destination) }
        catch { try await fixture.close(after: error); throw error }
        let completion = StreamingCompletion()
        let task = Task {
            do { try await fixture.client.download(file: file, to: destination); await completion.finish() }
            catch { await completion.finish(); throw error }
        }
        do {
            try await waitForStreamCondition("bounded interrupted-body retries to finish", seconds: 20) { await completion.finished() }
            do { try await task.value; Issue.record("A premature TCP EOF must not replace the destination.") }
            catch let error as URLError { #expect(error.code == .networkConnectionLost) }
            #expect(try Data(contentsOf: destination) == original)
            #expect(await fixture.server.snapshot().paths == Array(repeating: "/media/interrupted", count: 4))
            #expect(await fixture.server.snapshot().failures.isEmpty)
            #expect(await fixture.router.requests() == ["metadata:interrupted"] + Array(repeating: "media:interrupted", count: 4))
        } catch {
            task.cancel()
            try await fixture.close(after: error)
            throw error
        }
        try await fixture.close()
    }
}

private let streamFixtureChunk = Data((0..<65_536).map { UInt8($0 % 251) })

private func streamFixtureFile(id: String, name: String, bytes: Int) -> DriveFile {
    var file = DriveFile(id: id, name: name, mimeType: "application/octet-stream")
    file.size = String(bytes)
    file.capabilities = FileCapabilities(canDownload: true, canTrash: false)
    var digest = SHA256()
    var remaining = bytes
    while remaining > 0 {
        let count = min(streamFixtureChunk.count, remaining)
        digest.update(data: streamFixtureChunk.prefix(count))
        remaining -= count
    }
    file.sha256Checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return file
}

private func streamFileDigest(_ url: URL) throws -> String {
    let reader = try FileHandle(forReadingFrom: url)
    var digest = SHA256()
    do {
        while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty { digest.update(data: chunk) }
    } catch {
        let cause = error
        do { try reader.close() }
        catch { throw MonitorError.invalid("Streaming digest failed: \(cause.localizedDescription); reader close failed: \(error.localizedDescription).") }
        throw cause
    }
    try reader.close()
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func streamFileAttributes(_ url: URL) throws -> stat {
    var result = stat()
    guard lstat(url.path, &result) == 0 else {
        let code = errno
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
    return result
}

private func waitForStreamCondition(_ operation: String, seconds: Int, condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !(await condition()) {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Timed out waiting for \(operation).") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor StreamingCompletion {
    private var complete = false
    func finish() { complete = true }
    func finished() -> Bool { complete }
}

private struct StreamingFixture {
    let directory: URL
    let server: StreamHTTPServer
    let router: StreamRequestRouter
    let session: URLSession
    let client: GoogleClient
    let key: String

    static func open(files: [DriveFile], responses: [String: StreamResponse]) async throws -> StreamingFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DriveTrace-stream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let server: StreamHTTPServer
        do { server = try StreamHTTPServer(files: files, responses: responses) }
        catch { try FileManager.default.removeItem(at: directory); throw error }
        do {
            let base = try await server.start()
            let router = StreamRequestRouter(files: files, base: base)
            let key = UUID().uuidString
            StreamProtocol.registry.insert(router, key: key)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StreamProtocol.self]
            configuration.httpAdditionalHeaders = ["X-DriveTrace-Stream-Fixture": key]
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            let tokens = FixtureTokens()
            await tokens.grantManagement()
            return StreamingFixture(directory: directory, server: server, router: router, session: session, client: GoogleClient(tokens: tokens, session: session), key: key)
        } catch {
            let cause = error
            do { try await server.stop(); try FileManager.default.removeItem(at: directory) }
            catch { throw MonitorError.invalid("Streaming setup failed: \(cause.localizedDescription); task-owned cleanup failed: \(error.localizedDescription).") }
            throw cause
        }
    }

    func close() async throws {
        session.invalidateAndCancel()
        StreamProtocol.registry.remove(key: key)
        try await server.stop()
        try FileManager.default.removeItem(at: directory)
    }

    func close(after cause: any Error) async throws {
        do { try await close() }
        catch { throw MonitorError.invalid("Streaming test failed: \(cause.localizedDescription); task-owned cleanup failed: \(error.localizedDescription).") }
    }
}

/// A per-session router supplies synthetic metadata and redirects only known media requests to real localhost HTTP.
private actor StreamRequestRouter {
    private let files: [String: DriveFile]
    private let base: URL
    private var recorded: [String] = []
    init(files: [DriveFile], base: URL) {
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        self.base = base
    }
    func response(for request: URLRequest) throws -> StreamRoute {
        guard let url = request.url, url.scheme == "https", url.host == "www.googleapis.com", request.httpMethod == "GET",
              url.path.hasPrefix("/drive/v3/files/"), let id = url.path.components(separatedBy: "/").last,
              let file = files[id], let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw MonitorError.invalid("The streaming test rejected an unexpected external request.")
        }
        if query.contains(where: { $0.name == "alt" && $0.value == "media" }) {
            recorded.append("media:" + id)
            return .redirect(base.appendingPathComponent("media").appendingPathComponent(id))
        }
        guard query.contains(where: { $0.name == "fields" }) else { throw MonitorError.invalid("The streaming test rejected an unknown Google operation.") }
        recorded.append("metadata:" + id)
        return .metadata(try JSONEncoder().encode(file))
    }
    func requests() -> [String] { recorded }
}

private enum StreamRoute: Sendable { case metadata(Data), redirect(URL) }

/// URLProtocol is a Foundation boundary; the registry lock keeps independent session keys isolated.
private final class StreamProtocol: URLProtocol, @unchecked Sendable {
    static let registry = StreamRouterRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host != "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            do {
                guard let key = request.value(forHTTPHeaderField: "X-DriveTrace-Stream-Fixture"),
                      let router = Self.registry.router(key: key), let source = request.url else {
                    throw MonitorError.invalid("The streaming test refused an unregistered external request.")
                }
                switch try await router.response(for: request) {
                case let .metadata(data):
                    guard let response = HTTPURLResponse(url: source, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                        throw MonitorError.invalid("The streaming metadata response could not be formed.")
                    }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                case let .redirect(target):
                    var redirected = request
                    redirected.url = target
                    redirected.setValue(nil, forHTTPHeaderField: "Authorization")
                    guard let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]) else {
                        throw MonitorError.invalid("The streaming media redirect could not be formed.")
                    }
                    client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                }
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}

/// All mutable registry state is accessed under its lock; no fixture responses are shared between sessions.
private final class StreamRouterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var routers: [String: StreamRequestRouter] = [:]
    func insert(_ router: StreamRequestRouter, key: String) { lock.withLock { routers[key] = router } }
    func remove(key: String) { lock.withLock { _ = routers.removeValue(forKey: key) } }
    func router(key: String) -> StreamRequestRouter? { lock.withLock { routers[key] } }
}

private enum StreamResponse: Sendable { case complete(Int), held(Int), interrupted(Int) }
private struct StreamSnapshot: Sendable {
    let paths: [String]
    let sent: [String: Int]
    let authorizations: [String?]
    let failures: [String]
}

/// A task-owned listener sends fixed-size chunks with transport backpressure and holds partial bodies until cancellation.
private actor StreamHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DriveTrace.streaming-fixture")
    private let files: [String: DriveFile]
    private let responses: [String: StreamResponse]
    private var port: NWEndpoint.Port?
    private var startupFailure: NWError?
    private var connections: [UUID: NWConnection] = [:]
    private var closed: Set<UUID> = []
    private var listenerClosed = false
    private var stopping = false
    private var paths: [String] = []
    private var authorizations: [String?] = []
    private var sent: [String: Int] = [:]
    private var failures: [String] = []

    init(files: [DriveFile], responses: [String: StreamResponse]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.files = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        self.responses = responses
    }
    func start() async throws -> URL {
        listener.stateUpdateHandler = { state in Task { await self.listenerChanged(state) } }
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        listener.start(queue: queue)
        try await waitForStreamCondition("local streaming listener readiness", seconds: 5) { await self.readyOrFailed() }
        if let startupFailure { throw startupFailure }
        guard let port, let base = URL(string: "http://127.0.0.1:\(port.rawValue)/") else { throw MonitorError.invalid("Local streaming listener has no ready port.") }
        return base
    }
    private func listenerChanged(_ state: NWListener.State) {
        if case .ready = state { port = listener.port }
        if case let .failed(error) = state { startupFailure = error }
        if case .cancelled = state { listenerClosed = true }
    }
    private func readyOrFailed() -> Bool { port != nil || startupFailure != nil }
    private func accept(_ connection: NWConnection) {
        guard !stopping else { connection.cancel(); return }
        let key = UUID()
        connections[key] = connection
        connection.stateUpdateHandler = { state in
            if case .cancelled = state { Task { await self.connectionClosed(key) } }
        }
        connection.start(queue: queue)
        Task {
            do {
                let header = try await self.readHeader(connection)
                try await self.respond(header, connection: connection)
            } catch { self.failed(error); connection.cancel() }
        }
    }
    private func readHeader(_ connection: NWConnection) async throws -> String {
        var received = Data()
        while received.range(of: Data("\r\n\r\n".utf8)) == nil {
            let part: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: MonitorError.invalid("Local streaming request ended before its HTTP headers.")) }
                    else { continuation.resume(throwing: MonitorError.invalid("Local streaming request returned no header bytes.")) }
                }
            }
            received.append(part)
            guard received.count <= 16_384 else { throw MonitorError.invalid("Local streaming request headers exceeded the fixture limit.") }
        }
        guard let header = String(data: received, encoding: .utf8) else { throw MonitorError.invalid("Local streaming request headers were not UTF-8.") }
        return header
    }
    private func respond(_ header: String, connection: NWConnection) async throws {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw MonitorError.invalid("Local streaming request has no request line.") }
        let requestLine = first.components(separatedBy: " ")
        guard requestLine.count == 3, requestLine[0] == "GET", requestLine[1].hasPrefix("/media/"),
              let id = requestLine[1].components(separatedBy: "/").last, let file = files[id],
              let response = responses[id], let metadataSize = file.size.flatMap(Int.init) else {
            throw MonitorError.invalid("Local streaming server rejected an unknown request.")
        }
        paths.append(requestLine[1])
        authorizations.append(lines.first { $0.lowercased().hasPrefix("authorization:") })
        let count: Int
        let declared: Int
        switch response {
        case let .complete(bytes): count = bytes; declared = bytes
        case let .held(bytes): count = bytes; declared = metadataSize
        case let .interrupted(bytes): count = bytes; declared = metadataSize
        }
        let responseHeader = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(declared)\r\nConnection: close\r\n\r\n".utf8)
        try await send(responseHeader, connection: connection)
        var delivered = 0
        while delivered < count {
            let chunkSize = min(streamFixtureChunk.count, count - delivered)
            try await send(streamFixtureChunk.prefix(chunkSize), connection: connection)
            delivered += chunkSize
            sent[id] = delivered
        }
        switch response {
        case .held: break
        case .complete, .interrupted: try await finishResponse(connection)
        }
    }
    private func send(_ bytes: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: bytes, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    private func finishResponse(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
    private func failed(_ error: any Error) { failures.append(error.localizedDescription) }
    private func connectionClosed(_ key: UUID) { closed.insert(key) }
    func snapshot() -> StreamSnapshot { StreamSnapshot(paths: paths, sent: sent, authorizations: authorizations, failures: failures) }
    func stop() async throws {
        stopping = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        try await waitForStreamCondition("task-owned listener and connections to close", seconds: 5) { await self.allClosed() }
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        for connection in connections.values { connection.stateUpdateHandler = nil }
        connections.removeAll()
    }
    private func allClosed() -> Bool { listenerClosed && Set(connections.keys).isSubset(of: closed) }
}
