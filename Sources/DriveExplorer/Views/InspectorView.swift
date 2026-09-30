import SwiftUI
import DriveCore

struct InspectorView: View {
    @Bindable var model: AppModel
    @State private var snapshots: [SnapshotRecord] = []
    @State private var evidence: [DriveEvent] = []
    @State private var raw: String?
    var body: some View {
        ScrollView {
            if let file = model.selected {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: fileIcon(file)).font(.system(size: 34, weight: .light)).foregroundStyle(.tint)
                        Text(file.name).font(.title2.bold()).textSelection(.enabled)
                        Text(file.typeLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Open in Google Drive") { model.open(file) }.accessibilityIdentifier("openSelectedFile")
                    if model.isDemo {
                        Button("Try a synthetic preview sample", action: model.showPreviewSample).disabled(model.busy).accessibilityIdentifier("previewDemoSample")
                    }
                    if !file.isFolder && file.shortcutDetails == nil {
                        Button("Preview file") { model.showPreview(file) }.disabled(model.busy || model.isDemo || !model.managementGranted).accessibilityIdentifier("previewSelectedFile")
                    }
                    Button("Move to Trash…", role: .destructive) { model.prepareTrash(file) }.disabled(model.busy || model.isDemo || !model.managementGranted || file.trashed == true).accessibilityIdentifier("trashSelectedFile")
                    if !model.managementGranted && !model.isDemo {
                        Text("To enable previews and Trash, choose View files and Move to Trash in Connect Google Drive → Sign in.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Group {
                        detail("File size", byteLabel(file.bytes)); detail("Quota usage", byteLabel(file.quotaBytes))
                        detail("Owner · not necessarily uploader", file.ownerLabel)
                        detail("Created", displayDate(file.createdTime)); detail("Modified", displayDate(file.modifiedTime))
                        detail("First discovered locally", displayDate(model.facts.firstSeen[file.id]))
                        detail("Location · current cached metadata", filePath(file.id, index: model.index, visited: []))
                        detail("File ID", file.id)
                    }
                    if file.isFolder {
                        let children = descendants(file.id, files: model.files)
                        let known = model.files.filter { children.contains($0.id) && !$0.isFolder }
                        detail("Computed descendant total", byteLabel(sumKnown(known.compactMap(\.bytes))))
                        Text("\(known.filter { $0.bytes == nil }.count) descendants have unknown size. Indexed scope only.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let shortcut = file.shortcutDetails {
                        detail("Shortcut target", shortcut.targetId)
                        Button("Inspect target") {
                            if model.index[shortcut.targetId] != nil { model.selectedFile = shortcut.targetId }
                            else { model.error = "The target is not in this local index. It may be outside the indexed scope or inaccessible." }
                        }
                    }
                    Divider()
                    Text("Sharing").font(.headline)
                    if let permissions = file.permissions, !permissions.isEmpty {
                        ForEach(permissions, id: \.id) { permission in
                            Label { VStack(alignment: .leading) { Text(permission.emailAddress ?? permission.domain ?? permission.type); Text(permission.role + (permission.allowFileDiscovery == true ? " · discoverable" : "")).foregroundStyle(.secondary) } } icon: { Image(systemName: permission.type == "anyone" ? "globe" : "person") }.font(.caption)
                        }
                    } else { Text("No permission details returned. This does not establish that the item is private.").font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    HStack { Text("Recorded activity").font(.headline); Spacer(); Text("\(evidence.count)").foregroundStyle(.secondary) }
                    ForEach(evidence.prefix(6)) { event in
                        Button { raw = event.raw } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.action.capitalized).fontWeight(.medium)
                                Text(event.actor ?? "Actor unavailable").foregroundStyle(.secondary)
                                Text(displayDate(event.time)).foregroundStyle(.secondary)
                                Text(event.source.rawValue.uppercased()).font(.caption2).foregroundStyle(.tint)
                            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    Button("Show full timeline") { model.activityTarget = file.id; model.navigate("activity") }.accessibilityIdentifier("selectedFileActivity")
                    DisclosureGroup("Local snapshots (\(snapshots.count))") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Observed states only. Gaps and pre-index history cannot be reconstructed.").font(.caption).foregroundStyle(.secondary)
                            ForEach(snapshots) { snapshot in
                                Button(displayDate(snapshot.observedAt)) { do { raw = try encoded(snapshot) } catch { model.error = error.localizedDescription } }.buttonStyle(.link)
                                Text(snapshot.reconstructedPath).font(.caption).textSelection(.enabled)
                            }
                        }.padding(.top, 8)
                    }
                    DisclosureGroup("Advanced evidence") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let md5 = file.md5Checksum { detail("MD5", md5) }
                            if let sha = file.sha256Checksum { detail("SHA-256", sha) }
                            Button("Inspect metadata JSON") { do { raw = try encoded(file) } catch { model.error = error.localizedDescription } }
                        }.padding(.top, 8)
                    }
                }.padding(22)
            } else { ContentUnavailableView("Select a file", systemImage: "sidebar.right", description: Text("Metadata, sharing and evidence appear here.")).padding(.top, 70) }
        }.background(.background).accessibilityIdentifier("fileInspector")
        .task(id: model.selectedFile) {
            snapshots = []; evidence = []
            guard let id = model.selectedFile, let database = model.database else { return }
            do { let history = try await database.snapshotRecords(id); let events = try await database.events(fileID: id, limit: 1000); guard model.selectedFile == id else { return }; snapshots = history; evidence = events }
            catch { model.error = error.localizedDescription }
        }
        .sheet(item: Binding(get: { raw.map { EvidenceText(text: $0) } }, set: { raw = $0?.text })) { item in RawEvidenceView(text: item.text) }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).textSelection(.enabled) }
    }
}
struct EvidenceText: Identifiable { let text: String; var id: String { text } }
struct RawEvidenceView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Raw evidence").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("closeEvidence") }
            Text("API payloads may contain file names and account identifiers. Review before sharing.").foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.background(.quaternary.opacity(0.3))
        }.padding(24).frame(width: 760, height: 600)
    }
}
