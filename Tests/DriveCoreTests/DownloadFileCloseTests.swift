import Foundation
import CryptoKit
import Darwin
import Testing
@testable import DriveCore

@Test func fileCloseFailureRetainsRealTaskCancellationAndClosesOnce() async throws {
    let directory = try closeFixtureDirectory()
    defer { removeCloseFixtureDirectory(directory) }
    let source = directory.appendingPathComponent("source.bin")
    let bytes = Data("Exact bytes remain after cancelled handle cleanup".utf8)
    try writeCloseFixture(bytes, to: source)
    let handle = try FileHandle(forReadingFrom: source)
    let task = Task {
        var closes = 0
        try cancelCurrentCloseFixtureTask()
        do {
            let _: Data = try withDownloadFileHandle(handle, file: source, operation: .checksumInput, closing: { handle in
                closes += 1
                try closeFixtureWithPOSIXFailure(handle)
            }) { handle in
                try Task.checkCancellation()
                return try handle.readToEnd() ?? Data()
            }
            throw MonitorError.invalid("Cancelled file work unexpectedly returned a value despite its closing failure.")
        } catch let failure as DownloadFileCloseError {
            #expect(closes == 1)
            #expect(Task.isCancelled)
            return failure
        }
    }
    let failure = try await task.value
    #expect(!Task.isCancelled)
    #expect(failure.file == source)
    #expect(failure.operation == .checksumInput)
    #expect(failure.cause is CancellationError)
    #expect(failure.cancelled)
    #expect(downloadWasCancelled(failure))
    try assertControlledCloseFailure(failure.closing)
    #expect(failure.localizedDescription.contains("cancelled before completion"))
    #expect(failure.localizedDescription.contains(source.path))
    #expect(try Data(contentsOf: source) == bytes)
}

@Test func fileCloseFailureRetainsGenuineURLSessionCancellationWithoutTaskCancellation() async throws {
    let cancellation = try await nativeCancelledURLSessionFailure()
    #expect(cancellation.code == .cancelled)
    #expect(!Task.isCancelled)
    let directory = try closeFixtureDirectory()
    defer { removeCloseFixtureDirectory(directory) }
    let source = directory.appendingPathComponent("source.bin")
    let bytes = Data("URLSession cancellation is an error cause, not this task's state".utf8)
    try writeCloseFixture(bytes, to: source)
    let handle = try FileHandle(forReadingFrom: source)
    var closes = 0
    do {
        let _: Data = try withDownloadFileHandle(handle, file: source, operation: .errorResponse, closing: { handle in
            closes += 1
            try closeFixtureWithPOSIXFailure(handle)
        }) { _ in throw cancellation }
        throw MonitorError.invalid("The original cancelled URLSession request and closing failure were unexpectedly discarded.")
    } catch let failure as DownloadFileCloseError {
        #expect(closes == 1)
        #expect(!Task.isCancelled)
        let retained = try #require(failure.cause as? URLError)
        #expect(retained.code == cancellation.code)
        #expect(failure.file == source && failure.operation == .errorResponse)
        #expect(failure.cancelled)
        #expect(downloadWasCancelled(failure))
        try assertControlledCloseFailure(failure.closing)
        #expect(failure.localizedDescription.contains(cancellation.localizedDescription))
        #expect(failure.localizedDescription.contains(source.path))
    }
    #expect(try Data(contentsOf: source) == bytes)
}

@Test func nestedFileCloseFailuresAndDeniedCleanupRetainCancellationAndBothCloseCauses() async throws {
    let manager = FileManager.default
    let directory = try closeFixtureDirectory()
    defer { removeCloseFixtureDirectory(directory) }
    let source = directory.appendingPathComponent("source.bin")
    let output = directory.appendingPathComponent("unfinished-output.bin")
    let bytes = Data("Actual native input and output precede nested close failures".utf8)
    try writeCloseFixture(bytes, to: source)
    let task = Task {
        let reader = try FileHandle(forReadingFrom: source)
        var inputCloses = 0
        var outputCloses = 0
        do {
            let _: Data = try withDownloadFileHandle(reader, file: source, operation: .stagingInput, closing: { handle in
                inputCloses += 1
                try closeFixtureWithPOSIXFailure(handle)
            }) { reader in
                let copied = try reader.readToEnd() ?? Data()
                let descriptor = open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard descriptor >= 0 else { throw closeFixturePOSIXFailure("Create exact private output for nested-close validation", code: errno) }
                let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                return try withDownloadFileHandle(writer, file: output, operation: .stagingOutput, closing: { handle in
                    outputCloses += 1
                    try closeFixtureWithPOSIXFailure(handle)
                }) { writer in
                    try writer.write(contentsOf: copied)
                    try cancelCurrentCloseFixtureTask()
                    try Task.checkCancellation()
                    return copied
                }
            }
            throw MonitorError.invalid("Nested cancelled file work unexpectedly returned despite both closing failures.")
        } catch let failure as DownloadFileCloseError {
            #expect(inputCloses == 1 && outputCloses == 1)
            return failure
        }
    }
    let outer = try await task.value
    #expect(!Task.isCancelled)
    #expect(outer.file == source && outer.operation == .stagingInput)
    #expect(outer.cancelled)
    try assertControlledCloseFailure(outer.closing)
    let inner = try #require(outer.cause as? DownloadFileCloseError)
    #expect(inner.file == output && inner.operation == .stagingOutput)
    #expect(inner.cause is CancellationError)
    #expect(inner.cancelled)
    try assertControlledCloseFailure(inner.closing)
    #expect(outer.localizedDescription.contains(source.path))
    #expect(outer.localizedDescription.contains(output.path))
    #expect(try Data(contentsOf: source) == bytes)
    #expect(try Data(contentsOf: output) == bytes)
    #expect(try manager.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int == 0o600)

    let blocked = directory.appendingPathComponent("denied-cleanup", isDirectory: true)
    try manager.createDirectory(at: blocked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let temporary = blocked.appendingPathComponent("temporary.bin")
    try writeCloseFixture(bytes, to: temporary)
    defer {
        do { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        catch { Issue.record(error) }
    }
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
    do {
        try removeFailedDownload(temporary, cause: outer)
        throw MonitorError.invalid("The exact inaccessible cleanup fixture unexpectedly allowed removal.")
    } catch let failure as FailedDownloadCleanupError {
        #expect(failure.cancelled)
        #expect(downloadWasCancelled(failure))
        #expect(failure.temporary == temporary)
        let retainedOuter = try #require(failure.cause as? DownloadFileCloseError)
        let retainedInner = try #require(retainedOuter.cause as? DownloadFileCloseError)
        #expect(retainedInner.cause is CancellationError)
        try assertControlledCloseFailure(retainedOuter.closing)
        try assertControlledCloseFailure(retainedInner.closing)
        #expect((failure.cleanup as NSError).domain == NSCocoaErrorDomain)
        #expect((failure.cleanup as NSError).code == NSFileWriteNoPermissionError)
        #expect(failure.localizedDescription.contains(source.path))
        #expect(failure.localizedDescription.contains(output.path))
        #expect(failure.localizedDescription.contains(temporary.path))
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
    #expect(try Data(contentsOf: temporary) == bytes)
    try removeFailedDownload(temporary, cause: outer)
    #expect(!manager.fileExists(atPath: temporary.path))
    #expect(try Data(contentsOf: output) == bytes)
}

@Test func successfulStagingBodyWithCloseFailureDeniesCommitWithoutInventingPrimaryCancellation() async throws {
    let directory = try closeFixtureDirectory()
    defer { removeCloseFixtureDirectory(directory) }
    let source = directory.appendingPathComponent("source.bin")
    let destination = directory.appendingPathComponent("earlier-saved.bin")
    let staging = directory.appendingPathComponent("owned-staging", isDirectory: true)
    let bytes = Data(repeating: 68, count: 65_536 + 7)
    let earlier = Data("Previously committed destination must remain unchanged".utf8)
    try writeCloseFixture(bytes, to: source)
    try writeCloseFixture(earlier, to: destination)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var file = DriveFile(id: "close-deny", name: "Source.bin", mimeType: "application/octet-stream")
    file.sha256Checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let selected = file
    let task = Task {
        var closes = 0
        var publicationAttempted = false
        do {
            try stageDownloadedFile(source, destination: destination, staging: staging) { staged in
                try validateDownloadChecksum(staged, file: selected)
                let handle = try FileHandle(forReadingFrom: staged)
                let checked = try withDownloadFileHandle(handle, file: staged, operation: .checksumInput, closing: { handle in
                    closes += 1
                    // Cancellation arrives after a successful body. It is not the primary cause of this close failure.
                    try cancelCurrentCloseFixtureTask()
                    try closeFixtureWithPOSIXFailure(handle)
                }) { try $0.readToEnd() ?? Data() }
                guard checked == bytes else { throw MonitorError.invalid("Completed staged bytes changed before publication.") }
                publicationAttempted = true
                guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw closeFixturePOSIXFailure("Commit exact completed close-denial fixture exclusively", code: errno)
                }
            }
            throw MonitorError.invalid("The staged file unexpectedly committed after a closing failure.")
        } catch let failure as DownloadFileCloseError {
            #expect(closes == 1)
            #expect(!publicationAttempted)
            #expect(Task.isCancelled)
            return failure
        }
    }
    let failure = try await task.value
    #expect(!Task.isCancelled)
    #expect(failure.operation == .checksumInput)
    #expect(failure.cause == nil)
    #expect(!failure.cancelled)
    #expect(!downloadWasCancelled(failure))
    try assertControlledCloseFailure(failure.closing)
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(try Data(contentsOf: source) == bytes)
    #expect(try Data(contentsOf: destination) == earlier)
}

@Test func nativeFileHandleClosingReturnsValueAndPreservesOriginalCancellation() async throws {
    let directory = try closeFixtureDirectory()
    defer { removeCloseFixtureDirectory(directory) }
    let source = directory.appendingPathComponent("source.bin")
    let bytes = Data("The ordinary Foundation close boundary keeps the body result".utf8)
    try writeCloseFixture(bytes, to: source)
    let handle = try FileHandle(forReadingFrom: source)
    let returned = try withDownloadFileHandle(handle, file: source, operation: .checksumInput) { try $0.readToEnd() ?? Data() }
    #expect(returned == bytes)
    let task = Task {
        let handle = try FileHandle(forReadingFrom: source)
        try cancelCurrentCloseFixtureTask()
        return try withDownloadFileHandle(handle, file: source, operation: .checksumInput) { _ -> Data in
            try Task.checkCancellation()
            return Data()
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!Task.isCancelled)
    #expect(try Data(contentsOf: source) == bytes)
}

/// Controlled POSIX closing boundary: close the real owned Foundation handle exactly once,
/// then obtain EBADF from close(-1), which can never target another process-owned descriptor.
/// This validates composition and propagation, not a naturally failing Foundation close.
func closeFixtureWithPOSIXFailure(_ handle: FileHandle) throws {
    try handle.close()
    let result = Darwin.close(-1)
    let code = errno
    guard result == -1, code == EBADF else {
        throw MonitorError.invalid("The controlled POSIX close(-1) boundary did not report the required EBADF failure (result \(result), errno \(code)).")
    }
    throw closeFixturePOSIXFailure("Controlled POSIX closing boundary after native handle closure", code: code)
}

private func assertControlledCloseFailure(_ error: any Error) throws {
    let failure = error as NSError
    #expect(failure.domain == NSPOSIXErrorDomain)
    #expect(failure.code == Int(EBADF))
    #expect(failure.localizedDescription.contains("Controlled POSIX closing boundary"))
}

private func closeFixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DriveTrace File Close " + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

private func writeCloseFixture(_ bytes: Data, to file: URL) throws {
    try bytes.write(to: file, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}

private func removeCloseFixtureDirectory(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record(error) }
}

private func cancelCurrentCloseFixtureTask() throws {
    try withUnsafeCurrentTask { task in
        guard let task else { throw MonitorError.invalid("The controlled file-close cancellation must run inside its owned Swift task.") }
        task.cancel()
    }
}

private func closeFixturePOSIXFailure(_ operation: String, code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))."])
}

private actor CloseRequestCompletion {
    private var value: Result<URLError, any Error>?
    func finish(_ result: Result<URLError, any Error>) { value = result }
    func result() -> Result<URLError, any Error>? { value }
}

/// A real Foundation task is cancelled before resume; no callback request or Google connection is made.
func nativeCancelledURLSessionFailure() async throws -> URLError {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 2
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "http://127.0.0.1:9/drivetrace-close-cancellation"))
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
    let completion = CloseRequestCompletion()
    let task = session.dataTask(with: request) { _, _, error in
        let result: Result<URLError, any Error>
        if let failure = error as? URLError, failure.code == .cancelled { result = .success(failure) }
        else if let error { result = .failure(error) }
        else { result = .failure(MonitorError.invalid("The real pre-cancelled URLSession task completed without a cancellation error.")) }
        Task { @Sendable [completion, result] in await completion.finish(result) }
    }
    task.cancel()
    task.resume()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
        if let result = await completion.result() { return try result.get() }
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The real pre-cancelled URLSession task did not return its cancellation before the test deadline.") }
        try Task.checkCancellation()
        await Task.yield()
    }
}
