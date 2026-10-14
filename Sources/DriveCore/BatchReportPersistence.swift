import Foundation
import Darwin

/// Final outcomes must survive transfer cancellation. Create a new 0600 report, never replace an existing item.
/// This boundary deliberately finishes persistence even if the transfer task was cancelled.
public func saveBatchDownloadReport(_ report: BatchDownloadReport, to destination: URL) throws -> URL {
    let data: Data
    do {
        guard destination.isFileURL else { throw MonitorError.invalid("Choose a local JSON file for the download report.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(report)
    } catch { throw BatchDownloadReportSaveError(report: report, destination: destination, cause: error, cleanup: nil) }
    let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else {
        let code = errno
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        // Preserve Foundation's existing-file error contract and the original kernel cause.
        let cause: any Error = code == EEXIST ? CocoaError(.fileWriteFileExists, userInfo: [NSUnderlyingErrorKey: posix]) : posix
        throw BatchDownloadReportSaveError(report: report, destination: destination, cause: cause, cleanup: nil)
    }
    let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        do {
            guard fchmod(descriptor, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard attributes.st_mode & 0o777 == 0o600 else { throw MonitorError.invalid("This destination did not preserve private report permissions. Choose a local volume supporting 0600 permissions.") }
            try writer.write(contentsOf: data)
        }
        catch {
            let cause = error
            do { try writer.close() }
            catch { throw ReportWriteCloseError(cause: cause, closing: error) }
            throw cause
        }
        try writer.close()
    } catch {
        let cause = error
        do { try FileManager.default.removeItem(at: destination) }
        catch { throw BatchDownloadReportSaveError(report: report, destination: destination, cause: cause, cleanup: error) }
        throw BatchDownloadReportSaveError(report: report, destination: destination, cause: cause, cleanup: nil)
    }
    return destination
}

private struct ReportWriteCloseError: LocalizedError {
    let cause: any Error
    let closing: any Error
    var errorDescription: String? { "Writing the report failed: \(cause.localizedDescription). Closing its output file also failed: \(closing.localizedDescription)." }
}
