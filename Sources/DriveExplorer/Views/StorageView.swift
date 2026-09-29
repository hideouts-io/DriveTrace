import SwiftUI
import Charts
import DriveCore

struct StorageGroup: Identifiable { let id: String; let bytes: Int64?; let count: Int; let unknown: Int }
func storageGroups(_ files: [DriveFile], key: (DriveFile) -> String) -> [StorageGroup] {
    Dictionary(grouping: files.filter { !$0.isFolder && $0.trashed != true }, by: key).map { name, files in StorageGroup(id: name, bytes: sumKnown(files.compactMap(\.bytes)), count: files.count, unknown: files.filter { $0.bytes == nil }.count) }.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
}
struct StorageView: View {
    @Bindable var model: AppModel
    @State private var grouping = "type"
    private var groups: [StorageGroup] {
        storageGroups(model.files) { file in
            if grouping == "folder" { return file.parents?.first.map { model.index[$0]?.name ?? "Unresolved folder · \($0)" } ?? "No visible parent" }
            if grouping == "drive" { return file.driveId.flatMap { id in model.drives.first { $0.id == id }?.name ?? id } ?? "Personal / shared items" }
            return file.mimeType.hasPrefix("application/vnd.google-apps") ? "Google Workspace" : file.mimeType.components(separatedBy: "/").first?.capitalized ?? file.mimeType
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) { Text("Storage overview").font(.largeTitle.bold()); Text("Understand the space behind your files.").foregroundStyle(.secondary) }
                HStack(spacing: 16) {
                    metric("Known file size", value: byteLabel(sumKnown(groups.compactMap(\.bytes))), icon: "externaldrive")
                    metric("Reported quota usage", value: byteLabel(sumKnown(model.files.filter { $0.trashed != true }.compactMap(\.quotaBytes))), icon: "chart.pie")
                    metric("Unknown file sizes", value: groups.map(\.unknown).reduce(0, +).formatted(), icon: "questionmark.circle")
                }
                HStack { Text("Storage distribution").font(.title2.bold()); Spacer(); Picker("Group by", selection: $grouping) { Text("File type").tag("type"); Text("Direct parent").tag("folder"); Text("Drive").tag("drive") }.pickerStyle(.segmented).frame(width: 350).accessibilityIdentifier("storageGrouping") }
                Chart(groups.filter { $0.bytes != nil }.prefix(12)) { group in
                    BarMark(x: .value("Known bytes", group.bytes!), y: .value("Group", group.id)).foregroundStyle(.blue.gradient).cornerRadius(5)
                }.chartXAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let size = value.as(Int64.self) { Text(byteLabel(size)) } } } }.frame(height: max(200, CGFloat(min(groups.count, 12)) * 38)).accessibilityIdentifier("storageChart")
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        HStack { Text(group.id).fontWeight(.medium); Spacer(); Text("\(group.count) files · \(group.unknown) unknown sizes").foregroundStyle(.secondary); Text(byteLabel(group.bytes)).monospacedDigit().frame(width: 120, alignment: .trailing) }.padding(.vertical, 13)
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
