import SwiftUI
import DriveCore

struct ExplorerView: View {
    @Bindable var model: AppModel
    @State private var searchName = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.title).font(.largeTitle.bold())
                        Text(subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(model.results.count.formatted()) items").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let selection = model.selection, selection.hasPrefix("folder:"), let file = model.index[String(selection.dropFirst(7))] {
                    HStack {
                        BreadcrumbView(components: folderTrail(file.id, index: model.index, roots: model.navigationRoots), current: file.id) { id in
                            model.navigate(id == model.rootID ? "my" : "folder:" + id)
                        }
                        Spacer()
                        Button("Watch folder") { model.watch(file) }.accessibilityIdentifier("watchCurrentFolder")
                    }.font(.caption)
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search file names…", text: $model.filter.text).textFieldStyle(.plain).accessibilityIdentifier("fileSearch")
                    Button { model.filter = FileFilter(); model.serverResults = nil; model.updateResults() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search").accessibilityIdentifier("clearSearch")
                    Divider().frame(height: 20)
                    Picker("Sort", selection: $model.order) { ForEach(FileOrder.allCases, id: \.self) { Text(orderLabel($0)).tag($0) } }.labelsHidden().frame(width: 160).accessibilityIdentifier("sortOrder")
                    Button { model.ascending.toggle() } label: { Image(systemName: model.ascending ? "arrow.up" : "arrow.down") }.help(model.ascending ? "Ascending; click for descending" : "Descending; click for ascending").accessibilityIdentifier("sortDirection")
                }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                if model.selection == "newest" {
                    HStack {
                        Text("TIME BASIS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Button("Created") { model.order = .created; model.ascending = false }
                        Button("Modified") { model.order = .modified; model.ascending = false }
                        Button("First discovered") { model.order = .discovered; model.ascending = false }
                        Button("Uploads & actors") { model.activityAction = "UPLOADED"; model.navigate("activity") }
                        Spacer()
                        Menu("Time range") {
                            Button("All time") { model.filter.createdAfter = ""; model.filter.modifiedAfter = ""; model.filter.discoveredAfter = "" }
                            ForEach([1, 7, 30], id: \.self) { days in Button("Last \(days) days") { let date = timestamp(Date().addingTimeInterval(Double(-days * 86400))); model.filter.createdAfter = ""; model.filter.modifiedAfter = ""; model.filter.discoveredAfter = ""; if model.order == .modified { model.filter.modifiedAfter = date } else if model.order == .discovered { model.filter.discoveredAfter = date } else { model.filter.createdAfter = date } } }
                        }
                    }.controlSize(.small)
                }
                if model.showFilters { FilterView(model: model) }
                HStack {
                    Label(model.serverResults == nil ? "Local index · \(model.files.count.formatted()) cached items" : model.serverCoverage, systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save search…") { saving = true }.buttonStyle(.link).font(.caption).accessibilityIdentifier("saveSearch")
                }
                if !model.gaps.isEmpty { DisclosureGroup("\(model.gaps.count) coverage gaps · results may be incomplete") { ForEach(model.gaps, id: \.self) { Text($0).font(.caption).textSelection(.enabled) } }.foregroundStyle(.orange) }
            }.padding(22)
            Divider()
            HSplitView {
                FileTable(model: model)
                if model.showInspector { InspectorView(model: model).frame(minWidth: 260, idealWidth: 300, maxWidth: 330) }
            }
        }
        .sheet(isPresented: $saving) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Save this search").font(.title2.bold())
                TextField("Search name", text: $searchName).accessibilityIdentifier("savedSearchName")
                HStack { Spacer(); Button("Cancel") { saving = false }; Button("Save") { model.saveSearch(name: searchName); searchName = ""; saving = false }.keyboardShortcut(.defaultAction).disabled(searchName.isEmpty).accessibilityIdentifier("confirmSaveSearch") }
            }.padding(24).frame(width: 380)
        }
    }
    private var subtitle: String {
        switch model.selection {
        case "newest": "Creation, modification and discovery are different moments. Choose the one you need."
        case "largest": "Find what takes up space. Unknown sizes stay distinct from zero-byte files."
        case "security": "Review visible sharing permissions. Missing permissions do not prove a file is private."
        default: "Find, sort and inspect the files in your accessible Drive."
        }
    }
}
struct FileTable: View {
    @Bindable var model: AppModel
    @State private var headerSort = [KeyPathComparator(\DriveFile.name)]
    var body: some View {
        Table(model.results, selection: $model.selectedFile, sortOrder: $headerSort) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 9) {
                    Image(systemName: fileIcon(file)).foregroundStyle(file.isFolder ? .blue : .secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) { Text(file.name).lineLimit(1); if file.shortcutDetails != nil { Text("Shortcut").font(.caption2).foregroundStyle(.secondary) } }
                }.padding(.vertical, 4).accessibilityIdentifier("file-\(file.id)")
            }.width(min: 200, ideal: 260)
            TableColumn("Size", value: \.sortableBytes) { file in Text(byteLabel(file.bytes)).monospacedDigit().foregroundStyle(file.bytes == nil ? .secondary : .primary) }.width(min: 70, ideal: 85)
            TableColumn("Modified", value: \.sortableModified) { file in Text(displayDate(file.modifiedTime)).foregroundStyle(.secondary) }.width(min: 120, ideal: 130)
            TableColumn("Owner", value: \.ownerLabel) { file in Text(file.ownerLabel).lineLimit(1).foregroundStyle(.secondary) }.width(min: 80, ideal: 90)
        }
        .accessibilityIdentifier("filesTable")
        .onChange(of: headerSort) { _, sort in
            guard let first = sort.first else { return }
            if first.keyPath == \DriveFile.name { model.order = .name }
            else if first.keyPath == \DriveFile.sortableBytes { model.order = .size }
            else if first.keyPath == \DriveFile.sortableModified { model.order = .modified }
            else if first.keyPath == \DriveFile.ownerLabel { model.order = .owner }
            model.ascending = first.order == .forward
        }
        .onChange(of: model.order) { _, _ in updateHeaderSort() }
        .onChange(of: model.ascending) { _, _ in updateHeaderSort() }
        .onAppear { updateHeaderSort() }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let file = model.index[id] ?? model.serverResults?.first(where: { $0.id == id }) {
                Button("Open in Google Drive") { model.open(file) }
                Button("Show activity") { model.activityTarget = file.id; model.navigate("activity") }
                if file.isFolder { Button("Browse folder") { model.navigate("folder:" + id) }; Button("Watch folder") { model.watch(file) } }
                if let shortcut = file.shortcutDetails { Button("Inspect shortcut target") { model.selectedFile = shortcut.targetId; model.showInspector = true } }
            }
        } primaryAction: { ids in if let id = ids.first, let file = model.index[id] { if file.isFolder { model.navigate("folder:" + id) } else { model.open(file) } } }
        .overlay { if model.results.isEmpty { ContentUnavailableView("No matching files", systemImage: "doc.text.magnifyingglass", description: Text("Adjust the filters or refresh your Drive index.")) } }
    }
    private func updateHeaderSort() {
        let direction: SortOrder = model.ascending ? .forward : .reverse
        switch model.order {
        case .name: headerSort = [KeyPathComparator(\DriveFile.name, order: direction)]
        case .size: headerSort = [KeyPathComparator(\DriveFile.sortableBytes, order: direction)]
        case .modified: headerSort = [KeyPathComparator(\DriveFile.sortableModified, order: direction)]
        case .owner: headerSort = [KeyPathComparator(\DriveFile.ownerLabel, order: direction)]
        default: headerSort = []
        }
    }

}
func orderLabel(_ order: FileOrder) -> String {
    switch order { case .name: "Name"; case .size: "File size"; case .quota: "Quota usage"; case .created: "Created"; case .modified: "Modified"; case .discovered: "First discovered"; case .activity: "Last activity"; case .activityCount: "Activity count"; case .type: "Type"; case .owner: "Owner"; case .location: "Location" }
}
func fileIcon(_ file: DriveFile) -> String {
    if file.isFolder { return "folder.fill" }; if file.shortcutDetails != nil { return "arrow.turn.up.right" }
    if file.mimeType.hasPrefix("video/") { return "film" }; if file.mimeType.hasPrefix("image/") { return "photo" }
    if file.mimeType.contains("spreadsheet") || file.mimeType == "text/csv" { return "tablecells" }
    if file.mimeType.contains("zip") { return "doc.zipper" }; return "doc.text"
}

extension DriveFile {
    var sortableBytes: Int64 { bytes ?? -1 }
    var sortableModified: String { modifiedTime ?? "" }
}
