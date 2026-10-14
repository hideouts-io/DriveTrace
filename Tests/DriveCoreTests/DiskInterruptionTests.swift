import Foundation
import Darwin
import Testing
@testable import DriveCore

@Test func completedStagingCommitRefusalPreservesOccupiedFileAndSymlink() throws {
    let manager = FileManager.default
    let root = try interruptionDirectory()
    defer { removeInterruptionDirectory(root) }
    let source = root.appendingPathComponent("completed-source.bin")
    let original = root.appendingPathComponent("earlier-download.bin")
    let bytes = Data(repeating: 83, count: 3 * 1_048_576 + 71)
    let earlier = Data("previously saved contents".utf8)
    try bytes.write(to: source)
    try earlier.write(to: original)
    let symlink = root.appendingPathComponent("occupied-symlink")
    try manager.createSymbolicLink(at: symlink, withDestinationURL: original)

    for destination in [original, symlink] {
        var stagingDirectory: URL?
        do {
            try stageDownloadedFile(source, destination: destination) { staged in
                stagingDirectory = staged.deletingLastPathComponent()
                #expect(try Data(contentsOf: staged) == bytes)
                #expect(try interruptionAttributes(staged).st_mode & 0o777 == 0o600)
                guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw interruptionPOSIXFailure("Refuse occupied completed-download destination", code: errno)
                }
            }
            Issue.record("Exclusive commit must refuse an existing file or symlink after staging all bytes.")
        } catch let failure as NSError where failure.domain == NSPOSIXErrorDomain {
            #expect(failure.code == Int(EEXIST))
        }
        let removedStaging = try #require(stagingDirectory)
        #expect(!manager.fileExists(atPath: removedStaging.path))
        #expect(try Data(contentsOf: original) == earlier)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try manager.destinationOfSymbolicLink(atPath: symlink.path) == original.path)

        #expect(throws: MonitorError.self) { try saveNewDownloadedFile(source, to: destination) }
        #expect(try Data(contentsOf: original) == earlier)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try manager.destinationOfSymbolicLink(atPath: symlink.path) == original.path)
    }
}

@Test func invalidAndDeniedBatchDestinationsFailBeforeWritingWithRecoveryContext() throws {
    let manager = FileManager.default
    let root = try interruptionDirectory()
    defer { removeInterruptionDirectory(root) }
    let regular = root.appendingPathComponent("regular-file")
    let bytes = Data("destination must remain untouched".utf8)
    try bytes.write(to: regular)
    let missing = root.appendingPathComponent("missing-folder", isDirectory: true)
    let denied = root.appendingPathComponent("denied-folder", isDirectory: true)
    try manager.createDirectory(at: denied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: denied.path)
    defer {
        do { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        catch { Issue.record(error) }
    }

    for destination in [missing, regular, denied] {
        do {
            try validateBatchDestination(destination)
            Issue.record("Invalid or unwritable batch destination must fail before creating a download directory.")
        } catch let failure as DownloadDestinationError {
            #expect(failure.destination == destination)
            #expect(failure.localizedDescription.contains(destination.path))
            #expect(failure.localizedDescription.contains("Choose"))
            if destination == denied {
                #expect((failure.cause as NSError).domain == NSPOSIXErrorDomain)
                #expect((failure.cause as NSError).code == Int(EACCES))
            }
        } catch let failure as MonitorError {
            #expect(failure.localizedDescription.contains(destination.path))
            #expect(failure.localizedDescription.contains("Choose"))
        }
    }
    #expect(!manager.fileExists(atPath: missing.path))
    #expect(try Data(contentsOf: regular) == bytes)
    #expect(try manager.contentsOfDirectory(atPath: denied.path).isEmpty)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
    try validateBatchDestination(denied)
    #expect(try manager.contentsOfDirectory(atPath: denied.path).isEmpty)
}

@Test func cancellationAtCompletedStageWithDeniedCleanupPreservesBothCausesAndEarlierOutput() async throws {
    let manager = FileManager.default
    let root = try interruptionDirectory()
    defer { removeInterruptionDirectory(root) }
    let source = root.appendingPathComponent("completed-source.bin")
    let destination = root.appendingPathComponent("already-saved.bin")
    let bytes = Data(repeating: 92, count: 2 * 1_048_576 + 19)
    let earlier = Data("previous committed output".utf8)
    try bytes.write(to: source)
    try earlier.write(to: destination)
    let task = Task.detached {
        try stageDownloadedFile(source, destination: destination) { staged in
            #expect(try Data(contentsOf: staged) == bytes)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: staged.deletingLastPathComponent().path)
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        }
    }
    do {
        try await task.value
        Issue.record("Cancelled staging with inaccessible temporary data must preserve both failure causes.")
    } catch let failure as FailedDownloadCleanupError {
        let staging = failure.temporary
        defer {
            do {
                if manager.fileExists(atPath: staging.path) {
                    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
                    try manager.removeItem(at: staging)
                }
            } catch { Issue.record(error) }
        }
        #expect(failure.cause is CancellationError)
        #expect(failure.cancelled)
        #expect((failure.cleanup as NSError).domain == NSCocoaErrorDomain)
        #expect((failure.cleanup as NSError).code == NSFileWriteNoPermissionError)
        #expect(failure.localizedDescription.contains(staging.path))
        #expect(try Data(contentsOf: source) == bytes)
        #expect(try Data(contentsOf: destination) == earlier)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        let remaining = try manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1)
        let completed = try #require(remaining.first)
        #expect(try Data(contentsOf: completed) == bytes)
        try removeFailedDownload(staging, cause: failure.cause)
        #expect(!manager.fileExists(atPath: staging.path))
        #expect(try Data(contentsOf: destination) == earlier)
    }
}

@Test func failedCancellationCleanupPreservesPrimaryCauseAndAllowsExplicitRemovalRetry() throws {
    let manager = FileManager.default
    let root = try interruptionDirectory()
    defer { removeInterruptionDirectory(root) }
    let directory = root.appendingPathComponent("blocked-temporary", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
        do { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        catch { Issue.record(error) }
    }
    let temporary = directory.appendingPathComponent("incomplete-source")
    let destination = root.appendingPathComponent("earlier-saved.bin")
    let temporaryBytes = Data("task-owned partial source".utf8)
    let savedBytes = Data("earlier saved output".utf8)
    try temporaryBytes.write(to: temporary)
    try savedBytes.write(to: destination)
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    do {
        try removeFailedDownload(temporary, cause: CancellationError())
        Issue.record("Cancellation cleanup must fail explicitly when its task-owned parent denies access.")
    } catch let failure as FailedDownloadCleanupError {
        #expect(failure.temporary == temporary)
        #expect(failure.cause is CancellationError)
        #expect(failure.cancelled)
        #expect((failure.cleanup as NSError).domain == NSCocoaErrorDomain)
        #expect((failure.cleanup as NSError).code == NSFileWriteNoPermissionError)
        #expect(failure.localizedDescription.contains(temporary.path))
        #expect(try Data(contentsOf: destination) == savedBytes)
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(try Data(contentsOf: temporary) == temporaryBytes)
    try removeFailedDownload(temporary, cause: CancellationError())
    #expect(!manager.fileExists(atPath: temporary.path))
    #expect(try Data(contentsOf: destination) == savedBytes)
}

extension ControlledFIFOTests {
    @Test func checksumCancellationAfterMultipleConsumedChunksCompletesWithoutChangingDestination() async throws {
        let manager = FileManager.default
        let root = try interruptionDirectory()
        defer { removeInterruptionDirectory(root) }
        let source = root.appendingPathComponent("controlled-checksum-source")
        let destination = root.appendingPathComponent("already-saved.bin")
        let earlier = Data("saved bytes must survive checksum cancellation".utf8)
        try earlier.write(to: destination)
        guard mkfifo(source.path, 0o600) == 0 else {
            throw interruptionPOSIXFailure("Create controlled checksum source", code: errno)
        }
        let descriptor = open(source.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw interruptionPOSIXFailure("Open controlled checksum source", code: errno)
        }
        var keeper: Int32? = descriptor
        defer {
            if let descriptor = keeper, close(descriptor) != 0 {
                Issue.record(interruptionPOSIXFailure("Close remaining checksum source keeper", code: errno))
            }
        }
        var file = DriveFile(id: "dynamic-checksum", name: "Source.bin", mimeType: "application/octet-stream")
        file.sha256Checksum = String(repeating: "0", count: 64)
        let selected = file
        let completion = DiskInterruptionCompletion()
        let task = Task.detached {
            do {
                try validateDownloadChecksum(source, file: selected)
                await completion.finish()
            } catch {
                await completion.finish()
                throw error
            }
        }
        do {
            let bytes = Data(repeating: 74, count: 3 * 1_048_576 + 23)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw MonitorError.invalid("Controlled checksum source did not consume its fixture before the test deadline.")
                }
                let written = bytes.withUnsafeBytes { buffer in
                    write(descriptor, buffer.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                }
                if written > 0 { offset += written }
                else if written < 0 && [EAGAIN, EINTR].contains(errno) { await Task.yield() }
                else if written < 0 { throw interruptionPOSIXFailure("Write controlled checksum source", code: errno) }
                else { throw MonitorError.invalid("Controlled checksum source returned a zero-byte write.") }
            }
            while try interruptionUnreadBytes(descriptor) != 0 {
                guard ContinuousClock.now < deadline else {
                    throw MonitorError.invalid("Checksum validation did not consume the final fixture bytes before the test deadline.")
                }
                await Task.yield()
            }
            #expect(!(await completion.finished()))
            // The pipe is drained, and the keeper prevents EOF until cancellation releases the next read.
            task.cancel()
            keeper = nil
            guard close(descriptor) == 0 else {
                throw interruptionPOSIXFailure("Release controlled checksum EOF", code: errno)
            }
            try await waitForDiskInterruption(completion)
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try Data(contentsOf: destination) == earlier)
            #expect(try interruptionAttributes(source).st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
            #expect(try manager.contentsOfDirectory(atPath: root.path).sorted() == [destination.lastPathComponent, source.lastPathComponent].sorted())
        } catch {
            let cause = error
            task.cancel()
            do {
                if let descriptor = keeper {
                    // Keep the writer until the reader either finishes or demonstrates an opened descriptor.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !(await completion.finished()) {
                        if try interruptionUnreadBytes(descriptor) == 0 { break }
                        if ContinuousClock.now >= deadline { break }
                        await Task.yield()
                    }
                    keeper = nil
                    guard close(descriptor) == 0 else {
                        throw interruptionPOSIXFailure("Release controlled checksum EOF during cleanup", code: errno)
                    }
                }
                try await waitForDiskInterruption(completion)
                do { try await task.value } catch is CancellationError {}
            } catch {
                throw MonitorError.invalid("Checksum interruption test failed: \(cause.localizedDescription). Releasing the task-owned reader also failed: \(error.localizedDescription)")
            }
            throw cause
        }
    }
}

private actor DiskInterruptionCompletion {
    private var complete = false
    func finish() { complete = true }
    func finished() -> Bool { complete }
}

private func interruptionDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

private func removeInterruptionDirectory(_ directory: URL) {
    do { try FileManager.default.removeItem(at: directory) }
    catch { Issue.record(error) }
}

private func interruptionAttributes(_ url: URL) throws -> stat {
    var attributes = stat()
    guard lstat(url.path, &attributes) == 0 else {
        throw interruptionPOSIXFailure("Read task-owned fixture attributes", code: errno)
    }
    return attributes
}

private func interruptionUnreadBytes(_ descriptor: Int32) throws -> Int32 {
    var count: Int32 = 0
    // Darwin sys/filio.h defines FIONREAD as _IOR('f', 127, int). sys/ioccom.h encodes
    // IOC_OUT, the masked C int size, ASCII group and request number; Swift cannot import _IOR.
    let request: UInt = 0x40000000 | ((UInt(MemoryLayout<CInt>.size) & 0x1fff) << 16) | (102 << 8) | 127
    guard ioctl(descriptor, request, &count) == 0 else {
        throw interruptionPOSIXFailure("Observe consumed checksum source bytes", code: errno)
    }
    return count
}

private func interruptionPOSIXFailure(_ operation: String, code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))."])
}

private func waitForDiskInterruption(_ completion: DiskInterruptionCompletion) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await completion.finished()) {
        guard ContinuousClock.now < deadline else {
            throw MonitorError.invalid("Checksum interruption did not finish after EOF release before the cleanup deadline.")
        }
        await Task.yield()
    }
}
