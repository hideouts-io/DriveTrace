import Foundation
import Darwin
import Testing
@testable import DriveCore

@Test func reportCloseFaultPreservesConcurrentFinalRegularReplacement() throws {
    let root = try reportPathDirectory()
    defer { removeReportPathDirectory(root) }
    let report = reportPathOutcomes(root)
    let earlier = try reportPathEarlierFile(root)
    let destination = root.appendingPathComponent("report.json")
    let backup = root.appendingPathComponent("original-open-report.json")
    let replacement = Data("Another operation's exact final report contents".utf8)
    var opened: URL?
    var closes = 0
    let failure = try capturedReportPathFailure(report, to: destination) { handle, file in
        closes += 1
        try assertOpenedReportPath(handle, file: file, report: report)
        opened = file
        try relocateOpenedFinalReport(file, destination: destination, backup: backup)
        try writeReportPathFixture(replacement, to: destination)
        try closeFixtureWithPOSIXFailure(handle)
    }
    #expect(closes == 1)
    try assertReportPathFailureRetainsOutcomes(failure, report: report, destination: destination)
    try assertReportPathCloseCause(failure.cause)
    #expect(failure.cleanup == nil)
    #expect(try Data(contentsOf: destination) == replacement)
    #expect(try Data(contentsOf: earlier) == reportPathEarlierBytes)
    let openedFile = try #require(opened)
    if openedFile != destination { #expect(!FileManager.default.fileExists(atPath: openedFile.path)) }
}

@Test func reportCloseFaultPreservesConcurrentFinalSymlinkAndTarget() throws {
    let manager = FileManager.default
    let root = try reportPathDirectory()
    defer { removeReportPathDirectory(root) }
    let report = reportPathOutcomes(root)
    let earlier = try reportPathEarlierFile(root)
    let target = root.appendingPathComponent("symlink-target.bin")
    let targetBytes = Data("The replacement symlink's existing target must remain untouched".utf8)
    try writeReportPathFixture(targetBytes, to: target)
    let destination = root.appendingPathComponent("report.json")
    let backup = root.appendingPathComponent("original-open-report.json")
    var opened: URL?
    var closes = 0
    let failure = try capturedReportPathFailure(report, to: destination) { handle, file in
        closes += 1
        try assertOpenedReportPath(handle, file: file, report: report)
        opened = file
        try relocateOpenedFinalReport(file, destination: destination, backup: backup)
        try manager.createSymbolicLink(at: destination, withDestinationURL: target)
        try closeFixtureWithPOSIXFailure(handle)
    }
    #expect(closes == 1)
    try assertReportPathFailureRetainsOutcomes(failure, report: report, destination: destination)
    try assertReportPathCloseCause(failure.cause)
    #expect(failure.cleanup == nil)
    #expect(try reportPathAttributes(destination).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK))
    #expect(try manager.destinationOfSymbolicLink(atPath: destination.path) == target.path)
    #expect(try Data(contentsOf: target) == targetBytes)
    #expect(try Data(contentsOf: earlier) == reportPathEarlierBytes)
    let openedFile = try #require(opened)
    if openedFile != destination { #expect(!manager.fileExists(atPath: openedFile.path)) }
}

@Test func lateOccupiedReportDestinationRefusesExclusivePublicationAndRetainsOutcomes() throws {
    let root = try reportPathDirectory()
    defer { removeReportPathDirectory(root) }
    let report = reportPathOutcomes(root)
    let earlier = try reportPathEarlierFile(root)
    let destination = root.appendingPathComponent("report.json")
    let backup = root.appendingPathComponent("original-open-report.json")
    let replacement = Data("Late occupied final path is never overwritten".utf8)
    var opened: URL?
    var closes = 0
    let failure = try capturedReportPathFailure(report, to: destination) { handle, file in
        closes += 1
        try assertOpenedReportPath(handle, file: file, report: report)
        opened = file
        try relocateOpenedFinalReport(file, destination: destination, backup: backup)
        try writeReportPathFixture(replacement, to: destination)
        try handle.close()
    }
    #expect(closes == 1)
    try assertReportPathFailureRetainsOutcomes(failure, report: report, destination: destination)
    let cause = failure.cause as NSError
    #expect(cause.domain == NSCocoaErrorDomain && cause.code == NSFileWriteFileExistsError)
    let underlying = try #require(cause.userInfo[NSUnderlyingErrorKey] as? NSError)
    #expect(underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EEXIST))
    #expect(failure.cleanup == nil)
    #expect(try Data(contentsOf: destination) == replacement)
    #expect(try Data(contentsOf: earlier) == reportPathEarlierBytes)
    let openedFile = try #require(opened)
    #expect(openedFile != destination)
    #expect(!FileManager.default.fileExists(atPath: openedFile.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [destination.lastPathComponent, earlier.lastPathComponent].sorted())
}

@Test func reportStagingIdentityChangeRefusesReplacementCleanup() throws {
    let root = try reportPathDirectory()
    defer { removeReportPathDirectory(root) }
    let report = reportPathOutcomes(root)
    let earlier = try reportPathEarlierFile(root)
    let destination = root.appendingPathComponent("report.json")
    let backup = root.appendingPathComponent("moved-original-report.json")
    let replacement = Data("Replacement at the former staging name is not owned by the writer".utf8)
    var opened: URL?
    var originalIdentity: ReportPathIdentity?
    var closes = 0
    let failure = try capturedReportPathFailure(report, to: destination) { handle, file in
        closes += 1
        try assertOpenedReportPath(handle, file: file, report: report)
        opened = file
        let attributes = try reportPathAttributes(file)
        originalIdentity = ReportPathIdentity(device: attributes.st_dev, inode: attributes.st_ino, owner: attributes.st_uid)
        try FileManager.default.moveItem(at: file, to: backup)
        try writeReportPathFixture(replacement, to: file)
        try handle.close()
    }
    #expect(closes == 1)
    try assertReportPathFailureRetainsOutcomes(failure, report: report, destination: destination)
    #expect(failure.cause.localizedDescription.contains("no longer names its owned file"))
    let cleanup = try #require(failure.cleanup as? ReportStagingCleanupError)
    let openedFile = try #require(opened)
    #expect(cleanup.file == openedFile)
    #expect(cleanup.localizedDescription.contains(openedFile.path))
    #expect(try Data(contentsOf: openedFile) == replacement)
    let expectedIdentity = try #require(originalIdentity)
    #expect(!expectedIdentity.matches(try reportPathAttributes(openedFile)))
    #expect(expectedIdentity.matches(try reportPathAttributes(backup)))
    let retained = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: backup))
    #expect(try encodedReportPathOutcomes(retained) == encodedReportPathOutcomes(report))
    #expect(try Data(contentsOf: earlier) == reportPathEarlierBytes)
    if openedFile != destination { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
    let retry = root.appendingPathComponent("retry.json")
    _ = try saveBatchDownloadReport(failure.report, to: retry)
    try assertPublishedReportPath(retry, report: report)
    #expect(try Data(contentsOf: openedFile) == replacement)
}

@Test func reportStagingCleanupDenialRetainsPrimaryCloseAndSecondaryPathAndAllowsRetry() throws {
    let manager = FileManager.default
    let root = try reportPathDirectory()
    defer {
        do { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        catch { Issue.record(error) }
        removeReportPathDirectory(root)
    }
    let report = reportPathOutcomes(root)
    let earlier = try reportPathEarlierFile(root)
    let destination = root.appendingPathComponent("report.json")
    var opened: URL?
    var closes = 0
    let failure = try capturedReportPathFailure(report, to: destination) { handle, file in
        closes += 1
        try assertOpenedReportPath(handle, file: file, report: report)
        opened = file
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        try closeFixtureWithPOSIXFailure(handle)
    }
    #expect(closes == 1)
    try assertReportPathFailureRetainsOutcomes(failure, report: report, destination: destination)
    try assertReportPathCloseCause(failure.cause)
    let openedFile = try #require(opened)
    let cleanup = try #require(failure.cleanup as? ReportStagingCleanupError)
    #expect(cleanup.file == openedFile)
    let kernel = cleanup.cause as NSError
    #expect(kernel.domain == NSPOSIXErrorDomain && kernel.code == Int(EACCES))
    #expect(cleanup.localizedDescription.contains(openedFile.path))
    #expect(failure.localizedDescription.contains(openedFile.path))
    #expect(openedFile != destination)
    #expect(!manager.fileExists(atPath: destination.path))
    try assertPublishedReportPath(openedFile, report: report)
    #expect(try Data(contentsOf: earlier) == reportPathEarlierBytes)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    let retry = root.appendingPathComponent("retry.json")
    _ = try saveBatchDownloadReport(failure.report, to: retry)
    try assertPublishedReportPath(retry, report: report)
    #expect(try Data(contentsOf: earlier) == reportPathEarlierBytes)
    try manager.removeItem(at: openedFile)
    #expect(!manager.fileExists(atPath: openedFile.path))
    #expect(try manager.contentsOfDirectory(atPath: root.path).sorted() == [earlier.lastPathComponent, retry.lastPathComponent].sorted())
}

@Test func successfulReportClosePublishesOnlyCompletePrivateJSONWithoutStagingLeftovers() throws {
    let root = try reportPathDirectory()
    defer { removeReportPathDirectory(root) }
    let report = reportPathOutcomes(root)
    let earlier = try reportPathEarlierFile(root)
    let destination = root.appendingPathComponent("report.json")
    var opened: URL?
    var closes = 0
    let saved = try saveBatchDownloadReport(report, to: destination) { handle, file in
        closes += 1
        try assertOpenedReportPath(handle, file: file, report: report)
        opened = file
        #expect(file != destination)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try handle.close()
    }
    #expect(closes == 1 && saved == destination)
    try assertPublishedReportPath(destination, report: report)
    #expect(try Data(contentsOf: earlier) == reportPathEarlierBytes)
    let openedFile = try #require(opened)
    #expect(!FileManager.default.fileExists(atPath: openedFile.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [earlier.lastPathComponent, destination.lastPathComponent].sorted())
}

private let reportPathEarlierBytes = Data("Earlier saved download bytes must survive report persistence failures".utf8)

private struct ReportPathIdentity {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    func matches(_ attributes: stat) -> Bool { attributes.st_dev == device && attributes.st_ino == inode && attributes.st_uid == owner }
}

/// These tests control the exact pathname interleaving and POSIX closing boundary;
/// they do not establish a naturally failing Foundation close or arbitrary hostile parent-directory races.
private func capturedReportPathFailure(_ report: BatchDownloadReport, to destination: URL, closing: (FileHandle, URL) throws -> Void) throws -> BatchDownloadReportSaveError {
    do {
        _ = try saveBatchDownloadReport(report, to: destination, closing: closing)
        throw MonitorError.invalid("The controlled report persistence failure unexpectedly returned success.")
    } catch let failure as BatchDownloadReportSaveError { return failure }
}

private func assertOpenedReportPath(_ handle: FileHandle, file: URL, report: BatchDownloadReport) throws {
    guard file.isFileURL, file.deletingLastPathComponent().standardizedFileURL.path == report.directory.standardizedFileURL.path else {
        throw MonitorError.invalid("Report replacement tests may modify only the exact opened file inside their task-owned root.")
    }
    var descriptor = stat()
    guard fstat(handle.fileDescriptor, &descriptor) == 0 else { throw reportPathPOSIXFailure("Inspect exact opened report descriptor", code: errno) }
    let path = try reportPathAttributes(file)
    guard descriptor.st_dev == path.st_dev, descriptor.st_ino == path.st_ino, descriptor.st_uid == geteuid(), path.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw MonitorError.invalid("The opened report pathname must identify the exact task-owned regular inode before controlled replacement.")
    }
    #expect(path.st_mode & 0o777 == 0o600)
    let encoded = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: file))
    #expect(try encodedReportPathOutcomes(encoded) == encodedReportPathOutcomes(report))
}

/// Baseline direct creation exposes the final name; relocating that exact owned inode
/// supplies the same replacement interleaving before and after staged publication is introduced.
private func relocateOpenedFinalReport(_ opened: URL, destination: URL, backup: URL) throws {
    if opened == destination { try FileManager.default.moveItem(at: opened, to: backup) }
}

private func assertReportPathFailureRetainsOutcomes(_ failure: BatchDownloadReportSaveError, report: BatchDownloadReport, destination: URL) throws {
    #expect(failure.destination == destination)
    #expect(try encodedReportPathOutcomes(failure.report) == encodedReportPathOutcomes(report))
    #expect(failure.report.cancelled)
    #expect(failure.report.completed == report.completed)
    #expect(failure.report.failures == report.failures)
    #expect(failure.report.remaining == report.remaining)
}

private func assertReportPathCloseCause(_ error: any Error) throws {
    let cause = error as NSError
    #expect(cause.domain == NSPOSIXErrorDomain && cause.code == Int(EBADF))
}

private func assertPublishedReportPath(_ file: URL, report: BatchDownloadReport) throws {
    let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: file))
    #expect(try encodedReportPathOutcomes(saved) == encodedReportPathOutcomes(report))
    #expect(try reportPathAttributes(file).st_mode & 0o777 == 0o600)
}

private func encodedReportPathOutcomes(_ report: BatchDownloadReport) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(report)
}

private func reportPathOutcomes(_ root: URL) -> BatchDownloadReport {
    BatchDownloadReport(directory: root, planned: 5,
                        results: [DownloadResult(id: UUID(), path: "saved.bin", outcome: .downloaded, message: nil), DownloadResult(id: UUID(), path: "Denied.bin", outcome: .failed, message: "Access denied"), DownloadResult(id: UUID(), path: "Empty", outcome: .folderCreated, message: nil)],
                        issues: [DownloadIssue(path: "Shortcut", reason: "Shortcut skipped")],
                        unattempted: ["Remaining.bin", "Unknown descendants remain uncounted"], cancelled: true)
}

private func reportPathEarlierFile(_ root: URL) throws -> URL {
    let file = root.appendingPathComponent("saved.bin")
    try writeReportPathFixture(reportPathEarlierBytes, to: file)
    return file
}

private func writeReportPathFixture(_ data: Data, to file: URL) throws {
    try data.write(to: file, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}

private func reportPathDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DriveTrace Report Path " + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
}

private func removeReportPathDirectory(_ root: URL) {
    do { try FileManager.default.removeItem(at: root) }
    catch { Issue.record(error) }
}

private func reportPathAttributes(_ file: URL) throws -> stat {
    var attributes = stat()
    guard lstat(file.path, &attributes) == 0 else { throw reportPathPOSIXFailure("Inspect exact report pathname fixture", code: errno) }
    return attributes
}

private func reportPathPOSIXFailure(_ operation: String, code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))."])
}
