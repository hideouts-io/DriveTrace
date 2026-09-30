import AppKit
import DriveCore

struct BatchDownloadPresentation: Identifiable {
    let id: UUID
    var status: String
    var progress: BatchProgress
    var report: BatchDownloadReport?
    var finished: Bool
}

extension AppModel {
    func downloadSelection(_ ids: Set<String>) {
        guard !ids.isEmpty else { error = "Select one or more files or folders first."; return }
        run {
            self.progress = "Preparing selected downloads…"
            let client = try await self.fileActionClient()
            guard let window = NSApp.keyWindow else { throw MonitorError.invalid("Open the explorer window before downloading.") }
            let panel = NSOpenPanel()
            panel.title = "Download Selected Items"
            panel.message = "Choose a destination. A new DriveTrace Download folder will contain your files and a completion report. Existing files are never overwritten. Shortcuts are reported as skipped."
            panel.prompt = "Download Here"
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
            let response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .OK, let parent = panel.url else { return }
            self.batchDownload = BatchDownloadPresentation(id: UUID(), status: "Discovering current folder contents…", progress: BatchProgress(current: "", discovered: 0, completed: 0, failed: 0), report: nil, finished: false)
            defer { self.batchDownload?.finished = true }
            do {
                let plan = try await client.planDownloads(ids: ids.sorted()) { value in
                    await MainActor.run { self.batchDownload?.progress = value; self.progress = "Discovering selected downloads · \(value.discovered) items" }
                }
                self.batchDownload?.status = "Downloading…"
                let report = try await client.downloadBatch(plan: plan, parent: parent) { value in
                    await MainActor.run { self.batchDownload?.progress = value; self.progress = "Downloading · \(value.completed) of \(value.discovered) processed · \(value.failed) failed/skipped" }
                }
                self.batchDownload?.report = report
                self.batchDownload?.status = report.summary
                self.operationNotice = report.summary
            } catch is CancellationError {
                self.batchDownload?.status = "Cancelled during discovery. No batch was completed."
            } catch let error as URLError where error.code == .cancelled {
                self.batchDownload?.status = "Cancelled during discovery. No batch was completed."
            } catch {
                self.batchDownload?.status = "Download could not finish: \(error.localizedDescription)"
                throw error
            }
        }
    }
}
