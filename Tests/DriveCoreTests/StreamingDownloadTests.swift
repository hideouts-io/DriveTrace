import Foundation
import Network
import CryptoKit
import Darwin
import os
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

    @Test func cancelledCloseFailureStopsBatchWithoutCancellingItsSwiftTask() async throws {
        let cancelled = try await nativeCancelledURLSessionFailure()
        let first = streamFixtureFile(id: "saved-close", name: "Saved.bin", bytes: 1_048_576)
        let second = streamFixtureFile(id: "cancelled-close", name: "Cancelled.bin", bytes: 2 * 1_048_576 + 19)
        let last = streamFixtureFile(id: "later-close", name: "Unattempted.bin", bytes: 65_536)
        let files = [first, second, last]
        let fixture = try await StreamingFixture.open(files: files, responses: [first.id: .complete(1_048_576), second.id: .complete(2 * 1_048_576 + 19), last.id: .complete(65_536)])
        let observed = OSAllocatedUnfairLock<DownloadFileCloseError?>(initialState: nil)
        let temporary = OSAllocatedUnfairLock<URL?>(initialState: nil)
        do {
            let sentinel = fixture.directory.appendingPathComponent("existing.txt")
            let earlier = Data("Earlier bytes must survive a cancelled close failure".utf8)
            try earlier.write(to: sentinel, options: .withoutOverwriting)
            let tokens = FixtureTokens(); await tokens.grantManagement()
            let client = GoogleClient(tokens: tokens, session: fixture.session, saveNewFile: { @Sendable [observed, temporary, second, cancelled] source, destination in
                guard destination.lastPathComponent == second.name else { try saveNewDownloadedFile(source, to: destination); return }
                temporary.withLock { $0 = source }
                try stageDownloadedFile(source, destination: destination) { staged in
                    #expect(!Task.isCancelled)
                    #expect(try streamFileDigest(staged) == second.sha256Checksum)
                    #expect(try streamFileAttributes(staged).st_size == 2 * 1_048_576 + 19)
                    #expect(try streamFileAttributes(staged).st_mode & 0o777 == 0o600)
                    let reader = try FileHandle(forReadingFrom: staged)
                    do {
                        try withDownloadFileHandle(reader, file: staged, operation: .stagingInput, closing: closeFixtureWithPOSIXFailure) { handle in
                            #expect(try handle.read(upToCount: 65_536) == streamFixtureChunk)
                            throw cancelled
                        }
                        throw MonitorError.invalid("The controlled cancelled close boundary unexpectedly reached commit.")
                    } catch let failure as DownloadFileCloseError {
                        observed.withLock { $0 = failure }
                        throw failure
                    }
                }
            })
            let plan = DownloadPlan(items: files.map { DownloadItem(file: $0, components: [$0.name]) }, issues: [])
            let report = try await runCleanupBatch(client, plan: plan, parent: fixture.directory)
            #expect(!Task.isCancelled)
            #expect(report.cancelled)
            try assertCancelledCleanupReport(report, first: first, second: second, last: last)
            let failure = try #require(observed.withLock { $0 })
            #expect(failure.cancelled)
            let original = try #require(failure.cause as? URLError)
            #expect(original.code == .cancelled)
            #expect((failure.closing as NSError).domain == NSPOSIXErrorDomain)
            #expect((failure.closing as NSError).code == Int(EBADF))
            #expect(report.results[1].message == failure.localizedDescription)
            #expect(!FileManager.default.fileExists(atPath: failure.file.deletingLastPathComponent().path))
            let returnedTemporary = try #require(temporary.withLock { $0 })
            #expect(!FileManager.default.fileExists(atPath: returnedTemporary.path))
            #expect(try Data(contentsOf: sentinel) == earlier)
            try assertCleanupReportRoundTrip(report)
            #expect(await fixture.router.requests() == ["metadata:" + first.id, "media:" + first.id, "metadata:" + second.id, "media:" + second.id])
            #expect(await fixture.server.snapshot().paths == ["/media/" + first.id, "/media/" + second.id])
            #expect(await fixture.server.snapshot().failures.isEmpty)
        } catch { try await fixture.close(after: error); throw error }
        try await fixture.close()
    }

    @Test func cancelledBatchRetainsStageCleanupFailureAndRemovesTransportTemporary() async throws {
        let first = streamFixtureFile(id: "saved-stage", name: "Saved.bin", bytes: 1_048_576)
        let second = streamFixtureFile(id: "cancelled-stage", name: "Cancelled.bin", bytes: 2 * 1_048_576 + 19)
        let last = streamFixtureFile(id: "later-stage", name: "Unattempted.bin", bytes: 65_536)
        let files = [first, second, last]
        let fixture = try await StreamingFixture.open(files: files, responses: [first.id: .complete(1_048_576), second.id: .complete(2 * 1_048_576 + 19), last.id: .complete(65_536)])
        let saver = CleanupFaultSaver(directory: fixture.directory, selected: second)
        do {
            let sentinel = fixture.directory.appendingPathComponent("existing.txt")
            let original = Data("Earlier parent content must survive cancelled cleanup".utf8)
            try original.write(to: sentinel, options: .withoutOverwriting)
            let tokens = FixtureTokens(); await tokens.grantManagement()
            let client = GoogleClient(tokens: tokens, session: fixture.session, saveNewFile: { @Sendable [saver] source, destination in try saver.saveCancellingStage(source, destination) })
            let plan = DownloadPlan(items: files.map { DownloadItem(file: $0, components: [$0.name]) }, issues: [])
            let report = try await runCleanupBatch(client, plan: plan, parent: fixture.directory)
            try saver.requirePreparedBoundary()
            try assertCancelledCleanupReport(report, first: first, second: second, last: last)
            let recorded = saver.snapshot()
            let temporary = try #require(recorded.temporary)
            let stageFailure = try #require(recorded.stageFailure)
            #expect(stageFailure.cause is CancellationError)
            #expect(stageFailure.cancelled)
            #expect(stageFailure.temporary == saver.staging)
            #expect((stageFailure.cleanup as NSError).domain == NSCocoaErrorDomain)
            #expect((stageFailure.cleanup as NSError).code == NSFileWriteNoPermissionError)
            #expect(report.results[1].message == stageFailure.localizedDescription)
            #expect(report.results[1].message?.contains(saver.staging.path) == true)
            #expect(!FileManager.default.fileExists(atPath: temporary.url.path))
            #expect(try Data(contentsOf: sentinel) == original)
            #expect(try streamFileDigest(report.directory.appendingPathComponent("Files/" + first.name)) == first.sha256Checksum)
            try assertCleanupReportRoundTrip(report)
            #expect(await fixture.router.requests() == ["metadata:" + first.id, "media:" + first.id, "metadata:" + second.id, "media:" + second.id])
            #expect(await fixture.server.snapshot().paths == ["/media/" + first.id, "/media/" + second.id])
            #expect(await fixture.server.snapshot().failures.isEmpty)
            try saver.repair()
            #expect(!FileManager.default.fileExists(atPath: saver.staging.path))
            #expect(try streamFileDigest(report.directory.appendingPathComponent("Files/" + first.name)) == first.sha256Checksum)
        } catch { try await closeCleanupFixture(fixture, saver: saver, after: error) }
        try await closeCleanupFixture(fixture, saver: saver)
    }

    @Test func cancelledBatchRetainsNestedStageAndImmutableTransportCleanupFailures() async throws {
        let first = streamFixtureFile(id: "saved-nested", name: "Saved.bin", bytes: 1_048_576)
        let second = streamFixtureFile(id: "cancelled-nested", name: "Cancelled.bin", bytes: 2 * 1_048_576 + 19)
        let last = streamFixtureFile(id: "later-nested", name: "Unattempted.bin", bytes: 65_536)
        let files = [first, second, last]
        let fixture = try await StreamingFixture.open(files: files, responses: [first.id: .complete(1_048_576), second.id: .complete(2 * 1_048_576 + 19), last.id: .complete(65_536)])
        let saver = CleanupFaultSaver(directory: fixture.directory, selected: second)
        do {
            let sentinel = fixture.directory.appendingPathComponent("existing.txt")
            let original = Data("Earlier content must survive both real cleanup failures".utf8)
            try original.write(to: sentinel, options: .withoutOverwriting)
            let tokens = FixtureTokens(); await tokens.grantManagement()
            let client = GoogleClient(tokens: tokens, session: fixture.session, saveNewFile: { @Sendable [saver] source, destination in try saver.saveCancellingStageAndTransport(source, destination) })
            let plan = DownloadPlan(items: files.map { DownloadItem(file: $0, components: [$0.name]) }, issues: [])
            let report = try await runCleanupBatch(client, plan: plan, parent: fixture.directory)
            try saver.requirePreparedBoundary()
            try assertCancelledCleanupReport(report, first: first, second: second, last: last)
            let recorded = saver.snapshot()
            let temporary = try #require(recorded.temporary)
            let stageFailure = try #require(recorded.stageFailure)
            #expect(stageFailure.cause is CancellationError)
            #expect(stageFailure.cancelled)
            #expect((stageFailure.cleanup as NSError).domain == NSCocoaErrorDomain)
            #expect((stageFailure.cleanup as NSError).code == NSFileWriteNoPermissionError)
            let message = try #require(report.results[1].message)
            #expect(message.hasPrefix("Download cancelled before completion"))
            #expect(message.contains(stageFailure.localizedDescription))
            #expect(message.contains(saver.staging.path))
            #expect(message.contains(temporary.url.path))
            try saver.assertImmutableFailedRemoval(stageFailure, message: message)
            let retained = try streamFileAttributes(temporary.url)
            #expect(retained.st_flags & UInt32(UF_IMMUTABLE) != 0)
            #expect(retained.st_dev == temporary.identity.device && retained.st_ino == temporary.identity.inode)
            #expect(try streamFileDigest(temporary.url) == second.sha256Checksum)
            #expect(try Data(contentsOf: sentinel) == original)
            try assertCleanupReportRoundTrip(report)
            #expect(await fixture.router.requests() == ["metadata:" + first.id, "media:" + first.id, "metadata:" + second.id, "media:" + second.id])
            #expect(await fixture.server.snapshot().paths == ["/media/" + first.id, "/media/" + second.id])
            #expect(await fixture.server.snapshot().failures.isEmpty)
            try saver.repair()
            #expect(!FileManager.default.fileExists(atPath: saver.staging.path))
            #expect(!FileManager.default.fileExists(atPath: temporary.url.path))
            #expect(try streamFileDigest(report.directory.appendingPathComponent("Files/" + first.name)) == first.sha256Checksum)
        } catch { try await closeCleanupFixture(fixture, saver: saver, after: error) }
        try await closeCleanupFixture(fixture, saver: saver)
    }

    @Test func committedBatchTransportCleanupWarningKeepsSavedOutcomeAndContinues() async throws {
        let first = streamFixtureFile(id: "warning-first", name: "SavedWithWarning.bin", bytes: 2 * 1_048_576 + 19)
        let next = streamFixtureFile(id: "warning-next", name: "Next.bin", bytes: 1_048_576)
        let files = [first, next]
        let fixture = try await StreamingFixture.open(files: files, responses: [first.id: .complete(2 * 1_048_576 + 19), next.id: .complete(1_048_576)])
        let saver = CleanupFaultSaver(directory: fixture.directory, selected: first)
        do {
            let sentinel = fixture.directory.appendingPathComponent("existing.txt")
            let original = Data("Earlier parent content must survive a cleanup warning".utf8)
            try original.write(to: sentinel, options: .withoutOverwriting)
            let tokens = FixtureTokens(); await tokens.grantManagement()
            let client = GoogleClient(tokens: tokens, session: fixture.session, saveNewFile: { @Sendable [saver] source, destination in try saver.saveWithTransportCleanupFailure(source, destination) })
            let plan = DownloadPlan(items: files.map { DownloadItem(file: $0, components: [$0.name]) }, issues: [])
            let report = try await runCleanupBatch(client, plan: plan, parent: fixture.directory)
            try saver.requirePreparedBoundary()
            #expect(!report.cancelled)
            #expect(report.planned == 2 && report.completed == 2 && report.failures == 0 && report.remaining == 0)
            #expect(report.cleanupWarnings == 1)
            try #require(report.results.count == 2)
            #expect(report.results.map(\.path) == files.map(\.name))
            #expect(report.results.map(\.outcome) == [.downloaded, .downloaded])
            #expect(report.results[1].message == nil)
            let temporary = try #require(saver.snapshot().temporary)
            let message = try #require(report.results[0].message)
            #expect(message.contains("was saved"))
            #expect(message.contains(report.directory.appendingPathComponent("Files/" + first.name).path))
            #expect(message.contains(temporary.url.path))
            #expect(message.contains("before downloading again"))
            try saver.assertImmutableSavedRemoval(destination: report.directory.appendingPathComponent("Files/" + first.name), message: message)
            #expect(try streamFileAttributes(temporary.url).st_flags & UInt32(UF_IMMUTABLE) != 0)
            #expect(try streamFileDigest(temporary.url) == first.sha256Checksum)
            for file in files {
                let saved = report.directory.appendingPathComponent("Files/" + file.name)
                #expect(try streamFileDigest(saved) == file.sha256Checksum)
                let expectedSize = try #require(file.size.flatMap(Int64.init))
                #expect(try streamFileAttributes(saved).st_size == expectedSize)
                #expect(try streamFileAttributes(saved).st_mode & 0o777 == 0o600)
            }
            #expect(try Data(contentsOf: sentinel) == original)
            try assertCleanupReportRoundTrip(report)
            #expect(await fixture.router.requests() == ["metadata:" + first.id, "media:" + first.id, "metadata:" + next.id, "media:" + next.id])
            #expect(await fixture.server.snapshot().paths == ["/media/" + first.id, "/media/" + next.id])
            #expect(await fixture.server.snapshot().failures.isEmpty)
            try saver.repair()
            #expect(!FileManager.default.fileExists(atPath: temporary.url.path))
            #expect(try streamFileDigest(report.directory.appendingPathComponent("Files/" + first.name)) == first.sha256Checksum)
        } catch { try await closeCleanupFixture(fixture, saver: saver, after: error) }
        try await closeCleanupFixture(fixture, saver: saver)
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

private func runCleanupBatch(_ client: GoogleClient, plan: DownloadPlan, parent: URL) async throws -> BatchDownloadReport {
    let completion = StreamingCompletion()
    let task = Task {
        do {
            let report = try await client.downloadBatch(plan: plan, parent: parent, progress: { _ in })
            await completion.finish()
            return report
        } catch { await completion.finish(); throw error }
    }
    do {
        try await waitForStreamCondition("complete batch cleanup outcomes and automatic report", seconds: 5) { await completion.finished() }
    } catch {
        let cause = error
        task.cancel()
        do {
            try await waitForStreamCondition("cancelled cleanup batch to finish before fixture repair", seconds: 5) { await completion.finished() }
            do { _ = try await task.value }
            catch is CancellationError {}
            catch let failure as URLError where failure.code == .cancelled {}
        } catch { throw MonitorError.invalid("Batch cleanup check failed: \(cause.localizedDescription). Finishing its owned batch also failed: \(error.localizedDescription).") }
        throw cause
    }
    return try await task.value
}

private func assertCancelledCleanupReport(_ report: BatchDownloadReport, first: DriveFile, second: DriveFile, last: DriveFile) throws {
    try #require(report.results.count == 2)
    #expect(report.cancelled)
    #expect(report.planned == 3 && report.completed == 1 && report.failures == 1 && report.remaining == 1)
    #expect(report.cleanupWarnings == 0)
    #expect(report.summary.hasPrefix("Cancelled"))
    #expect(report.results.map(\.path) == [first.name, second.name])
    #expect(report.results.map(\.outcome) == [.downloaded, .failed])
    #expect(report.unattempted == [last.name])
    #expect(report.issues.isEmpty)
    let content = report.directory.appendingPathComponent("Files", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: content.path) == [first.name])
    let saved = content.appendingPathComponent(first.name)
    #expect(try streamFileDigest(saved) == first.sha256Checksum)
    let expectedSize = try #require(first.size.flatMap(Int64.init))
    #expect(try streamFileAttributes(saved).st_size == expectedSize)
    #expect(try streamFileAttributes(saved).st_mode & 0o777 == 0o600)
}

private func assertCleanupReportRoundTrip(_ report: BatchDownloadReport) throws {
    let reportURL = report.directory.appendingPathComponent("download-report.json")
    let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: reportURL))
    #expect(saved.directory == report.directory && saved.planned == report.planned && saved.cancelled == report.cancelled)
    #expect(saved.results.map(\.id) == report.results.map(\.id))
    #expect(saved.results.map(\.path) == report.results.map(\.path))
    #expect(saved.results.map(\.outcome) == report.results.map(\.outcome))
    #expect(saved.results.map(\.message) == report.results.map(\.message))
    #expect(saved.issues.map(\.id) == report.issues.map(\.id))
    #expect(saved.issues.map(\.path) == report.issues.map(\.path))
    #expect(saved.issues.map(\.reason) == report.issues.map(\.reason))
    #expect(saved.unattempted == report.unattempted)
    #expect(saved.completed == report.completed && saved.failures == report.failures && saved.remaining == report.remaining)
    #expect(saved.cleanupWarnings == report.cleanupWarnings)
    #expect(try streamFileAttributes(reportURL).st_mode & 0o777 == 0o600)
    #expect(try streamFileAttributes(report.directory).st_mode & 0o777 == 0o700)
}

private func closeCleanupFixture(_ fixture: StreamingFixture, saver: CleanupFaultSaver) async throws {
    var repairFailure: (any Error)?
    do { try saver.repair() } catch { repairFailure = error }
    do { try await fixture.close() }
    catch {
        if let repairFailure { throw MonitorError.invalid("Repairing owned cleanup fixtures failed: \(repairFailure.localizedDescription). Closing their listener/directory also failed: \(error.localizedDescription).") }
        throw error
    }
    if let repairFailure { throw repairFailure }
}

private func closeCleanupFixture(_ fixture: StreamingFixture, saver: CleanupFaultSaver, after cause: any Error) async throws -> Never {
    do { try await closeCleanupFixture(fixture, saver: saver) }
    catch { throw MonitorError.invalid("Batch cleanup check failed: \(cause.localizedDescription). Task-owned repair/closure also failed: \(error.localizedDescription).") }
    throw cause
}

private struct CleanupFileIdentity: Sendable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    func matches(_ attributes: stat) -> Bool { attributes.st_dev == device && attributes.st_ino == inode && attributes.st_uid == owner }
}

private struct OwnedCleanupTemporary: Sendable {
    let url: URL
    let identity: CleanupFileIdentity
    let originalFlags: UInt32
}

private struct CleanupFaultState: Sendable {
    var temporary: OwnedCleanupTemporary?
    var stagingIdentity: CleanupFileIdentity?
    var stageFailure: FailedDownloadCleanupError?
    var preparationFailure: (any Error)?
}

/// Only exact URLSession-returned files and this connector's private staging directory are changed.
private final class CleanupFaultSaver: Sendable {
    let staging: URL
    private let selected: DriveFile
    private let state = OSAllocatedUnfairLock(initialState: CleanupFaultState(temporary: nil, stagingIdentity: nil, stageFailure: nil, preparationFailure: nil))
    init(directory: URL, selected: DriveFile) {
        self.staging = directory.appendingPathComponent("owned-cleanup-staging", isDirectory: true)
        self.selected = selected
    }
    func snapshot() -> CleanupFaultState { state.withLock { $0 } }
    func requirePreparedBoundary() throws { if let failure = snapshot().preparationFailure { throw failure } }

    func saveCancellingStage(_ source: URL, _ destination: URL) throws {
        guard destination.lastPathComponent == selected.name else { try saveNewDownloadedFile(source, to: destination); return }
        do { try recordTemporary(source) }
        catch { state.withLock { $0.preparationFailure = error }; throw error }
        try cancelWithDeniedStaging(source, destination: destination)
    }

    func saveCancellingStageAndTransport(_ source: URL, _ destination: URL) throws {
        guard destination.lastPathComponent == selected.name else { try saveNewDownloadedFile(source, to: destination); return }
        do { try recordTemporary(source); try protectTemporary() }
        catch { state.withLock { $0.preparationFailure = error }; throw error }
        try cancelWithDeniedStaging(source, destination: destination)
    }

    func saveWithTransportCleanupFailure(_ source: URL, _ destination: URL) throws {
        guard destination.lastPathComponent == selected.name else { try saveNewDownloadedFile(source, to: destination); return }
        do { try recordTemporary(source); try protectTemporary() }
        catch { state.withLock { $0.preparationFailure = error }; throw error }
        try saveNewDownloadedFile(source, to: destination)
    }

    private func recordTemporary(_ source: URL) throws {
        let attributes = try streamFileAttributes(source)
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_uid == geteuid() else {
            throw MonitorError.invalid("The URLSession cleanup fixture must be an owned regular file, never a symlink or another user's file.")
        }
        guard let size = selected.size.flatMap(Int64.init), attributes.st_size == size, try streamFileDigest(source) == selected.sha256Checksum else {
            throw MonitorError.invalid("The returned URLSession temporary did not match the complete known response before cleanup fault injection.")
        }
        let owned = OwnedCleanupTemporary(url: source, identity: CleanupFileIdentity(device: attributes.st_dev, inode: attributes.st_ino, owner: attributes.st_uid), originalFlags: attributes.st_flags)
        try state.withLock {
            guard $0.temporary == nil else { throw MonitorError.invalid("The selected cleanup-failure item unexpectedly reached its saver more than once.") }
            $0.temporary = owned
        }
    }

    private func protectTemporary() throws {
        let temporary = try #require(snapshot().temporary)
        let descriptor = open(temporary.url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw cleanupFixturePOSIXFailure("Open exact owned transport temporary before immutable protection", code: errno) }
        do {
            let attributes = try cleanupDescriptorAttributes(descriptor)
            guard temporary.identity.matches(attributes), attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_flags == temporary.originalFlags else {
                throw MonitorError.invalid("The transport temporary identity or original flags changed before immutable protection; no foreign file may be changed.")
            }
            guard attributes.st_flags & UInt32(UF_IMMUTABLE) == 0 else { throw MonitorError.invalid("The returned transport temporary was already immutable; the intended real flag-change boundary cannot be verified.") }
            guard fchflags(descriptor, temporary.originalFlags | UInt32(UF_IMMUTABLE)) == 0 else {
                throw cleanupFixturePOSIXFailure("Set UF_IMMUTABLE on the exact owned transport temporary; this filesystem must support the validation boundary", code: errno)
            }
            let protected = try cleanupDescriptorAttributes(descriptor)
            guard temporary.identity.matches(protected), protected.st_flags == temporary.originalFlags | UInt32(UF_IMMUTABLE) else {
                throw MonitorError.invalid("The exact transport temporary did not retain its verified identity and immutable flag.")
            }
        } catch {
            let cause = error
            guard close(descriptor) == 0 else {
                let code = errno
                throw MonitorError.invalid("Transport temporary protection failed: \(cause.localizedDescription). Closing its descriptor also failed: \(cleanupFixturePOSIXFailure("Close protected transport temporary", code: code).localizedDescription).")
            }
            throw cause
        }
        guard close(descriptor) == 0 else { throw cleanupFixturePOSIXFailure("Close protected transport temporary", code: errno) }
    }

    private func cancelWithDeniedStaging(_ source: URL, destination: URL) throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let attributes = try streamFileAttributes(staging)
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), attributes.st_uid == geteuid() else {
            throw MonitorError.invalid("The private staging fixture must be this task's owned directory before cancellation.")
        }
        state.withLock { $0.stagingIdentity = CleanupFileIdentity(device: attributes.st_dev, inode: attributes.st_ino, owner: attributes.st_uid) }
        do {
            try stageDownloadedFile(source, destination: destination, staging: staging) { staged in
                let expectedSize = try #require(selected.size.flatMap(Int64.init))
                guard try streamFileDigest(staged) == selected.sha256Checksum, try streamFileAttributes(staged).st_size == expectedSize, try streamFileAttributes(staged).st_mode & 0o777 == 0o600 else {
                    throw MonitorError.invalid("Production staging did not preserve the completed known body before controlled cancellation.")
                }
                try withUnsafeCurrentTask { task in
                    guard let task else { throw MonitorError.invalid("The cleanup cancellation boundary must execute inside its owned Swift batch task.") }
                    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: staging.path)
                    task.cancel()
                }
                try Task.checkCancellation()
            }
            throw MonitorError.invalid("The controlled cancelled stage unexpectedly committed.")
        } catch let failure as FailedDownloadCleanupError {
            state.withLock { $0.stageFailure = failure }
            throw failure
        }
    }

    func assertImmutableFailedRemoval(_ cause: FailedDownloadCleanupError, message: String) throws {
        let temporary = try verifiedImmutableTemporary()
        do {
            try removeFailedDownload(temporary.url, cause: cause)
            throw MonitorError.invalid("The exact immutable transport temporary unexpectedly allowed failed-transfer cleanup.")
        } catch let failure as FailedDownloadCleanupError {
            #expect(failure.temporary == temporary.url)
            #expect(failure.cancelled)
            let retainedStage = try #require(failure.cause as? FailedDownloadCleanupError)
            #expect(retainedStage.cause is CancellationError)
            #expect(retainedStage.temporary == staging)
            #expect(retainedStage.cleanup.localizedDescription == cause.cleanup.localizedDescription)
            #expect((failure.cleanup as NSError).domain == NSCocoaErrorDomain)
            #expect((failure.cleanup as NSError).code == NSFileWriteNoPermissionError)
            #expect(failure.localizedDescription == message)
        }
    }

    func assertImmutableSavedRemoval(destination: URL, message: String) throws {
        let temporary = try verifiedImmutableTemporary()
        do {
            try removeSavedDownloadTemporary(temporary.url, destination: destination)
            throw MonitorError.invalid("The exact immutable transport temporary unexpectedly allowed saved-transfer cleanup.")
        } catch let failure as SavedDownloadCleanupError {
            #expect(failure.destination == destination)
            #expect(failure.failures.count == 1)
            let detail = try #require(failure.failures.first)
            #expect(detail.temporary == temporary.url)
            #expect((detail.cause as NSError).domain == NSCocoaErrorDomain)
            #expect((detail.cause as NSError).code == NSFileWriteNoPermissionError)
            #expect(failure.localizedDescription == message)
        }
    }

    private func verifiedImmutableTemporary() throws -> OwnedCleanupTemporary {
        let temporary = try #require(snapshot().temporary)
        let attributes = try streamFileAttributes(temporary.url)
        guard temporary.identity.matches(attributes), attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_uid == geteuid(), attributes.st_flags == temporary.originalFlags | UInt32(UF_IMMUTABLE) else {
            throw MonitorError.invalid("Repeated cleanup refusal must inspect the exact owned immutable transport inode; no replacement file may be removed.")
        }
        return temporary
    }

    func repair() throws {
        let recorded = snapshot()
        var stageRepairFailure: (any Error)?
        do {
            if let identity = recorded.stagingIdentity, FileManager.default.fileExists(atPath: staging.path) {
                let attributes = try streamFileAttributes(staging)
                guard identity.matches(attributes), attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    throw MonitorError.invalid("Owned staging identity changed before repair; no replacement directory may be modified.")
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
                let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                guard files.count == 1, let staged = files.first, try streamFileDigest(staged) == selected.sha256Checksum else {
                    throw MonitorError.invalid("The retained staging fixture lost its completed known bytes before explicit removal.")
                }
                try FileManager.default.removeItem(at: staging)
            }
        } catch { stageRepairFailure = error }
        do { if let temporary = recorded.temporary { try repairCleanupTemporary(temporary) } }
        catch {
            if let stageRepairFailure { throw MonitorError.invalid("Repairing the owned staging fixture failed: \(stageRepairFailure.localizedDescription). Repairing its exact transport temporary also failed: \(error.localizedDescription).") }
            throw error
        }
        if let stageRepairFailure { throw stageRepairFailure }
    }
}

private func cleanupDescriptorAttributes(_ descriptor: Int32) throws -> stat {
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0 else { throw cleanupFixturePOSIXFailure("Inspect exact owned cleanup descriptor", code: errno) }
    return attributes
}

private func repairCleanupTemporary(_ temporary: OwnedCleanupTemporary) throws {
    let descriptor = open(temporary.url.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
        let code = errno
        guard code == ENOENT else { throw cleanupFixturePOSIXFailure("Open exact owned transport temporary for repair", code: code) }
        return
    }
    do {
        let attributes = try cleanupDescriptorAttributes(descriptor)
        guard temporary.identity.matches(attributes), attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_uid == geteuid() else {
            throw MonitorError.invalid("Transport temporary identity changed before repair; no foreign inode may have its flags changed or be removed.")
        }
        guard fchflags(descriptor, temporary.originalFlags) == 0 else { throw cleanupFixturePOSIXFailure("Restore original flags on the verified owned transport inode", code: errno) }
        let repaired = try cleanupDescriptorAttributes(descriptor)
        guard temporary.identity.matches(repaired), repaired.st_flags == temporary.originalFlags else { throw MonitorError.invalid("The owned transport inode did not recover its exact original flags.") }
        let path = try streamFileAttributes(temporary.url)
        guard temporary.identity.matches(path), path.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw MonitorError.invalid("The transport temporary pathname no longer names the verified repaired inode; no replacement item may be removed.")
        }
        try FileManager.default.removeItem(at: temporary.url)
    } catch {
        let cause = error
        guard close(descriptor) == 0 else {
            let code = errno
            throw MonitorError.invalid("Exact transport temporary repair failed: \(cause.localizedDescription). Closing its descriptor also failed: \(cleanupFixturePOSIXFailure("Close repaired transport descriptor", code: code).localizedDescription).")
        }
        throw cause
    }
    guard close(descriptor) == 0 else { throw cleanupFixturePOSIXFailure("Close repaired transport descriptor", code: errno) }
}

private func cleanupFixturePOSIXFailure(_ operation: String, code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))."])
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
        Task { @Sendable [self] in
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
