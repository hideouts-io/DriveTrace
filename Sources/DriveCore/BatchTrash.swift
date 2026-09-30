import Foundation

public struct TrashItemResult: Sendable, Identifiable {
    public let file: DriveFile
    public let updated: DriveFile?
    public let failure: String?
    public var id: String { file.id }
}

public struct BatchTrashReport: Sendable {
    public let requested: Int
    public let results: [TrashItemResult]
    public let cancelled: Bool
    public var completed: Int { results.filter { $0.updated != nil }.count }
    public var failed: Int { results.filter { $0.failure != nil }.count }
    public var remaining: Int { requested - results.count }
    public var summary: String {
        "\(cancelled ? "Stopped" : failed > 0 ? "Finished with gaps" : "Finished") · \(completed) moved to Trash · \(failed) unconfirmed · \(remaining) not attempted"
    }
}

extension GoogleClient {
    /// Only the reviewed IDs are attempted. Each mutation rechecks the current target.
    /// Cancellation cannot undo requests Google has already received.
    public func trashBatch(confirmed: [DriveFile], progress: @Sendable (TrashItemResult) async -> Void) async -> BatchTrashReport {
        var results: [TrashItemResult] = []
        var cancelled = false
        for file in confirmed {
            if Task.isCancelled { cancelled = true; break }
            let result: TrashItemResult
            do {
                let updated = try await moveToTrash(confirmed: file)
                result = TrashItemResult(file: file, updated: updated, failure: nil)
            } catch {
                result = TrashItemResult(file: file, updated: nil, failure: "\(error.localizedDescription) Refresh and check this item before retrying: an interrupted request may already have reached Google.")
                cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            }
            results.append(result)
            await progress(result)
            if cancelled { break }
        }
        return BatchTrashReport(requested: confirmed.count, results: results, cancelled: cancelled)
    }
}
