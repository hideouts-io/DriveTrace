import AppKit
import DriveCore

struct BatchDownloadPresentation: Identifiable {
    let id: UUID
    var status: String
    var progress: BatchProgress
    var report: BatchDownloadReport?
    var reportSaveError: String?
    var reportURL: URL?
    var recoveryError: String?
    var finished: Bool

    init(id: UUID, status: String, progress: BatchProgress, report: BatchDownloadReport?, reportSaveError: String?, finished: Bool) {
        self.id = id; self.status = status; self.progress = progress; self.report = report
        self.reportSaveError = reportSaveError; self.finished = finished
        reportURL = nil; recoveryError = nil
    }

    func reportingFailure(_ failure: BatchDownloadReportSaveError) -> BatchDownloadPresentation {
        BatchDownloadPresentation(id: id, status: "\(failure.report.summary) · Report save failed", progress: progress, report: failure.report, reportSaveError: failure.localizedDescription, finished: true)
    }
}

extension AppModel {
    func closeBatchDownload() {
        guard !busy, let job = batchDownload, job.finished else { return }
        if let error, error == job.reportSaveError || error == job.recoveryError { self.error = nil }
        if let report = job.report {
            let storage = job.reportURL.map { "Private report: \($0.path)." } ?? "No saved private report was confirmed."
            operationNotice = "\(report.summary) · Results closed. \(storage) Download folder: \(report.directory.path)."
        } else {
            operationNotice = "\(job.status) · Results closed. No completion report is available."
        }
        batchDownload = nil
    }

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
            let parent: URL
            do {
                guard let chosen = try await selectDownloadDestination(panel: panel, window: window) else {
                    self.operationNotice = "Selected download dismissed before a destination was confirmed."; return
                }
                parent = chosen
            } catch {
                guard error is CancellationError || (error as? URLError)?.code == .cancelled else { throw error }
                self.operationNotice = "Selected download cancelled before a destination was confirmed. No discovery or transfer started."; return
            }
            try validateBatchDestination(parent)
            self.batchDownload = BatchDownloadPresentation(id: UUID(), status: "Discovering current folder contents…", progress: BatchProgress(current: "", discovered: 0, completed: 0, failed: 0), report: nil, reportSaveError: nil, finished: false)
            defer { self.batchDownload?.finished = true }
            let cancellationNotice = "Selected download cancelled before a completion report was available. Check the selected destination before retrying."
            do {
                let plan: DownloadPlan
                do {
                    plan = try await client.planDownloads(ids: ids.sorted()) { value in
                        await MainActor.run { self.batchDownload?.progress = value; self.progress = "Discovering selected downloads · \(value.discovered) items" }
                    }
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        self.batchDownload?.status = "Discovery cancelled before transfers started"
                        self.batchDownload?.recoveryError = "No download folder or completion report was created by this attempt. Choose Download Selected again to repeat discovery; undiscovered descendants are not counted."
                        self.operationNotice = self.batchDownload?.status
                        return
                    }
                    self.batchDownload?.status = "Discovery failed before transfers started"
                    self.batchDownload?.recoveryError = "\(error.localizedDescription). Resolve the access or listing error and choose Download Selected again. No transfer started."
                    throw error
                }
                self.batchDownload?.status = "Downloading…"
                let report = try await client.downloadBatch(plan: plan, parent: parent) { value in
                    await MainActor.run { self.batchDownload?.progress = value; self.progress = "Downloading · \(value.completed) of \(value.discovered) processed · \(value.failed) failed/skipped" }
                }
                self.batchDownload?.report = report
                self.batchDownload?.reportURL = report.directory.appendingPathComponent("download-report.json")
                self.batchDownload?.status = report.summary
                self.operationNotice = report.summary
            } catch let failure as BatchDownloadReportSaveError {
                self.batchDownload = self.batchDownload?.reportingFailure(failure)
                self.operationNotice = "\(failure.report.summary) · Report save failed; results are retained."
                throw failure
            } catch is CancellationError {
                self.batchDownload?.status = cancellationNotice
                self.operationNotice = cancellationNotice
            } catch let error as URLError where error.code == .cancelled {
                self.batchDownload?.status = cancellationNotice
                self.operationNotice = cancellationNotice
            } catch {
                if self.batchDownload?.recoveryError == nil {
                    self.batchDownload?.status = "Selected download could not finish"
                    self.batchDownload?.recoveryError = error.localizedDescription
                }
                throw error
            }
        }
    }

    func saveBatchReportCopy(window: NSWindow?) {
        guard !busy, let job = batchDownload, job.finished, job.report != nil else { return }
        guard let window else { batchDownload?.recoveryError = "Open the download results window before choosing Save Report Copy."; return }
        let jobID = job.id
        run {
            self.progress = "Choose a new location for the private report…"
            let panel = NSSavePanel()
            panel.title = "Save Download Report Copy"
            panel.prompt = "Save Report"
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "DriveTrace download report.json"
            panel.directoryURL = job.reportURL?.deletingLastPathComponent() ?? job.report?.directory
            panel.canCreateDirectories = true
            panel.message = "Save the retained outcomes without downloading files again. Choose a new filename; existing files are never overwritten."
            do {
                guard let destination = try await selectReportCopyDestination(panel: panel, window: window) else {
                    self.operationNotice = "Report copy dismissed. Download results and any earlier report remain unchanged."; return
                }
                try await self.writeBatchReportCopy(jobID: jobID, destination: destination)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.operationNotice = "Report copy cancelled before saving. Download results and any earlier report remain unchanged."; return
                }
                if self.batchDownload?.id == jobID { self.batchDownload?.recoveryError = error.localizedDescription }
                throw error
            }
        }
    }

    /// Save the captured completed outcomes only. A copy never retries Google requests or changes transfer counts.
    func writeBatchReportCopy(jobID: UUID, destination: URL) async throws {
        try Task.checkCancellation()
        guard let job = batchDownload, job.id == jobID, job.finished, let report = job.report else {
            throw MonitorError.invalid("These download results are no longer open. Keep the results window open while saving its report.")
        }
        progress = "Saving the private report copy…"
        let task = Task.detached(priority: .userInitiated) { try saveBatchDownloadReport(report, to: destination) }
        let saved: URL
        do { saved = try await task.value }
        catch {
            if batchDownload?.id == jobID { batchDownload?.recoveryError = error.localizedDescription }
            throw error
        }
        // Persistence can complete after a late cancellation; never claim a committed copy was absent.
        operationNotice = "Report copy saved to \(saved.path). Downloaded files and transfer outcomes are unchanged."
        guard batchDownload?.id == jobID else { return }
        batchDownload?.reportURL = saved
        batchDownload?.reportSaveError = nil; batchDownload?.recoveryError = nil
        batchDownload?.status = "\(report.summary) · Report copy saved"
    }
}
