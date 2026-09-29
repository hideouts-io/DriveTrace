import SwiftUI
import DriveCore

struct FolderNode: Identifiable {
    let id: String; let name: String; let children: [FolderNode]?
}
func folderNodes(files: [DriveFile], parent: String, visited: Set<String>) -> [FolderNode] {
    files.filter { $0.isFolder && ($0.parents ?? []).contains(parent) && !visited.contains($0.id) }.sorted { $0.name < $1.name }.map { file in
        let children = folderNodes(files: files, parent: file.id, visited: visited.union([file.id]))
        return FolderNode(id: file.id, name: file.name, children: children.isEmpty ? nil : children)
    }
}
struct SidebarView: View {
    @Bindable var model: AppModel
    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.navigate($0) })) {
            Section {
                item("All files", icon: "square.grid.2x2", id: "all")
                item("Newest items", icon: "clock", id: "newest")
                item("Largest files", icon: "externaldrive", id: "largest")
                item("Activity", icon: "waveform.path", id: "activity")
                item("Observed history", icon: "clock.arrow.circlepath", id: "history")
            } header: { Text("Explore") }
            Section("Drive") {
                item("My Drive", icon: "folder", id: "my")
                OutlineGroup(folderNodes(files: model.files, parent: model.rootID, visited: [model.rootID]), children: \.children) { node in
                    Label(node.name, systemImage: "folder").tag("folder:" + node.id).accessibilityIdentifier("folder-\(node.id)")
                        .contextMenu { if let file = model.index[node.id] { Button("Watch folder") { model.watch(file) }; Button("Open in Google Drive") { model.open(file) } } }
                }
                item("Shared with me", icon: "person.2", id: "shared")
                ForEach(model.drives) { drive in
                    DisclosureGroup {
                        OutlineGroup(folderNodes(files: model.files, parent: drive.id, visited: [drive.id]), children: \.children) { node in
                            Label(node.name, systemImage: "folder").tag("folder:" + node.id).accessibilityIdentifier("folder-" + node.id)
                        }
                    } label: { Label(drive.name, systemImage: "externaldrive.badge.person.crop").tag("drive:" + drive.id).accessibilityIdentifier("drive-" + drive.id) }
                }
                item("Trash", icon: "trash", id: "trash")
            }
            Section("Insights") {
                item("Storage overview", icon: "chart.bar.xaxis", id: "storage")
                item("Sharing audit", icon: "person.badge.shield.checkmark", id: "security")
                item("Folder watches", icon: "bell.badge", id: "watches")
            }
            if !model.saved.isEmpty {
                Section("Saved searches") {
                    ForEach(model.saved) { search in
                        Button { model.loadSearch(search) } label: { Label(search.name, systemImage: "magnifyingglass") }.buttonStyle(.plain)
                            .contextMenu { Button("Remove saved search") { model.removeSearch(search.id) } }
                    }
                }
            }
        }.listStyle(.sidebar).accessibilityIdentifier("navigationSidebar")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Image(systemName: model.isDemo ? "sparkles" : "person.crop.circle").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) { Text(model.isDemo ? "Demo workspace" : model.connected ? "Google Drive" : "Local workspace").fontWeight(.medium); Text(model.isDemo ? "Explore every view" : model.connected ? "Read-only connection" : "Connect in Settings").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).accessibilityLabel("Settings").accessibilityIdentifier("sidebarSettings")
                }
            }.padding(14)
        }
    }
    private func item(_ text: String, icon: String, id: String) -> some View { Label(text, systemImage: icon).tag(id).accessibilityIdentifier("nav-" + id) }
}
