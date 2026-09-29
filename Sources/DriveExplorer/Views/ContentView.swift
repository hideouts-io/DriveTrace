import SwiftUI
import AppKit
import DriveCore

struct ContentView: View {
    @Bindable var model: AppModel
    var body: some View {
        NavigationSplitView {
            SidebarView(model: model).navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 330)
        } detail: {
            VStack(spacing: 0) {
                if model.isDemo {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(.orange)
                        Text("Demo workspace").fontWeight(.semibold)
                        Text("Synthetic files and activity • no Google account used").foregroundStyle(.secondary)
                        Spacer()
                        Button("Leave demo", action: model.toggleDemo).buttonStyle(.link).disabled(model.busy).accessibilityIdentifier("leaveDemo")
                    }.font(.caption).padding(.horizontal, 22).padding(.vertical, 9).background(.orange.opacity(0.08))
                    Divider()
                }
                if !model.ready { ProgressView("Opening your workspace…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if model.files.isEmpty && !model.isDemo && !model.connected { WelcomeView(model: model) }
                else {
                    switch model.selection {
                    case "activity": ActivityView(model: model)
                    case "history": HistoryView(model: model).id(model.database.map { ObjectIdentifier($0) })
                    case "storage": StorageView(model: model)
                    case "watches": WatchesView(model: model)
                    default: ExplorerView(model: model)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Circle().fill(model.isDemo ? .orange : model.gaps.isEmpty ? .green : .orange).frame(width: 6, height: 6)
                    Text(model.busy ? model.progress : model.isDemo ? "Demo data · local SQLite" : model.lastSync.map { "Last complete poll \(displayDate($0))" } ?? "Index not yet synchronized")
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small); Button("Cancel", action: model.cancel).accessibilityIdentifier("cancelOperation") }
                    Text(model.autoRefresh ? "Polling every 60 seconds" : "Manual refresh").foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
            }
            .navigationTitle(model.title)
            .toolbar {
                ToolbarItemGroup {
                    Button(action: model.sync) { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.busy || (!model.connected && !model.isDemo)).accessibilityIdentifier("refreshDrive")
                    Button { model.showFilters.toggle() } label: { Label("Filters", systemImage: "line.3.horizontal.decrease.circle") }.accessibilityIdentifier("showFilters")
                    Menu { ForEach(ExportFormat.allCases, id: \.self) { format in Button(format.rawValue.uppercased()) { model.export(format) } } } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(model.selection == "history" || (model.selection == "activity" ? model.filteredEvents.isEmpty : model.results.isEmpty)).accessibilityIdentifier("exportFiles")
                    Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }.accessibilityIdentifier("showInspector")
                }
            }
        }
        .alert("Action couldn’t finish", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .onChange(of: model.selection) { _, _ in model.updateResults() }
        .onChange(of: model.filter) { _, _ in model.serverResults = nil; model.updateResults() }
        .onChange(of: model.order) { _, _ in model.updateResults() }
        .onChange(of: model.ascending) { _, _ in model.updateResults() }
    }
}
struct WelcomeView: View {
    @Bindable var model: AppModel
    private static let logo: NSImage = {
        guard let url = Bundle.module.url(forResource: "drive-explorer-logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { preconditionFailure("Drive Explorer logo is missing or unreadable. Rebuild with script/build_and_run.sh to package its resources.") }
        return image
    }()
    var body: some View {
        VStack(spacing: 24) {
            Image(nsImage: Self.logo).resizable().scaledToFit().frame(width: 160, height: 160).accessibilityLabel("Drive Explorer logo")
            VStack(spacing: 8) {
                Text("A clearer view of your Drive").font(.largeTitle.bold())
                Text("Find the newest and largest files. Explore folders.\nUnderstand who changed what, with the evidence beside it.").multilineTextAlignment(.center).foregroundStyle(.secondary).font(.title3)
            }
            HStack(spacing: 14) {
                Button("Explore demo", action: model.toggleDemo).buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("startDemo")
                SettingsLink { Text("Connect Google Drive…") }.controlSize(.large).accessibilityIdentifier("openSettings")
            }
            HStack(spacing: 28) { Label("Read-only access", systemImage: "lock.shield"); Label("Stored on your Mac", systemImage: "internaldrive"); Label("No telemetry", systemImage: "hand.raised") }.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }
}
func displayDate(_ value: String?) -> String { parseDate(value).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unavailable" }
