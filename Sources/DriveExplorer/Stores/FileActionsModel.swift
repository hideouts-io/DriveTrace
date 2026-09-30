import Foundation
import DriveCore

extension AppModel {
    private func fileActionClient() async throws -> GoogleClient {
        guard !isDemo, connected, let client else { throw MonitorError.invalid("File actions require a connected Google account. Demo data cannot be changed remotely.") }
        guard await credentials.grantedScopes().contains("https://www.googleapis.com/auth/drive") else {
            throw MonitorError.authentication("Open Connect Google Drive → Sign in, select View files and Move to Trash, and approve the new Google consent request first.")
        }
        let root = try await client.file(id: "root")
        guard root.id == rootID else { throw MonitorError.authentication("The connected Google account differs from this index. Synchronize the current account before acting on files.") }
        return client
    }
    func showPreviewSample() {
        run {
            guard self.isDemo else { throw MonitorError.invalid("The synthetic preview sample is available only in the demo workspace.") }
            let content = PreviewContent(data: Data("Drive Explorer preview sample\n\nThis is synthetic text for trying the native viewer. It is not the content of any indexed Drive file. No Google account or download was used.\n".utf8), fileExtension: "txt")
            self.preview = try await self.previewStore.save(content, name: "Synthetic preview sample")
        }
    }
    func showPreview(_ file: DriveFile) {
        run {
            let client = try await self.fileActionClient()
            self.progress = "Preparing file preview…"
            let current = try await client.file(id: file.id)
            let content = try await client.previewContent(file: current)
            try Task.checkCancellation()
            self.preview = try await self.previewStore.save(content, name: current.name)
        }
    }
    func removePreview(_ item: FilePreview) {
        Task {
            do { try await previewStore.remove(item.url) }
            catch { self.error = "The temporary preview could not be removed: \(error.localizedDescription)" }
        }
    }
    func prepareTrash(_ file: DriveFile) {
        run {
            self.progress = "Checking whether this item can move to Trash…"
            let client = try await self.fileActionClient()
            let current = try await client.file(id: file.id)
            guard current.capabilities?.canTrash == true, current.trashed != true else {
                throw MonitorError.invalid("Google does not allow this item to be moved to Trash, or it is already trashed. Check ownership or your Shared Drive role.")
            }
            self.pendingTrash = current
        }
    }
    func confirmTrash(_ file: DriveFile) {
        run {
            let client = try await self.fileActionClient()
            self.progress = "Moving item to Google Drive Trash…"
            let result: DriveFile
            do { result = try await client.moveToTrash(confirmed: file) }
            catch { throw MonitorError.invalid("Move to Trash was not confirmed: \(error.localizedDescription). If interrupted during the request, Google may have applied it. Refresh and check the item before trying again.") }
            self.pendingTrash = nil
            self.operationNotice = "Google confirmed Move to Trash. You can restore the item in Google Drive; trashed items are normally deleted automatically after 30 days."
            guard let database = self.database else { throw MonitorError.database("The item was trashed, but the local database is unavailable. Refresh before acting again.") }
            do {
                try await database.recordFileActionResult(result, detected: timestamp(Date()))
                self.serverResults = self.serverResults?.map { $0.id == result.id ? result : $0 }
                try await self.reload()
                self.syncVerified = false
                self.selectedFile = nil
            } catch { throw MonitorError.database("Google confirmed Move to Trash, but the local index update failed: \(error.localizedDescription). Refresh to reconcile; do not repeat the action.") }
        }
    }
}
