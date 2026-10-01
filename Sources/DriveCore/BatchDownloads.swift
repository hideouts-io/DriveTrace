import Foundation
import Darwin

public enum DownloadOutcome: String, Codable, Sendable { case downloaded, folderCreated, failed }
public struct DownloadResult: Codable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let outcome: DownloadOutcome
    public let message: String?
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
    public var summary: String {
        "\(cancelled ? "Cancelled" : failures > 0 ? "Finished with gaps" : "Finished") · \(completed) files saved · \(failures) failed/skipped · \(remaining) not attempted"
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
                else { try await downloadNewFile(file: item.file, to: destination) }
                results.append(DownloadResult(id: UUID(), path: path, outcome: item.file.isFolder ? .folderCreated : .downloaded, message: nil))
            } catch is CancellationError { cancelled = true; break }
            catch let error as URLError where error.code == .cancelled { cancelled = true; break }
            catch { failures += 1; results.append(DownloadResult(id: UUID(), path: path, outcome: .failed, message: error.localizedDescription)) }
        }
        let unattempted = plan.items.dropFirst(results.count).map { $0.components.joined(separator: "/") }
        let report = BatchDownloadReport(directory: directory, planned: plan.items.count, results: results, issues: plan.issues, unattempted: unattempted, cancelled: cancelled)
        let reportURL = directory.appendingPathComponent("download-report.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: reportURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        } catch { throw MonitorError.invalid("\(report.summary). Files remain in \(directory.path), but saving the download report failed: \(error.localizedDescription)") }
        return report
    }
}

private func createDownloadDirectory(_ url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else { throw MonitorError.invalid("Could not create download folder at \(url.path): \(String(cString: strerror(errno))). Existing folders are never merged or replaced.") }
}
