import Foundation
import Darwin
import Testing
@testable import DriveCore

@Test func stagedDownloadCopiesMultipleChunksPrivatelyAndPreservesSource() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source")
    let destination = directory.appendingPathComponent("destination")
    let bytes = Data(repeating: 120, count: 2 * 1_048_576 + 13)
    try bytes.write(to: source)
    try saveNewDownloadedFile(source, to: destination)
    #expect(try Data(contentsOf: destination) == bytes)
    #expect(try Data(contentsOf: source) == bytes)
    #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int == 0o600)
    try FileManager.default.removeItem(at: directory)
}

extension ControlledFIFOTests {
    @Test func cancellationDuringStagingStopsAnIncompleteCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("controlled-source")
        let destination = directory.appendingPathComponent("partial-staging")
        let descriptor: Int32
        do {
            guard mkfifo(source.path, 0o600) == 0 else { throw stagingFixtureFailure("Create controlled source", code: errno) }
            descriptor = open(source.path, O_RDWR | O_NONBLOCK)
            guard descriptor >= 0 else { throw stagingFixtureFailure("Open controlled source", code: errno) }
        } catch {
            let cause = error
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw MonitorError.invalid("Staging fixture setup failed: \(cause.localizedDescription). Task-owned cleanup also failed: \(error.localizedDescription)") }
            throw cause
        }
        var keeper: Int32? = descriptor
        let state = StagingCopyCompletion()
        let task = Task.detached {
            do { try copyDownloadChunks(source, to: destination); await state.finish() }
            catch { await state.finish(); throw error }
        }
        do {
            let bytes = Data(repeating: 120, count: 1_048_576)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Controlled staging source did not finish writing before the test deadline.") }
                let written = bytes.withUnsafeBytes { buffer in
                    write(descriptor, buffer.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                }
                if written > 0 { offset += written }
                else if written < 0 && [EAGAIN, EINTR].contains(errno) { await Task.yield() }
                else if written < 0 { throw stagingFixtureFailure("Write controlled source", code: errno) }
                else { throw MonitorError.invalid("Write controlled source returned zero bytes before completing the fixture.") }
            }
            while !FileManager.default.fileExists(atPath: destination.path) {
                guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Staging did not create its destination before the test deadline.") }
                await Task.yield()
            }
            while try stagingFileAttributes(destination).st_size < Int64(bytes.count) {
                guard ContinuousClock.now < deadline else { throw MonitorError.invalid("Staging did not save the first chunk before the test deadline.") }
                await Task.yield()
            }
            // The keeper prevents EOF, so the copy cannot finish before cancellation.
            task.cancel()
            keeper = nil
            guard close(descriptor) == 0 else { throw stagingFixtureFailure("Close controlled source", code: errno) }
            try await waitForStagingCompletion(state)
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try Data(contentsOf: destination) == bytes)
            let attributes = try stagingFileAttributes(destination)
            #expect(attributes.st_size == Int64(bytes.count))
            #expect(attributes.st_mode & 0o777 == 0o600)
            #expect(try stagingFileAttributes(source).st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
        } catch {
            let cause = error
            task.cancel()
            do {
                if let descriptor = keeper {
                    // Destination creation follows reader-open; keep the writer alive until that point.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !FileManager.default.fileExists(atPath: destination.path) {
                        if await state.finished() { break }
                        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The staging reader did not open or finish before the cleanup deadline.") }
                        await Task.yield()
                    }
                    keeper = nil
                    guard close(descriptor) == 0 else { throw stagingFixtureFailure("Close controlled source during cleanup", code: errno) }
                }
                try await waitForStagingCompletion(state)
                do { try await task.value } catch is CancellationError {}
                try FileManager.default.removeItem(at: directory)
            } catch { throw MonitorError.invalid("Staging cancellation test failed: \(cause.localizedDescription). Task-owned cleanup also failed: \(error.localizedDescription)") }
            throw cause
        }
        try FileManager.default.removeItem(at: directory)
    }
}

private actor StagingCopyCompletion {
    private var complete = false
    func finish() { complete = true }
    func finished() -> Bool { complete }
}

private func waitForStagingCompletion(_ state: StagingCopyCompletion) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await state.finished()) {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("The staging copy did not finish before the cleanup deadline.") }
        await Task.yield()
    }
}

private func stagingFileAttributes(_ url: URL) throws -> stat {
    var attributes = stat()
    guard lstat(url.path, &attributes) == 0 else { throw stagingFixtureFailure("Read fresh staging attributes", code: errno) }
    return attributes
}

private func stagingFixtureFailure(_ operation: String, code: Int32) -> MonitorError {
    .invalid("\(operation) failed: \(String(cString: strerror(code))) (errno \(code)).")
}
