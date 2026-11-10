import SwiftUI
import DriveCore

struct ActivityView: View {
    @Bindable var model: AppModel
    @State private var selected: String?
    @State private var raw: EvidenceText?
    private var filtered: [DriveEvent] { model.filteredEvents }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Activity").font(.largeTitle.bold())
                Text("Who did what, and when — with the source attached.").foregroundStyle(.secondary)
                HStack {
                    TextField("Actor name or People resource", text: $model.activityActor).accessibilityIdentifier("activityActor")
                    TextField("File name or ID", text: $model.activityTarget).accessibilityIdentifier("activityTarget")
                    Picker("Action", selection: $model.activityAction) {
                        Text("All actions").tag("")
                        ForEach(["CREATED", "UPLOADED", "MODIFIED", "RENAMED", "MOVED", "TRASHED", "RESTORED", "DELETED", "INACCESSIBLE", "PERMISSION", "SHARED", "UNSHARED", "OWNERSHIP", "DISCOVERED"], id: \.self) { Text($0.capitalized).tag($0) }
                    }.frame(width: 200).accessibilityIdentifier("activityAction")
                }.textFieldStyle(.roundedBorder)
                HStack {
                    TextField("After · RFC3339", text: $model.activityAfter).accessibilityIdentifier("activityAfter")
                    TextField("Before · RFC3339", text: $model.activityBefore).accessibilityIdentifier("activityBefore")
                    Menu("Time range") { Button("All recorded time") { model.activityAfter = ""; model.activityBefore = "" }; ForEach([1,7,30], id: \.self) { days in Button("Last \(days) days") { model.activityAfter = timestamp(Date().addingTimeInterval(Double(-days * 86400))); model.activityBefore = "" } } }
                    Button("Reset", action: resetFilters).accessibilityIdentifier("resetActivity")
                }.textFieldStyle(.roundedBorder)
                if let error = model.activityValidationError { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("activityFilterError") }
                Text("\(filtered.count) matching source records · latest \(model.events.count) loaded (limit 10,000). Changes actors are unknown; Activity identities can be unavailable. Sources are not merged into assumed actions.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("activityResultCount")
            }.padding(22)
            Divider()
            HSplitView {
                if filtered.isEmpty {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(filtered, selection: $selected) {
                        TableColumn("Action") { event in Label(event.action.capitalized, systemImage: eventIcon(event.action)) }.width(min: 110, ideal: 140)
                        TableColumn("Item", value: \.name).width(min: 160, ideal: 280)
                        TableColumn("Actor") { Text($0.actor ?? "Unavailable").foregroundStyle(.secondary) }.width(min: 110, ideal: 160)
                        TableColumn("When") { Text(displayDate($0.time)) }.width(min: 130, ideal: 160)
                        TableColumn("Source") { Text($0.source.rawValue.capitalized).font(.caption).foregroundStyle(.tint) }.width(75)
                    }.accessibilityIdentifier("activityTable")
                }
                if let event = filtered.first(where: { $0.id == selected }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: eventIcon(event.action)).font(.largeTitle).foregroundStyle(.tint)
                            Text(event.action.capitalized).font(.title2.bold())
                            Text(event.name).font(.headline)
                            Text(event.explanation).foregroundStyle(.secondary)
                            detail("Actor", event.actor ?? "Unavailable — not inferred from ownership")
                            detail("Action time", displayDate(event.time)); detail("Observed locally", displayDate(event.detected))
                            if let name = event.previousName { detail("Previous name", name) }
                            detail("Previous parent IDs", event.previousParents.isEmpty ? "Not supplied" : event.previousParents.joined(separator: ", "))
                            detail("Current / added parent IDs", event.parents.isEmpty ? "Not supplied" : event.parents.joined(separator: ", "))
                            Text("Parent IDs are evidence from this record. Current folder names cannot prove a full historical path.").font(.caption).foregroundStyle(.secondary)
                            let related = model.events.filter { $0.fileID == event.fileID && $0.source != event.source && abs((parseDate($0.time) ?? .distantPast).timeIntervalSince(parseDate(event.time) ?? .distantFuture)) < 60 }
                            if !related.isEmpty { Text("\(related.count) other-source records within 60 seconds. Possible correlation only; timing is not proof of the same action.").font(.caption).foregroundStyle(.orange) }
                            Button("Inspect observed history") {
                                model.run {
                                    guard let database = model.database else { throw MonitorError.database("The local database is not open.") }
                                    let records = try await database.snapshotRecords(event.fileID)
                                    guard !records.isEmpty else { throw MonitorError.invalid("No local snapshots were recorded for this item. Activity may predate the metadata index.") }
                                    raw = EvidenceText(text: try encoded(records))
                                }
                            }.accessibilityIdentifier("inspectObservedHistory")
                            Button("Inspect raw evidence") { raw = EvidenceText(text: event.raw) }.accessibilityIdentifier("inspectActivityEvidence")
                        }.padding(22)
                    }.frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
            }
        }.sheet(item: $raw) { RawEvidenceView(text: $0.text) }
    }
    @ViewBuilder private var emptyState: some View {
        if let error = model.activityValidationError {
            ContentUnavailableView {
                Label("Correct the activity dates", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("Reset filters", action: resetFilters).accessibilityIdentifier("resetInvalidActivity")
            }.accessibilityElement(children: .contain).accessibilityIdentifier("activityInvalidDates")
        } else if model.events.isEmpty {
            ContentUnavailableView("No activity records loaded", systemImage: "doc.badge.clock", description: Text("Synchronize your Drive index and review any coverage gaps. This view contains only loaded source records; Google may not expose every action."))
                .accessibilityIdentifier("activityNoRecords")
        } else {
            ContentUnavailableView {
                Label("No activity matches these filters", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Try another actor, action, file or date range, or reset the filters to see all loaded records.")
            } actions: {
                Button("Reset filters", action: resetFilters).accessibilityIdentifier("resetEmptyActivity")
            }.accessibilityElement(children: .contain).accessibilityIdentifier("activityNoMatches")
        }
    }
    private func resetFilters() {
        model.resetActivityFilters()
        selected = nil
    }
    private func detail(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
}
func eventIcon(_ action: String) -> String {
    switch action { case "UPLOADED": "arrow.up.doc"; case "MOVED": "folder.badge.questionmark"; case "RENAMED": "pencil"; case "SHARED", "PERMISSION", "OWNERSHIP": "person.2"; case "TRASHED", "DELETED", "INACCESSIBLE": "trash"; case "RESTORED": "arrow.uturn.backward"; default: "doc.badge.clock" }
}
