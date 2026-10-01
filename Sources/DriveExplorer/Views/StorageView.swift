import SwiftUI
import Charts
import DriveCore

struct StorageGroup: Identifiable {
    let scope: StorageScope
    let title: String
    let bytes: Int64?
    let count: Int
    let unknown: Int
    var id: String { scope.key }
}
func storageGroups(_ files: [DriveFile], key: (DriveFile) -> StorageScope, label: (StorageScope) -> String) -> [StorageGroup] {
    Dictionary(grouping: files.filter { !$0.isFolder && $0.trashed != true }, by: key).map { scope, files in
        StorageGroup(scope: scope, title: label(scope), bytes: sumKnown(files.compactMap(\.bytes)), count: files.count, unknown: files.filter { $0.bytes == nil }.count)
    }.sorted { $0.bytes == $1.bytes ? $0.id < $1.id : ($0.bytes ?? -1) > ($1.bytes ?? -1) }
}
func storageTitle(_ scope: StorageScope, index: [String: DriveFile], drives: [SharedDrive]) -> String {
    switch scope {
    case .workspace: "Google Workspace"
    case .mimeFamily(let type): type.isEmpty ? "Unknown MIME family" : type.capitalized
    case .parent(let id): id.map { index[$0]?.name ?? "Unresolved folder · \($0)" } ?? "No visible parent"
    case .drive(let id): id.map { id in drives.first { $0.id == id }?.name ?? id } ?? "Personal / shared items"
    }
}
struct StorageView: View {
    @Bindable var model: AppModel
    private var groups: [StorageGroup] {
        storageGroups(model.files, key: { file in
            if model.storageGrouping == "folder" { return .parent(file.parents?.first) }
            if model.storageGrouping == "drive" { return .drive(file.driveId) }
            return storageType(file)
        }, label: { storageTitle($0, index: model.index, drives: model.drives) })
    }
    var body: some View {
        let groups = groups
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) { Text("Storage overview").font(.largeTitle.bold()); Text("Understand the space behind your files.").foregroundStyle(.secondary) }
                HStack(spacing: 16) {
                    metric("Known file size", value: byteLabel(sumKnown(groups.compactMap(\.bytes))), icon: "externaldrive")
                    metric("Reported quota usage", value: byteLabel(sumKnown(model.files.filter { $0.trashed != true }.compactMap(\.quotaBytes))), icon: "chart.pie")
                    metric("Unknown file sizes", value: groups.map(\.unknown).reduce(0, +).formatted(), icon: "questionmark.circle")
                }
                HStack { Text("Storage distribution").font(.title2.bold()); Spacer(); Picker("Group by", selection: $model.storageGrouping) { Text("File type").tag("type"); Text("Direct parent").tag("folder"); Text("Drive").tag("drive") }.pickerStyle(.segmented).frame(width: 350).accessibilityIdentifier("storageGrouping") }
                Chart(groups.filter { $0.bytes != nil }.prefix(12)) { group in
                    BarMark(x: .value("Known bytes", group.bytes!), y: .value("Group", group.id)).foregroundStyle(.blue.gradient).cornerRadius(5)
                        .accessibilityLabel(group.title).accessibilityValue("\(group.count) files, \(byteLabel(group.bytes))")
                }
                .chartYAxis { AxisMarks { value in AxisValueLabel { if let id = value.as(String.self), let group = groups.first(where: { $0.id == id }) { Text(group.title) } } } }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { point in
                                guard let anchor = proxy.plotFrame else { return }
                                let frame = geometry[anchor]
                                guard frame.contains(point), let id: String = proxy.value(atY: point.y - frame.minY), let group = groups.first(where: { $0.id == id }) else { return }
                                model.openStorageGroup(group)
                            }
                    }
                }
                .chartXAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let size = value.as(Int64.self) { Text(byteLabel(size)) } } } }.frame(height: max(200, CGFloat(min(groups.count, 12)) * 38)).accessibilityIdentifier("storageChart")
                Text("Click a bar or category to see its files. File type uses Google’s reported MIME family; Chemical means chemical/* metadata, not an inspection of the contents.").font(.callout).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        Button { model.openStorageGroup(group) } label: {
                            HStack { Text(group.title).fontWeight(.medium); Spacer(); Text("\(group.count) files · \(group.unknown) unknown sizes").foregroundStyle(.secondary); Text(byteLabel(group.bytes)).monospacedDigit().frame(width: 120, alignment: .trailing); Image(systemName: "chevron.right").foregroundStyle(.secondary) }.padding(.vertical, 13).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("storageGroup:" + group.id)
                            .accessibilityLabel("Show \(group.title) files").accessibilityHint("Open \(group.count) indexed files, largest first")
                            .help("Show matching files · " + group.id)
                        Divider()
                    }
                }
                Label("Computed from indexed, nontrashed files. File size and reported quota usage measure different things. Missing values remain unknown; this is not an account quota total. Parent groups count direct children only.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
    private func metric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { Label(title, systemImage: icon).foregroundStyle(.secondary); Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 13))
    }
}

func sumKnown(_ values: [Int64]) -> Int64? { values.isEmpty ? nil : values.reduce(0, +) }
