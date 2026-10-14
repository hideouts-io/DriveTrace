import Foundation
import Darwin

public enum DownloadOutcome: String, Codable, Sendable { case downloaded, folderCreated, failed }
public struct DownloadResult: Codable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let outcome: DownloadOutcome
    public let message: String?
    static func savedWithCleanupFailure(_ failure: SavedDownloadCleanupError, path: String, id: UUID) -> DownloadResult {
        DownloadResult(id: id, path: path, outcome: .downloaded, message: failure.localizedDescription)
    }
}
public struct BatchDownloadReport: Codable, Sendable {
    public let directory: URL
    public let planned: Int
    public let results: [DownloadResult]
    public let issues: [DownloadIssue]
    public let unattempted: [String]
    public let cancelled: Bool
    public var completed: Int { results.filter { $0.outcome == .downloaded }.count }
    public var failures: Int { results.filter { $0.outcome == .failed }.count + issues.count }
    public var remaining: Int { unattempted.count }
    public var cleanupWarnings: Int { results.filter { $0.outcome == .downloaded && $0.message != nil }.count }
    public var summary: String {
        "\(cancelled ? "Cancelled" : failures > 0 ? "Finished with gaps" : "Finished") · \(completed) files saved · \(failures) failed/skipped · \(remaining) not attempted" + (cleanupWarnings == 0 ? "" : " · \(cleanupWarnings) cleanup warnings")
    }
}

/// Transfers have ended, but report persistence failed. Keep the outcomes available to the caller.
public struct BatchDownloadReportSaveError: LocalizedError {
    public let report: BatchDownloadReport
    public let destination: URL
    public let cause: any Error
    public let cleanup: (any Error)?
    public var errorDescription: String? {
        "Download output remains in \(report.directory.path), but saving \(destination.lastPathComponent) failed at \(destination.path): \(cause.localizedDescription). "
            + (cleanup.map { "Removing the incomplete report also failed: \($0.localizedDescription). Review that location before removing leftover data. " } ?? "")
            + "Results are retained in this window. Choose Save Report Copy to select a new writable JSON location; existing files are never overwritten."
    }
}

extension GoogleClient {
    /// Every job owns a new private directory. Completed files survive cancellation and partial failure.
    public func downloadBatch(plan: DownloadPlan, parent: URL, progress: @Sendable (BatchProgress) async -> Void) async throws -> BatchDownloadReport {
        try Task.checkCancellation()
        try validateBatchDestination(parent)
        let directory = parent.appendingPathComponent("DriveTrace Download " + UUID().uuidString, isDirectory: true)
        try createDownloadDirectory(directory)
        let content = directory.appendingPathComponent("Files", isDirectory: true)
        try createDownloadDirectory(content)
        let safeContent = content.resolvingSymlinksInPath()
        var results: [DownloadResult] = []
        var cancelled = false
        var failures = plan.issues.count
        for item in plan.items {
            let path = item.components.joined(separator: "/")
            do {
                try Task.checkCancellation()
                let destination = item.components.reduce(content) { $0.appendingPathComponent($1) }
                guard destination.resolvingSymlinksInPath().path.hasPrefix(safeContent.path + "/") else { throw MonitorError.invalid("The destination path escaped the batch folder. Check for symbolic links or moved folders.") }
                await progress(BatchProgress(current: path, discovered: plan.items.count, completed: results.count, failed: failures))
                try Task.checkCancellation()
                if item.file.isFolder { try createDownloadDirectory(destination) }
                else {
                    try validateBatchDestination(destination.deletingLastPathComponent())
                    try await downloadNewFile(file: item.file, to: destination)
                }
                results.append(DownloadResult(id: UUID(), path: path, outcome: item.file.isFolder ? .folderCreated : .downloaded, message: nil))
            } catch is CancellationError { cancelled = true; break }
            catch let error as URLError where error.code == .cancelled { cancelled = true; break }
            catch let failure as FailedDownloadCleanupError where failure.cancelled {
                cancelled = true
                results.append(DownloadResult(id: UUID(), path: path, outcome: .failed, message: failure.localizedDescription))
                break
            }
            catch let failure as SavedDownloadCleanupError { results.append(.savedWithCleanupFailure(failure, path: path, id: UUID())) }
            catch { failures += 1; results.append(DownloadResult(id: UUID(), path: path, outcome: .failed, message: error.localizedDescription)) }
        }
        let unattempted = plan.items.dropFirst(results.count).map { $0.components.joined(separator: "/") }
        let report = BatchDownloadReport(directory: directory, planned: plan.items.count, results: results, issues: plan.issues, unattempted: unattempted, cancelled: cancelled)
        let reportURL = directory.appendingPathComponent("download-report.json")
        _ = try saveBatchDownloadReport(report, to: reportURL)
        return report
    }
}

private func createDownloadDirectory(_ url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else {
        let code = errno
        throw MonitorError.invalid("Could not create download folder at \(url.path): \(String(cString: strerror(code))) (errno \(code)). Choose a writable destination with available space, then retry. Existing folders are never merged or replaced.")
    }
}
