import SwiftUI
import DriveCore

struct WatchesView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Folder watches").font(.largeTitle.bold())
            Text("Watch a folder from its context menu or its browse view. Rules include indexed descendants and recorded move parents.").foregroundStyle(.secondary)
            if model.watches.isEmpty { ContentUnavailableView("No watched folders", systemImage: "bell.badge", description: Text("Choose a folder in the sidebar, then select Watch folder.")) }
            else {
                List {
                    ForEach(model.watches) { rule in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Label(rule.name, systemImage: "folder").font(.headline); Spacer(); Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { enabled in model.saveWatches(model.watches.map { var value = $0; if value.id == rule.id { value.enabled = enabled }; return value }) })).toggleStyle(.switch).accessibilityLabel("Enable watch for " + rule.name).accessibilityIdentifier("watchEnabled-" + rule.id); Button(role: .destructive) { model.saveWatches(model.watches.filter { $0.id != rule.id }) } label: { Image(systemName: "trash") }.accessibilityLabel("Remove watch for " + rule.name).accessibilityIdentifier("removeWatch-" + rule.id) }
                            HStack {
                                Picker("Actions", selection: Binding(get: { rule.actions.first ?? "" }, set: { action in model.saveWatches(model.watches.map { var value = $0; if value.id == rule.id { value.actions = action.isEmpty ? [] : [action] }; return value }) })) {
                                    Text("All actions").tag(""); ForEach(["UPLOADED", "MOVED", "MODIFIED", "PERMISSION", "SHARED", "TRASHED"], id: \.self) { Text($0.capitalized).tag($0) }
                                }
                                Picker("Batch cooldown", selection: Binding(get: { rule.cooldown }, set: { cooldown in model.saveWatches(model.watches.map { var value = $0; if value.id == rule.id { value.cooldown = cooldown }; return value }) })) { Text("1 minute").tag(60); Text("5 minutes").tag(300); Text("15 minutes").tag(900) }
                            }
                        }.padding(.vertical, 10)
                    }
                }.accessibilityIdentifier("watchesList")
            }
            Text("Notifications summarize new source records after a poll and respect each rule’s cooldown. The app must be running. No upload queue or transfer progress is exposed.").font(.caption).foregroundStyle(.secondary)
        }.padding(26)
    }
}
