import SwiftUI
import DriveCore

struct HistoryView: View {
    @Bindable var model: AppModel
    @State private var cutoff = timestamp(Date())
    @State private var loadedCutoff: String?
    @State private var observations: [ObservedFile] = []
    @State private var folder: String?
    @State private var selected: String?
    @State private var query = ""
    @State private var request = UUID()
    @State private var loading = false
    @State private var failure: String?
    @State private var raw: EvidenceText?
    private var index: [String: DriveFile] { Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0.file) }) }
    private var rows: [ObservedFile] {
        observations.filter { row in
            (folder == nil || (row.file.parents ?? []).contains(folder!)) &&
            (query.isEmpty || row.file.name.localizedStandardContains(query) || row.id == query)
        }.sorted { lhs, rhs in
            if lhs.file.isFolder != rhs.file.isFolder { return lhs.file.isFolder }
            let names = lhs.file.name.localizedStandardCompare(rhs.file.name)
            return names == .orderedSame ? lhs.id < rhs.id : names == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Observed history").font(.largeTitle.bold())
                Text("Browse the last recorded metadata at or before a local observation cutoff. Removed or inaccessible items can remain here; this is not proof of historical access or continuous coverage.").foregroundStyle(.secondary)
                HStack {
                    TextField("Observation cutoff · RFC3339", text: $cutoff).textFieldStyle(.roundedBorder).accessibilityIdentifier("historyCutoff")
                        .onSubmit { request = UUID() }
                    Button("Load history") { request = UUID() }.accessibilityIdentifier("loadHistory")
                    Button("Now") { cutoff = timestamp(Date()); request = UUID() }.accessibilityIdentifier("historyNow")
                    if loading { ProgressView().controlSize(.small) }
                }
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("historyError") }
                if let loadedCutoff {
                    Text("Loaded cutoff: \(loadedCutoff) · \(observations.count) observed items · current metadata is not substituted").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("historyCoverage")
                }
                HStack {
                    Button("All observed items") { folder = nil; selected = nil; query = "" }.accessibilityIdentifier("historyAll")
                    if let folder {
                        BreadcrumbView(components: folderTrail(folder, index: index, roots: [model.rootID: "My Drive"]), current: folder, navigate: browse)
                    }
                    Spacer()
                    TextField("Search this level by name or ID", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320).accessibilityIdentifier("historySearch")
                }
            }.padding(22)
            Divider()
            HSplitView {
                Table(rows, selection: $selected) {
                    TableColumn("Name") { row in Label(row.file.name, systemImage: fileIcon(row.file)) }.width(min: 180, ideal: 270)
                    TableColumn("Last observed") { Text(displayDate($0.observedAt)) }.width(min: 150, ideal: 180)
                    TableColumn("Size") { Text(byteLabel($0.file.bytes)) }.width(min: 75, ideal: 90)
                    TableColumn("Recorded state") { Text($0.file.trashed == true ? "Trashed" : $0.file.trashed == false ? "Not trashed" : "Unknown") }.width(min: 100, ideal: 120)
                }.accessibilityIdentifier("historyTable")
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, index[id]?.isFolder == true { Button("Browse observed folder") { browse(id) } }
                } primaryAction: { ids in if let id = ids.first, index[id]?.isFolder == true { browse(id) } }
                .overlay {
                    if !loading && rows.isEmpty {
                        ContentUnavailableView("No observations at this level", systemImage: "clock.arrow.circlepath", description: Text("Try another cutoff, clear the search, or return to All observed items. Absence here does not establish that an item did not exist."))
                    }
                }
                if let row = observations.first(where: { $0.id == selected }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(row.file.name).font(.title2.bold()).textSelection(.enabled)
                            Text("Last observed: " + displayDate(row.observedAt)).font(.caption).foregroundStyle(.secondary)
                            Text(folderTrail(row.id, index: index, roots: [model.rootID: "My Drive"]).map(\.label).joined(separator: " / ")).textSelection(.enabled)
                            Text("Current existence and accessibility are unknown. Ancestor names come only from observations at this cutoff; different items may have been observed at different times.").font(.caption).foregroundStyle(.secondary)
                            if row.file.isFolder { Button("Browse observed folder") { browse(row.id) }.accessibilityIdentifier("browseHistoryFolder") }
                            Button("Inspect observation") {
                                do { raw = EvidenceText(text: try encoded(row)) } catch { failure = error.localizedDescription }
                            }.accessibilityIdentifier("inspectHistoryObservation")
                        }.padding(22)
                    }.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                }
            }.disabled(loading)
        }
        .task(id: request) { await load() }
        .sheet(item: $raw) { RawEvidenceView(text: $0.text) }
    }
    private func browse(_ id: String) { folder = id; selected = nil; query = "" }
    private func load() async {
        let requestedCutoff = cutoff
        loading = true; failure = nil; loadedCutoff = nil; observations = []; folder = nil; selected = nil
        do {
            guard let database = model.database else { throw MonitorError.database("The local database is not open.") }
            let records = try await database.observedFiles(at: requestedCutoff)
            try Task.checkCancellation()
            observations = records; loadedCutoff = requestedCutoff; loading = false
        } catch is CancellationError {
            // A replacement request or leaving this view cancels its result publication.
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription; loading = false
        }
    }
}
