import SwiftUI
import QuickLookUI
import DriveCore

struct FilePreviewView: View {
    let preview: FilePreview
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(preview.name).font(.title2.bold()).lineLimit(2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("closeFilePreview") }
            Text("Temporary local preview · up to 20 MiB · Google PDF exports have a 10 MB API limit").font(.caption).foregroundStyle(.secondary)
            NativeFilePreview(url: preview.url).accessibilityIdentifier("nativeFilePreview")
            Text("The app removes its temporary file when this sheet closes. Quick Look is a macOS service and may maintain its own caches.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 700, minHeight: 540).accessibilityElement(children: .contain).accessibilityIdentifier("filePreviewSheet")
    }
}

/// SwiftUI owns the sheet and URL; AppKit only renders the Quick Look view.
private struct NativeFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}

struct TrashConfirmationView: View {
    let file: DriveFile
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Move to Google Drive Trash?", systemImage: "trash").font(.title2.bold())
            Text(file.name).font(.headline).textSelection(.enabled)
            Text("File ID: \(file.id)").font(.caption.monospaced()).textSelection(.enabled)
            if file.isFolder { Text("This is a folder. Its contents are affected too. Review the folder in Google Drive before continuing.").foregroundStyle(.orange) }
            Text("This changes your Google Drive, not just this local index. You can restore the item in Google Drive before it is permanently removed. Google normally deletes trashed items after 30 days.")
            Text("No permanent-delete or empty-trash action is provided by this app.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error {
                ScrollView { Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140).foregroundStyle(.red).accessibilityIdentifier("trashActionError")
            }
            if model.busy { ProgressView(model.progress).accessibilityIdentifier("trashActionProgress") }
            HStack {
                Button("View in Google Drive") { model.open(file) }.accessibilityIdentifier("reviewTrashItem")
                Spacer()
                Button("Cancel") { model.pendingTrash = nil; model.error = nil }.disabled(model.busy).keyboardShortcut(.cancelAction).accessibilityIdentifier("cancelMoveToTrash")
                Button("Move to Trash", role: .destructive) { model.confirmTrash(file) }.disabled(model.busy).accessibilityIdentifier("confirmMoveToTrash")
            }
        }.padding(24).frame(width: 540).accessibilityElement(children: .contain).accessibilityIdentifier("trashConfirmation").interactiveDismissDisabled(model.busy)
    }
}
