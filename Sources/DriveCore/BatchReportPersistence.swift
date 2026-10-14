import Foundation
import Darwin

/// Final outcomes must survive transfer cancellation. Publish only a closed 0600 report, never replace an existing item.
/// Failure cleanup targets its unique sibling staging file, never the requested final pathname.
/// This boundary deliberately finishes persistence even if the transfer task was cancelled.
public func saveBatchDownloadReport(_ report: BatchDownloadReport, to destination: URL) throws -> URL {
    try saveBatchDownloadReport(report, to: destination, closing: { handle, _ in try handle.close() })
}

/// Keep the closing system boundary explicit for controlled filesystem failure validation.
func saveBatchDownloadReport(_ report: BatchDownloadReport, to destination: URL, closing: (FileHandle, URL) throws -> Void) throws -> URL {
    let staging = destination.deletingLastPathComponent().appendingPathComponent(".DriveTrace-report-" + UUID().uuidString + ".tmp")
    let data: Data
    do {
        guard destination.isFileURL else { throw MonitorError.invalid("Choose a local JSON file for the download report.") }
        guard staging.lastPathComponent != destination.lastPathComponent else { throw MonitorError.invalid("A distinct report staging filename could not be chosen. Retry saving the retained report; no file was created.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(report)
    } catch { throw BatchDownloadReportSaveError(report: report, destination: destination, cause: error, cleanup: nil) }
    let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
        let code = errno
        let cause = NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Could not create private report staging at \(staging.path): \(String(cString: strerror(code))) (errno \(code)). Choose an existing writable folder with available space."])
        throw BatchDownloadReportSaveError(report: report, destination: destination, cause: cause, cleanup: nil)
    }
    let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var identity: ReportStagingIdentity?
    do {
        do {
            identity = try reportStagingIdentity(descriptor)
            guard fchmod(descriptor, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard attributes.st_mode & 0o777 == 0o600 else { throw MonitorError.invalid("This destination did not preserve private report permissions. Choose a local volume supporting 0600 permissions.") }
            try writer.write(contentsOf: data)
        }
        catch {
            let cause = error
            do { try closing(writer, staging) }
            catch { throw ReportWriteCloseError(cause: cause, closing: error) }
            throw cause
        }
        try closing(writer, staging)
        try requireReportStagingIdentity(identity, at: staging)
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Could not publish the closed report at \(destination.path) using exclusive rename: \(String(cString: strerror(code))) (errno \(code)). Choose a writable volume supporting exclusive rename; existing items were not replaced."])
            // Preserve Foundation's existing-file error contract and the original kernel cause.
            let cause: any Error = code == EEXIST ? CocoaError(.fileWriteFileExists, userInfo: [NSUnderlyingErrorKey: posix]) : posix
            throw cause
        }
    } catch {
        let cause = error
        do {
            try requireReportStagingIdentity(identity, at: staging)
            guard unlink(staging.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        catch {
            let cleanup = ReportStagingCleanupError(file: staging, cause: error)
            throw BatchDownloadReportSaveError(report: report, destination: destination, cause: cause, cleanup: cleanup)
        }
        throw BatchDownloadReportSaveError(report: report, destination: destination, cause: cause, cleanup: nil)
    }
    return destination
}

private struct ReportStagingIdentity {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
}

private func reportStagingIdentity(_ descriptor: Int32) throws -> ReportStagingIdentity {
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == geteuid() else { throw MonitorError.invalid("The new report staging file is not a regular file owned by this account. Choose a local volume supporting private files.") }
    return ReportStagingIdentity(device: attributes.st_dev, inode: attributes.st_ino, owner: attributes.st_uid)
}

/// Refuse known replacement or missing paths. The check followed by rename/unlink is not atomic against same-user interference.
private func requireReportStagingIdentity(_ identity: ReportStagingIdentity?, at file: URL) throws {
    guard let identity else { throw MonitorError.invalid("The report staging file's ownership could not be recorded. Review the temporary file at \(file.path); no cleanup was attempted.") }
    var attributes = stat()
    guard lstat(file.path, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_dev == identity.device,
          attributes.st_ino == identity.inode, attributes.st_uid == identity.owner else {
        throw MonitorError.invalid("The report staging pathname no longer names its owned file at \(file.path). Publication and removal were refused. Review this location before retrying.")
    }
}

struct ReportStagingCleanupError: LocalizedError {
    let file: URL
    let cause: any Error
    var errorDescription: String? { "Report staging at \(file.path): \(cause.localizedDescription). Review this temporary location; the requested final report pathname was not removed." }
}

private struct ReportWriteCloseError: LocalizedError {
    let cause: any Error
    let closing: any Error
    var errorDescription: String? { "Writing the report failed: \(cause.localizedDescription). Closing its output file also failed: \(closing.localizedDescription)." }
}
