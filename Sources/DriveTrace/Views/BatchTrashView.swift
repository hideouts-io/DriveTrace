import SwiftUI
import DriveCore

struct BatchTrashView: View {
    @Bindable var model: AppModel
    var body: some View {
        if let review = model.pendingBatchTrash {
            VStack(alignment: .leading, spacing: 16) {
                Label(review.report == nil ? "Move \(review.files.count) selected items to Trash?" : "Move to Trash results", systemImage: "trash").font(.title2.bold())
                Text("This changes your Google Drive. Folders affect their contents too, including items not selected here. Shortcuts affect the shortcut, not its target. Restore items in Google Drive before permanent removal; Google normally deletes trashed items after 30 days.")
                Text("Only these selected IDs will be requested. Selecting a folder and its children can leave later requests already trashed; such requests are reported as unconfirmed. Stop prevents further requests but cannot undo a request already sent.").font(.caption).foregroundStyle(.secondary)
                if let report = review.report { Text(report.summary).font(.headline).accessibilityIdentifier("batchTrashSummary") }
                List(review.files) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(file.name, systemImage: file.isFolder ? "folder" : "doc").font(.headline)
                        Text(file.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let result = review.results.first(where: { $0.id == file.id }) {
                            Text(result.failure ?? "Google confirmed Move to Trash").foregroundStyle(result.failure == nil ? Color.secondary : Color.red)
                        } else { Text(review.report == nil ? "Awaiting confirmation / processing" : "Not attempted").font(.caption).foregroundStyle(.secondary) }
                    }.textSelection(.enabled)
                }.accessibilityIdentifier("batchTrashItems")
                if !review.indexFailures.isEmpty {
                    ScrollView { Text(review.indexFailures.joined(separator: "\n")).textSelection(.enabled) }.frame(maxHeight: 90).foregroundStyle(.red)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("batchTrashError") }
                if model.busy { ProgressView(model.progress).accessibilityIdentifier("batchTrashProgress") }
                HStack {
                    Spacer()
                    if model.busy {
                        Button("Stop batch", action: model.cancel).accessibilityIdentifier("stopBatchTrash")
                    } else if review.report != nil {
                        Button("Done") { model.pendingBatchTrash = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("closeBatchTrash")
                    } else {
                        Button("Cancel") { model.pendingBatchTrash = nil; model.error = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelBatchTrash")
                        Button("Move \(review.files.count) Items to Trash", role: .destructive) { model.confirmTrashSelection(review) }.accessibilityIdentifier("confirmBatchTrash")
                    }
                }
            }.padding(24).frame(width: 640, height: 550).interactiveDismissDisabled(model.busy).accessibilityElement(children: .contain).accessibilityIdentifier("batchTrashSheet")
        }
    }
}
