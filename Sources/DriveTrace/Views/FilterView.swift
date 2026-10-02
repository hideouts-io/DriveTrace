import SwiftUI
import DriveCore

struct FilterView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { field("File ID", value: $model.filter.fileID, id: "filterID"); field("MIME type", value: $model.filter.mime, id: "filterMIME"); field("Extension", value: $model.filter.ext, id: "filterExtension") }
                GridRow { field("Owner name / email", value: $model.filter.owner, id: "filterOwner"); field("Parent folder ID", value: $model.filter.parent, id: "filterParent"); field("Shared Drive ID", value: $model.filter.drive, id: "filterDrive") }
                GridRow {
                    field("Min bytes", value: $model.minimumSizeInput, id: "filterMinSize").onChange(of: model.minimumSizeInput) { _, _ in model.updateSizes() }
                    field("Max bytes", value: $model.maximumSizeInput, id: "filterMaxSize").onChange(of: model.maximumSizeInput) { _, _ in model.updateSizes() }
                    Picker("Trash", selection: $model.filter.trash) { Text("Active").tag("active"); Text("In trash").tag("trash"); Text("Any").tag("any") }.accessibilityIdentifier("filterTrash")
                }
                GridRow { field("Created after (RFC3339)", value: $model.filter.createdAfter, id: "createdAfter"); field("Created before", value: $model.filter.createdBefore, id: "createdBefore"); Color.clear.frame(height: 1) }
                GridRow { field("Modified after (RFC3339)", value: $model.filter.modifiedAfter, id: "modifiedAfter"); field("Modified before", value: $model.filter.modifiedBefore, id: "modifiedBefore"); Color.clear.frame(height: 1) }
                GridRow { field("Discovered after · local only", value: $model.filter.discoveredAfter, id: "discoveredAfter"); field("Discovered before", value: $model.filter.discoveredBefore, id: "discoveredBefore"); Color.clear.frame(height: 1) }
            }.textFieldStyle(.roundedBorder)
            HStack {
                Text("All filters are combined. Google search uses exact MIME and owner email; size and extension require the local index.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Search Google", action: model.queryGoogle).disabled(model.busy || model.isDemo || !model.connected || model.filterValidationError != nil).accessibilityIdentifier("searchGoogle")
            }
            if let error = model.filterValidationError { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }
    private func field(_ label: String, value: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); TextField(label, text: value).labelsHidden().accessibilityLabel(label).accessibilityIdentifier(id) }
    }
}
