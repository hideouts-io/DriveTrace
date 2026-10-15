import Darwin
import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

@Test func reportCopyPreservesEveryOutcomeAndPrivatePermissions() throws {
    let root = try reportRecoveryDirectory()
    defer { removeReportRecoveryDirectory(root) }
    let results = (0..<160).map { index in
        DownloadResult(id: UUID(), path: "Folder/Item \(index)", outcome: index < 120 ? .downloaded : index < 150 ? .folderCreated : .failed,
                       message: index < 120 ? (index.isMultiple(of: 20) ? "Saved with a temporary cleanup warning" : nil) : index >= 150 ? "Access denied" : nil)
    }
    let issues = [DownloadIssue(path: "Shortcut", reason: "Shortcut skipped"), DownloadIssue(path: "Unavailable", reason: "Folder listing failed"), DownloadIssue(path: "Repeated", reason: "Already encountered")]
    let report = BatchDownloadReport(directory: root, planned: 295, results: results, issues: issues,
                                     unattempted: (0..<135).map { "Not attempted/\($0)" }, cancelled: true)
    let destination = root.appendingPathComponent("complete-report.json")
    #expect(try saveBatchDownloadReport(report, to: destination) == destination)
    let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: destination))
    #expect(try encodedReportRecovery(saved) == encodedReportRecovery(report))
    #expect(saved.results.count == 160)
    #expect(saved.results.last?.path == "Folder/Item 159")
    #expect(saved.unattempted.count == 135)
    #expect(saved.unattempted.last == "Not attempted/134")
    #expect(saved.completed == 120); #expect(saved.failures == 13); #expect(saved.remaining == 135)
    #expect(saved.cleanupWarnings == 6); #expect(saved.cancelled)
    #expect(try reportRecoveryMode(destination) == 0o600)
    #expect(try reportRecoveryMode(root) == 0o700)
}

@Test func reportCopyRejectsOccupiedFilesAndSymlinksWithoutChangingTargets() throws {
    let manager = FileManager.default
    let root = try reportRecoveryDirectory()
    defer { removeReportRecoveryDirectory(root) }
    let report = reportRecoveryOutcomes(root)
    let bytes = Data("existing private content".utf8)
    let existing = root.appendingPathComponent("existing.json")
    let link = root.appendingPathComponent("linked.json")
    let dangling = root.appendingPathComponent("dangling.json")
    let absentTarget = root.appendingPathComponent("absent.json")
    try bytes.write(to: existing, options: .withoutOverwriting)
    try manager.createSymbolicLink(atPath: link.path, withDestinationPath: existing.path)
    try manager.createSymbolicLink(atPath: dangling.path, withDestinationPath: absentTarget.path)
    for destination in [existing, link, dangling] {
        do {
            _ = try saveBatchDownloadReport(report, to: destination)
            Issue.record("An occupied path must reject report persistence.")
        } catch let failure as BatchDownloadReportSaveError {
            #expect(failure.destination == destination)
            #expect(try encodedReportRecovery(failure.report) == encodedReportRecovery(report))
            #expect(failure.cleanup == nil)
            let cause = failure.cause as NSError
            #expect(cause.domain == NSCocoaErrorDomain)
            #expect(cause.code == NSFileWriteFileExistsError)
            let kernelCause = try #require(cause.userInfo[NSUnderlyingErrorKey] as? NSError)
            #expect(kernelCause.domain == NSPOSIXErrorDomain)
            #expect(kernelCause.code == Int(EEXIST))
        }
    }
    #expect(try Data(contentsOf: existing) == bytes)
    #expect(try manager.destinationOfSymbolicLink(atPath: link.path) == existing.path)
    #expect(try manager.destinationOfSymbolicLink(atPath: dangling.path) == absentTarget.path)
    #expect(!manager.fileExists(atPath: absentTarget.path))
}

@Test func reportCopyDestinationFailuresAllowRetryWithoutLosingOutcomes() throws {
    let manager = FileManager.default
    let root = try reportRecoveryDirectory()
    let denied = root.appendingPathComponent("denied", isDirectory: true)
    try manager.createDirectory(at: denied, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
        do { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        catch { Issue.record(error) }
        removeReportRecoveryDirectory(root)
    }
    let report = reportRecoveryOutcomes(root)
    let missing = root.appendingPathComponent("missing/report.json")
    let blocked = denied.appendingPathComponent("report.json")
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
    for (destination, code) in [(missing, ENOENT), (blocked, EACCES)] {
        do {
            _ = try saveBatchDownloadReport(report, to: destination)
            Issue.record("The inaccessible destination must fail explicitly.")
        } catch let failure as BatchDownloadReportSaveError {
            #expect(failure.destination == destination)
            #expect(try encodedReportRecovery(failure.report) == encodedReportRecovery(report))
            #expect((failure.cause as NSError).domain == NSPOSIXErrorDomain)
            #expect((failure.cause as NSError).code == Int(code))
            #expect(failure.cleanup == nil)
            #expect(failure.localizedDescription.contains("Save Report Copy"))
        }
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
    #expect(!manager.fileExists(atPath: blocked.path))
    #expect(!manager.fileExists(atPath: root.appendingPathComponent("missing").path))
    let retry = root.appendingPathComponent("retried.json")
    _ = try saveBatchDownloadReport(report, to: retry)
    let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: retry))
    #expect(try encodedReportRecovery(saved) == encodedReportRecovery(report))
}

@Test @MainActor func retainedReportCopyFailureThenSuccessPreservesTransfersAndJob() async throws {
    let root = try reportRecoveryDirectory()
    defer { removeReportRecoveryDirectory(root) }
    let report = reportRecoveryOutcomes(root)
    let file = root.appendingPathComponent("saved.txt")
    let occupied = root.appendingPathComponent("download-report.json")
    let downloaded = Data("already downloaded bytes".utf8)
    let earlier = Data("earlier report content".utf8)
    try downloaded.write(to: file, options: .withoutOverwriting)
    try earlier.write(to: occupied, options: .withoutOverwriting)
    let failure: BatchDownloadReportSaveError
    do {
        _ = try saveBatchDownloadReport(report, to: occupied)
        throw MonitorError.invalid("The occupied automatic report must fail before recovery.")
    } catch let error as BatchDownloadReportSaveError { failure = error }
    let jobID = UUID()
    let progress = BatchProgress(current: "Remaining.txt", discovered: 4, completed: 2, failed: 2)
    let original = BatchDownloadPresentation(id: jobID, status: "Downloading…", progress: progress, report: nil, reportSaveError: nil, finished: false)
    let model = AppModel(previewStore: PreviewStore(root: root.appendingPathComponent("previews", isDirectory: true)))
    model.batchDownload = original.reportingFailure(failure)
    do {
        try await model.writeBatchReportCopy(jobID: jobID, destination: occupied)
        Issue.record("Saving over the earlier report must retain the report and fail.")
    } catch let copyFailure as BatchDownloadReportSaveError {
        #expect(copyFailure.destination == occupied)
        #expect((copyFailure.cause as NSError).code == NSFileWriteFileExistsError)
    }
    let retained = try #require(model.batchDownload)
    #expect(retained.id == jobID); #expect(retained.finished)
    #expect(retained.reportSaveError == failure.localizedDescription)
    #expect(retained.recoveryError != nil); #expect(retained.reportURL == nil)
    #expect(try encodedReportRecovery(try #require(retained.report)) == encodedReportRecovery(report))
    let destination = root.appendingPathComponent("report-copy.json")
    try await model.writeBatchReportCopy(jobID: jobID, destination: destination)
    let recovered = try #require(model.batchDownload)
    #expect(recovered.id == jobID); #expect(recovered.finished)
    #expect(recovered.reportURL == destination)
    #expect(recovered.reportSaveError == nil); #expect(recovered.recoveryError == nil)
    #expect(recovered.progress.current == progress.current)
    #expect(recovered.progress.discovered == progress.discovered)
    #expect(recovered.progress.completed == progress.completed)
    #expect(recovered.progress.failed == progress.failed)
    #expect(try encodedReportRecovery(try #require(recovered.report)) == encodedReportRecovery(report))
    #expect(try encodedReportRecovery(JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: destination))) == encodedReportRecovery(report))
    #expect(try Data(contentsOf: file) == downloaded)
    #expect(try Data(contentsOf: occupied) == earlier)
    #expect(model.operationNotice?.contains(destination.path) == true)
    #expect(model.client == nil); #expect(!model.connected); #expect(!model.hasClient)
}

@Test @MainActor func alreadyCancelledReportCopyLeavesRetainedResultsAndDiskUnchanged() async throws {
    let root = try reportRecoveryDirectory()
    defer { removeReportRecoveryDirectory(root) }
    let report = reportRecoveryOutcomes(root)
    let model = AppModel(previewStore: PreviewStore(root: root.appendingPathComponent("previews", isDirectory: true)))
    let jobID = UUID()
    model.batchDownload = BatchDownloadPresentation(id: jobID, status: report.summary, progress: BatchProgress(current: "Remaining.txt", discovered: 4, completed: 2, failed: 2), report: report, reportSaveError: "Automatic report save failed", finished: true)
    let destination = root.appendingPathComponent("cancelled-copy.json")
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await model.writeBatchReportCopy(jobID: jobID, destination: destination)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    let retained = try #require(model.batchDownload)
    #expect(retained.id == jobID)
    #expect(retained.reportSaveError == "Automatic report save failed")
    #expect(retained.reportURL == nil); #expect(retained.recoveryError == nil)
    #expect(try encodedReportRecovery(try #require(retained.report)) == encodedReportRecovery(report))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(model.operationNotice == nil)
}

@Test @MainActor func staleAndUnfinishedReportCopiesRejectBeforeWriting() async throws {
    let root = try reportRecoveryDirectory()
    defer { removeReportRecoveryDirectory(root) }
    let report = reportRecoveryOutcomes(root)
    let model = AppModel(previewStore: PreviewStore(root: root.appendingPathComponent("previews", isDirectory: true)))
    let currentID = UUID()
    model.batchDownload = BatchDownloadPresentation(id: currentID, status: report.summary, progress: BatchProgress(current: "Remaining.txt", discovered: 4, completed: 2, failed: 2), report: report, reportSaveError: nil, finished: true)
    let staleDestination = root.appendingPathComponent("stale.json")
    await #expect(throws: MonitorError.self) { try await model.writeBatchReportCopy(jobID: UUID(), destination: staleDestination) }
    model.batchDownload?.finished = false
    let unfinishedDestination = root.appendingPathComponent("unfinished.json")
    await #expect(throws: MonitorError.self) { try await model.writeBatchReportCopy(jobID: currentID, destination: unfinishedDestination) }
    #expect(!FileManager.default.fileExists(atPath: staleDestination.path))
    #expect(!FileManager.default.fileExists(atPath: unfinishedDestination.path))
    let retained = try #require(model.batchDownload)
    #expect(retained.id == currentID)
    #expect(retained.reportURL == nil); #expect(retained.recoveryError == nil)
    #expect(try encodedReportRecovery(try #require(retained.report)) == encodedReportRecovery(report))
}

@Test func automaticReportPersistenceStillFinishesInsideCancelledTransferTask() async throws {
    let root = try reportRecoveryDirectory()
    defer { removeReportRecoveryDirectory(root) }
    let report = reportRecoveryOutcomes(root)
    let destination = root.appendingPathComponent("download-report.json")
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(Task.isCancelled)
        return try saveBatchDownloadReport(report, to: destination)
    }
    #expect(try await task.value == destination)
    let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: destination))
    #expect(try encodedReportRecovery(saved) == encodedReportRecovery(report))
    #expect(saved.cancelled); #expect(saved.completed == 1); #expect(saved.remaining == 2)
    #expect(try reportRecoveryMode(destination) == 0o600)
}

private func reportRecoveryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DriveTrace Report Recovery " + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

private func removeReportRecoveryDirectory(_ root: URL) {
    do { try FileManager.default.removeItem(at: root) }
    catch { Issue.record(error) }
}

private func reportRecoveryOutcomes(_ root: URL) -> BatchDownloadReport {
    BatchDownloadReport(directory: root, planned: 4,
                        results: [DownloadResult(id: UUID(), path: "saved.txt", outcome: .downloaded, message: nil), DownloadResult(id: UUID(), path: "denied.txt", outcome: .failed, message: "Access denied")],
                        issues: [DownloadIssue(path: "Shortcut", reason: "Shortcut skipped")], unattempted: ["Remaining.txt", "Undiscovered descendants remain unknown"], cancelled: true)
}

private func encodedReportRecovery(_ report: BatchDownloadReport) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(report)
}

private func reportRecoveryMode(_ url: URL) throws -> mode_t {
    var attributes = stat()
    guard lstat(url.path, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return attributes.st_mode & 0o777
}
