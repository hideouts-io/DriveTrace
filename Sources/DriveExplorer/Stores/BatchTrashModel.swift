import Foundation
import DriveCore

struct BatchTrashPresentation: Identifiable {
    let id: UUID
    let files: [DriveFile]
    var results: [TrashItemResult]
    var report: BatchTrashReport?
    var indexFailures: [String]
}

extension AppModel {
    func prepareTrashSelection(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        run {
            let client = try await self.fileActionClient()
            var files: [DriveFile] = []
            for id in ids.sorted() {
                try Task.checkCancellation()
                self.progress = "Checking Trash permissions · \(files.count + 1) of \(ids.count)…"
                let file = try await client.file(id: id)
                guard file.trashed != true, file.capabilities?.canTrash == true else {
                    throw MonitorError.invalid("Cannot move \(file.name) (\(id)) to Trash: it is already trashed or Google has not granted permission. Remove it from the selection and review again. Nothing was changed.")
                }
                files.append(file)
            }
            self.pendingBatchTrash = BatchTrashPresentation(id: UUID(), files: files, results: [], report: nil, indexFailures: [])
        }
    }

    func confirmTrashSelection(_ review: BatchTrashPresentation) {
        guard review.report == nil else { return }
        run {
            let client = try await self.fileActionClient()
            guard let database = self.database else { throw MonitorError.database("The account database is unavailable. Refresh before moving items to Trash.") }
            self.syncVerified = false
            self.progress = "Moving reviewed items to Google Drive Trash…"
            let report = await client.trashBatch(confirmed: review.files) { result in
                await MainActor.run {
                    self.pendingBatchTrash?.results.append(result)
                    self.progress = "Move to Trash · \(self.pendingBatchTrash?.results.count ?? 0) of \(review.files.count) processed"
                }
                if let updated = result.updated {
                    do { try await database.recordFileActionResult(updated, detected: timestamp(Date())) }
                    catch {
                        let message = "Google confirmed \(result.file.name) was trashed, but its local index update failed: \(error.localizedDescription). Refresh to reconcile; do not repeat the action."
                        await MainActor.run { self.pendingBatchTrash?.indexFailures.append(message) }
                    }
                }
            }
            self.pendingBatchTrash?.report = report
            self.operationNotice = report.summary
            let updated = Dictionary(uniqueKeysWithValues: report.results.compactMap { result in result.updated.map { ($0.id, $0) } })
            self.serverResults = self.serverResults?.map { updated[$0.id] ?? $0 }
            self.selectedFiles = []
            if report.cancelled {
                self.error = "The batch stopped. Review the per-item results and any local index errors. Refresh to reconcile the displayed index and unconfirmed requests before trying again."
                return
            }
            do { try await self.reload() }
            catch { throw MonitorError.database("The Trash results are retained in this sheet, but refreshing the local index failed: \(error.localizedDescription). Refresh before acting again.") }
        }
    }
}
