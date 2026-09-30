import SwiftUI
import AppKit
import DriveCore

struct BatchDownloadView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected downloads").font(.title2.bold())
            if let job = model.batchDownload {
                Text(job.status).textSelection(.enabled).accessibilityIdentifier("batchDownloadStatus")
                if !job.finished {
                    ProgressView().controlSize(.small)
                    Text("\(job.progress.discovered) items discovered · \(job.progress.completed) processed · \(job.progress.failed) failed/skipped").monospacedDigit().accessibilityIdentifier("batchDownloadProgress")
                    Text(job.progress.current).lineLimit(3).textSelection(.enabled)
                    Text("Large files stream to disk. Progress counts completed items, not bytes. Discovery reflects the accessible Drive state at request time.").font(.caption).foregroundStyle(.secondary)
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
                            Label(result.path, systemImage: result.outcome == .folderCreated ? "folder" : "checkmark.circle")
                        }
                    }.frame(minHeight: 180).accessibilityIdentifier("batchDownloadResults")
                    Text("Shows up to 100 entries per category. The complete private report is saved as download-report.json beside Files. Completed files remain after cancellation. A folder with inaccessible or changing contents may be incomplete.").font(.caption).foregroundStyle(.secondary)
                    Button("Show download folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.directory]) }.accessibilityIdentifier("revealBatchDownload")
                }
                Spacer()
                HStack {
                    Spacer()
                    if job.finished {
                        Button("Done") { model.batchDownload = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("closeBatchDownload")
                    } else {
                        Button("Cancel Download", action: model.cancel).accessibilityIdentifier("cancelBatchDownload")
                    }
                }
            }
        }.padding(24).frame(width: 640, height: 510).accessibilityElement(children: .contain).accessibilityIdentifier("batchDownloadSheet")
            .interactiveDismissDisabled(model.busy)
    }
}
