import Foundation
import AppKit
import DriveCore

extension AppModel {
    func fileActionClient() async throws -> GoogleClient {
        try Task.checkCancellation()
        guard !isDemo, connected, let client else { throw MonitorError.invalid("File actions require a connected Google account. Demo data cannot be changed remotely.") }
        guard await credentials.grantedScopes().contains("https://www.googleapis.com/auth/drive") else {
            throw MonitorError.authentication("Open Connect Google Drive → Sign in, select View files and Move to Trash, and approve the new Google consent request first.")
        }
        try Task.checkCancellation()
        let root = try await client.file(id: "root")
        try Task.checkCancellation()
        guard root.id == rootID else { throw MonitorError.authentication("The connected Google account differs from this index. Synchronize the current account before acting on files.") }
        return client
    }
    func downloadFile(_ file: DriveFile) {
        run {
            var destination: URL?
            do {
                try Task.checkCancellation()
                self.progress = "Preparing download…"
                let client = try await self.fileActionClient()
                let current = try await client.file(id: file.id)
                try Task.checkCancellation()
                let download = try fileDownload(current)
                guard let window = NSApp.keyWindow else { throw MonitorError.invalid("Open the explorer window before downloading a file.") }
                let panel = NSSavePanel()
                panel.title = "Download from Google Drive"
                panel.prompt = "Download"
                panel.nameFieldStringValue = download.name
                panel.canCreateDirectories = true
                panel.message = download.exportMIME == nil ? "Save the original file to your Mac." : "Google document export: \(URL(fileURLWithPath: download.name).pathExtension.uppercased()). Google limits these exports to 10 MB."
                destination = try await selectDownloadDestination(panel: panel, window: window)
                guard let destination else {
                    self.operationNotice = "Download dismissed before a destination was confirmed. Choose Download to start again."
                    return
                }
                try await self.saveFileDownload(current, client: client, destination: destination)
            } catch {
                guard error is CancellationError || (error as? URLError)?.code == .cancelled else { throw error }
                self.operationNotice = destination.map { "Download cancelled. Review \($0.path) before retrying. An incomplete transfer does not replace the existing file." }
                    ?? "Download cancelled before a destination was confirmed. Choose Download to start again."
            }
        }
    }
    /// A completed commit stays a saved outcome even if cancellation arrives during temporary cleanup.
    func saveFileDownload(_ file: DriveFile, client: GoogleClient, destination: URL) async throws {
        try Task.checkCancellation()
        progress = "Downloading to your selected location…"
        do { try await client.download(file: file, to: destination) }
        catch let warning as SavedDownloadCleanupError {
            showSavedDownloadCleanup(warning)
            return
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            throw FileDownloadFailure(destination: destination, cause: error)
        }
        operationNotice = "Download saved to \(destination.path)."
    }
    /// Present the committed outcome separately from the temporary cleanup failure; no transfer is retried.
    func showSavedDownloadCleanup(_ warning: SavedDownloadCleanupError) {
        operationNotice = "Download saved to \(warning.destination.path). Temporary cleanup needs attention."
        error = warning.localizedDescription
    }
    func showPreviewSample() {
        let generation = previewGeneration
        run {
            do {
                try Task.checkCancellation()
                guard self.isDemo else { throw MonitorError.invalid("The synthetic preview sample is available only in the demo workspace.") }
                let content = PreviewContent(data: Data("DriveTrace preview sample\n\nThis is synthetic text for trying the native viewer. It is not the content of any indexed Drive file. No Google account or download was used.\n".utf8), fileExtension: "txt")
                try await self.publishPreview(content, name: "Synthetic preview sample", generation: generation)
            } catch is PreviewSupersededError {
                self.operationNotice = "Preview stopped because the selection or workspace changed. Choose Preview file for the current item."
            } catch {
                guard error is CancellationError || (error as? URLError)?.code == .cancelled else { throw error }
                self.operationNotice = "Preview cancelled. Any previously displayed preview remains available. Choose Preview file to retry."
            }
        }
    }
    func showPreview(_ file: DriveFile) {
        let generation = previewGeneration
        run {
            do {
                try Task.checkCancellation()
                self.progress = "Preparing file preview…"
                let client = try await self.fileActionClient()
                let current = try await client.file(id: file.id)
                try self.checkPreviewRequest(generation)
                let content = try await client.previewContent(file: current)
                try await self.publishPreview(content, name: current.name, generation: generation)
            } catch is PreviewSupersededError {
                self.operationNotice = "Preview stopped because the selection or workspace changed. Choose Preview file for the current item."
            } catch {
                guard error is CancellationError || (error as? URLError)?.code == .cancelled else { throw error }
                self.operationNotice = "Preview cancelled. Any previously displayed preview remains available. Choose Preview file to retry."
            }
        }
    }
    /// Keep the earlier preview until a current request has saved and passed its publication check.
    func publishPreview(_ content: PreviewContent, name: String, generation: Int) async throws {
        try checkPreviewRequest(generation)
        let item = try await previewStore.save(content, name: name)
        do { try checkPreviewRequest(generation) }
        catch {
            let cause = error
            do { try await previewStore.remove(item.url) }
            catch { throw UnpublishedPreviewCleanupError(url: item.url, cause: cause, cleanup: error) }
            throw cause
        }
        preview = item
    }
    private func checkPreviewRequest(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == previewGeneration else { throw PreviewSupersededError() }
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

struct PreviewSupersededError: LocalizedError {
    var errorDescription: String? { "The selection or workspace changed before the preview could be displayed. Choose Preview file for the current item." }
}

struct UnpublishedPreviewCleanupError: LocalizedError {
    let url: URL
    let cause: any Error
    let cleanup: any Error
    var errorDescription: String? {
        "The preview was not displayed: \(cause.localizedDescription). Its temporary file could not be removed at \(url.path): \(cleanup.localizedDescription). Check that location and its permissions before removing leftover data."
    }
}

struct FileDownloadFailure: LocalizedError {
    let destination: URL
    let cause: any Error
    var errorDescription: String? {
        "Download to \(destination.path) failed: \(cause.localizedDescription). Check the destination folder's permissions and available space, review the file, then choose Download to retry."
    }
}
