import Foundation
import Darwin
import Testing
@testable import DriveCore

@Test func cancellationDuringPartialStageRemovesOnlyOwnedStagingAndPreservesEarlierOutput() async throws {
    let manager = FileManager.default
    let root = try boundaryDirectory()
    defer {
        do { try manager.removeItem(at: root) }
        catch { Issue.record(error) }
    }
    let source = root.appendingPathComponent("controlled-source")
    let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
    let destination = root.appendingPathComponent("earlier-saved.txt")
    try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let earlierBytes = Data("earlier committed download".utf8)
    try earlierBytes.write(to: destination, options: .withoutOverwriting)
    guard mkfifo(source.path, 0o600) == 0 else { throw boundaryPOSIXFailure("Create controlled staging source", code: errno) }
    let descriptor = open(source.path, O_RDWR | O_NONBLOCK)
    guard descriptor >= 0 else { throw boundaryPOSIXFailure("Open controlled staging source keeper", code: errno) }
    var keeper: Int32? = descriptor
    defer {
        if let descriptor = keeper, close(descriptor) != 0 {
            Issue.record(boundaryPOSIXFailure("Close remaining staging keeper", code: errno))
        }
    }
    let completion = BoundaryCopyCompletion()
    let task = Task.detached {
        do {
            try stageDownloadedFile(source, destination: destination, staging: staging) { _ in
                throw MonitorError.invalid("Partial staging must not reach commit before controlled EOF release.")
            }
            await completion.finish()
        } catch {
            await completion.finish()
            throw error
        }
    }
    do {
        let bytes = Data(repeating: 87, count: 3 * 1_048_576)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Partial staging did not consume the controlled source before the test deadline.") }
            let count = bytes.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
            }
            if count > 0 { offset += count }
            else if count < 0 && [EAGAIN, EINTR].contains(errno) { await Task.yield() }
            else if count < 0 { throw boundaryPOSIXFailure("Write controlled partial staging source", code: errno) }
            else { throw MonitorError.invalid("Writing the controlled staging source returned zero before its expected bytes.") }
        }
        let staged = try await boundaryStagedFile(staging, bytes: Int64(bytes.count), completion: completion, deadline: deadline)
        #expect(try Data(contentsOf: staged) == bytes)
        #expect(try boundaryAttributes(staged).st_mode & 0o777 == 0o600)
        #expect(!(await completion.finished()))
        #expect(try Data(contentsOf: destination) == earlierBytes)
        // The keeper prevents EOF. Cancellation is observed when this owned blocked read returns.
        task.cancel()
        keeper = nil
        guard close(descriptor) == 0 else { throw boundaryPOSIXFailure("Release controlled staging EOF", code: errno) }
        try await boundaryWaitForCompletion(completion)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!manager.fileExists(atPath: staging.path))
        #expect(try Data(contentsOf: destination) == earlierBytes)
        #expect(try boundaryAttributes(source).st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
        #expect(try manager.contentsOfDirectory(atPath: root.path).sorted() == [source.lastPathComponent, destination.lastPathComponent].sorted())
    } catch {
        let cause = error
        task.cancel()
        do {
            if let descriptor = keeper {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !(await completion.finished()) {
                    let files = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                    if !files.isEmpty { break }
                    guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The controlled staging reader never opened before the cleanup deadline.") }
                    await Task.yield()
                }
                keeper = nil
                guard close(descriptor) == 0 else { throw boundaryPOSIXFailure("Release controlled staging EOF during cleanup", code: errno) }
            }
            try await boundaryWaitForCompletion(completion)
            do { try await task.value } catch is CancellationError {}
        } catch {
            throw MonitorError.invalid("Partial staging check failed: \(cause.localizedDescription). Finishing its owned copy also failed: \(error.localizedDescription)")
        }
        throw cause
    }
}

extension GoogleIntegrationTests {
    @Test func destinationDeniedAfterPreflightRetainsSavedOutputAndSkipsUnavailableChildTransfers() async throws {
        let manager = FileManager.default
        let parent = try boundaryDirectory()
        let preparation = LateDestinationDenial(parent: parent)
        defer {
            do { try preparation.restoreAndRemove() }
            catch { Issue.record(error) }
        }
        let earlier = parent.appendingPathComponent("existing.txt")
        let previousBytes = Data("previous user output".utf8)
        try previousBytes.write(to: earlier, options: .withoutOverwriting)
        try validateBatchDestination(parent)

        let metadata = #"{"id":"saved","name":"Saved.txt","mimeType":"text/plain","size":"11","capabilities":{"canDownload":true}}"#
        let saved = try JSONDecoder().decode(DriveFile.self, from: Data(metadata.utf8))
        let blocked = DriveFile(id: "folder", name: "Blocked", mimeType: "application/vnd.google-apps.folder")
        var child = DriveFile(id: "child", name: "Child.txt", mimeType: "text/plain")
        child.capabilities = FileCapabilities(canDownload: true, canTrash: nil)
        let plan = DownloadPlan(items: [
            DownloadItem(file: saved, components: [saved.name]),
            DownloadItem(file: blocked, components: [blocked.name]),
            DownloadItem(file: child, components: [blocked.name, child.name])
        ], issues: [])
        let tokens = FixtureTokens(); await tokens.grantManagement()
        await FixtureProtocol.fixture.prepare([(200, metadata), (200, "saved bytes")])
        let report = try await fixtureClient(tokens).downloadBatch(plan: plan, parent: parent) { value in
            do { try preparation.apply(value) }
            catch { preparation.record(error) }
        }
        try preparation.requireApplied()
        #expect(!report.cancelled)
        #expect(report.planned == 3)
        #expect(report.completed == 1)
        #expect(report.failures == 2)
        #expect(report.unattempted.isEmpty)
        #expect(report.results.map(\.path) == ["Saved.txt", "Blocked", "Blocked/Child.txt"])
        #expect(report.results.map(\.outcome) == [.downloaded, .failed, .failed])
        #expect(report.results[1].message?.contains("Could not create download folder") == true)
        #expect(report.results[1].message?.contains("errno \(EACCES)") == true)
        #expect(report.results[2].message?.contains("destination") == true)
        #expect(report.results[2].message?.contains("Choose") == true)
        #expect(!manager.fileExists(atPath: report.directory.appendingPathComponent("Files/Blocked").path))
        #expect(try Data(contentsOf: report.directory.appendingPathComponent("Files/Saved.txt")) == Data("saved bytes".utf8))
        #expect(try Data(contentsOf: earlier) == previousBytes)
        let persisted = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: report.directory.appendingPathComponent("download-report.json")))
        #expect(persisted.directory == report.directory)
        #expect(persisted.results.map(\.path) == report.results.map(\.path))
        #expect(persisted.results.map(\.outcome) == report.results.map(\.outcome))
        #expect(persisted.completed == 1)
        #expect(persisted.failures == 2)
        #expect(persisted.unattempted.isEmpty)
        #expect(!persisted.cancelled)
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/drive/v3/files/saved" })
        #expect(requests.filter { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "alt" && $0.value == "media" } == true
        }.count == 1)
    }
}

/// This connector changes only the batch child created inside its exact task-owned parent.
/// Progress is serialized by downloadBatch; the lock makes that ownership explicit across executors.
private final class LateDestinationDenial: @unchecked Sendable {
    private let parent: URL
    private let lock = NSLock()
    private var content: URL?
    private var failure: (any Error)?

    init(parent: URL) { self.parent = parent }

    func apply(_ value: BatchProgress) throws {
        guard value.current == "Blocked" else { return }
        lock.lock(); defer { lock.unlock() }
        guard content == nil else { throw MonitorError.invalid("The controlled destination denial was applied twice.") }
        let directories = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]).filter {
            $0.lastPathComponent.hasPrefix("DriveTrace Download ")
        }
        guard directories.count == 1, let directory = directories.first else {
            throw MonitorError.invalid("The exact task-owned parent must contain one current batch directory before destination denial.")
        }
        let files = directory.appendingPathComponent("Files", isDirectory: true)
        guard access(files.path, W_OK | X_OK) == 0 else {
            throw boundaryPOSIXFailure("Verify writable batch folder before controlled denial", code: errno)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: files.path)
        content = files
    }

    func record(_ cause: any Error) {
        lock.lock(); defer { lock.unlock() }
        failure = cause
    }

    func requireApplied() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard content != nil else { throw MonitorError.invalid("The batch never reached the controlled destination-denial boundary.") }
    }

    func restoreAndRemove() throws {
        lock.lock(); defer { lock.unlock() }
        if let content { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: content.path) }
        try FileManager.default.removeItem(at: parent)
    }
}

private func boundaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DriveTrace Download Boundary " + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

private func boundaryPOSIXFailure(_ operation: String, code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))."])
}

private actor BoundaryCopyCompletion {
    private var complete = false
    func finish() { complete = true }
    func finished() -> Bool { complete }
}

private func boundaryAttributes(_ url: URL) throws -> stat {
    var attributes = stat()
    guard lstat(url.path, &attributes) == 0 else { throw boundaryPOSIXFailure("Read exact owned staging attributes", code: errno) }
    return attributes
}

private func boundaryStagedFile(_ directory: URL, bytes: Int64, completion: BoundaryCopyCompletion, deadline: ContinuousClock.Instant) async throws -> URL {
    while true {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The owned staging file did not retain the expected partial chunks before the test deadline.") }
        guard !(await completion.finished()) else { throw MonitorError.invalid("The staging operation finished before controlled cancellation and EOF release.") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.count <= 1 else { throw MonitorError.invalid("The exact private staging directory unexpectedly contains multiple files.") }
        if let staged = files.first, try boundaryAttributes(staged).st_size == bytes { return staged }
        await Task.yield()
    }
}

private func boundaryWaitForCompletion(_ completion: BoundaryCopyCompletion) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await completion.finished()) {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The owned staging operation did not finish after controlled EOF release before the cleanup deadline.") }
        await Task.yield()
    }
}
