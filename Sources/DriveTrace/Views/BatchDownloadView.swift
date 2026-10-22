import SwiftUI
import AppKit
import DriveCore

struct BatchDownloadView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected downloads").font(.title2.bold())
            if let job = model.batchDownload {
                Text(job.status).textSelection(.enabled).accessibilityLabel(job.status).accessibilityIdentifier("batchDownloadStatus")
                if !job.finished {
                    ProgressView().controlSize(.small).accessibilityLabel("Download in progress").accessibilityIdentifier("batchDownloadSpinner")
                    Text("\(job.progress.discovered) items discovered · \(job.progress.completed) processed · \(job.progress.failed) failed/skipped").monospacedDigit().accessibilityIdentifier("batchDownloadProgress")
                    Text(job.progress.current).lineLimit(3).textSelection(.enabled).accessibilityLabel("Current item: \(job.progress.current)").accessibilityIdentifier("batchDownloadCurrentItem")
                    Text("Large files stream to disk. Progress counts completed items, not bytes. Discovery reflects the accessible Drive state at request time.").font(.caption).foregroundStyle(.secondary)
                }
                if job.reportSaveError != nil || job.recoveryError != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let failure = job.reportSaveError {
                                Label(failure, systemImage: "exclamationmark.triangle").textSelection(.enabled).accessibilityIdentifier("batchDownloadReportError")
                            }
                            if let failure = job.recoveryError {
                                Label(failure, systemImage: "exclamationmark.triangle").textSelection(.enabled).accessibilityIdentifier("batchDownloadRecoveryError")
                            }
                        }
                    }.font(.callout).foregroundStyle(.red).frame(maxHeight: 130).accessibilityIdentifier("batchDownloadErrorArea")
                }
                if job.finished && job.report == nil {
                    Text("Latest progress: \(job.progress.discovered) planned items · \(job.progress.completed) processed · \(job.progress.failed) reported issues").accessibilityIdentifier("batchDownloadStoppedProgress")
                    Text("No completion report is available. These counts reflect observed progress; undiscovered descendants are not counted.").font(.caption).foregroundStyle(.secondary)
                }
                if let report = job.report {
                    Text(report.directory.path).font(.caption).textSelection(.enabled)
                    List {
                        ForEach(report.issues.prefix(100)) { issue in
                            VStack(alignment: .leading) { Label(issue.path, systemImage: "exclamationmark.triangle"); Text(issue.reason).font(.caption).textSelection(.enabled) }
                        }
                        ForEach(report.results.filter { $0.outcome == .failed }.prefix(100)) { result in
                            VStack(alignment: .leading) { Label(result.path, systemImage: "xmark.circle"); Text(result.message ?? "Failure details unavailable").font(.caption).textSelection(.enabled) }
                        }
                        ForEach(report.results.filter { $0.outcome != .failed }.prefix(100)) { result in
                            VStack(alignment: .leading) {
                                Label(result.path, systemImage: result.message != nil ? "exclamationmark.triangle" : result.outcome == .folderCreated ? "folder" : "checkmark.circle")
                                if let warning = result.message {
                                    Text(warning).font(.caption).textSelection(.enabled).accessibilityLabel("Saved file cleanup warning: \(warning)")
                                }
                            }
                        }
                        ForEach(Array(report.unattempted.prefix(100).enumerated()), id: \.offset) { _, path in
                            VStack(alignment: .leading) { Label(path, systemImage: "pause.circle"); Text("Not attempted — batch cancelled").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(minHeight: 180).accessibilityIdentifier("batchDownloadResults")
                    Text("Shows up to 100 entries per category. Completed files remain after cancellation. A folder with inaccessible or changing contents may be incomplete."
                         + (job.reportURL == nil ? " Save Report Copy before closing to retain the full results; a saved private report could not be confirmed." : " The full private report is saved at the location below.")).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("batchDownloadReportStorage")
                    if let url = job.reportURL {
                        Text("Report: \(url.path)").font(.caption).textSelection(.enabled).accessibilityIdentifier("batchDownloadReportPath")
                        Button("Show report in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.accessibilityIdentifier("revealBatchDownloadReport")
                    }
                    Button("Show download folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.directory]) }.accessibilityIdentifier("revealBatchDownload")
                    ReportCopyButton(enabled: job.finished && !model.busy, action: model.saveBatchReportCopy).fixedSize()
                }
                if model.busy && job.finished { ProgressView(model.progress).accessibilityIdentifier("batchReportCopyProgress") }
                Spacer()
                HStack {
                    Spacer()
                    if job.finished {
                        Button("Done", action: model.closeBatchDownload).disabled(model.busy).keyboardShortcut(.cancelAction).accessibilityIdentifier("closeBatchDownload")
                    } else {
                        Button("Cancel Download", action: model.cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelBatchDownload")
                    }
                }
            }
        }.padding(24).frame(width: 680, height: 650).accessibilityElement(children: .contain).accessibilityIdentifier("batchDownloadSheet")
            .interactiveDismissDisabled(model.busy)
    }
}
