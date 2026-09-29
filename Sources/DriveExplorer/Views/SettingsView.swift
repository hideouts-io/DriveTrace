import SwiftUI
import DriveCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmCache = false
    @State private var confirmHistory = false
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }.pickerStyle(.segmented).accessibilityIdentifier("appearancePicker")
            }
            Section("Google account") {
                LabeledContent("Connection", value: model.connected ? "Connected · read-only scopes" : "Not connected")
                Text("Create a Desktop app OAuth client in Google Cloud. Enable Google Drive API and Google Drive Activity API, then import its JSON file. Your browser handles sign-in; tokens stay in macOS Keychain.").font(.callout).foregroundStyle(.secondary)
                HStack { Button("Import Desktop client JSON…", action: model.importClient).accessibilityIdentifier("importOAuth"); Button("Connect Google account", action: model.connect).accessibilityIdentifier("connectGoogle"); if model.connected { Button("Disconnect", action: model.disconnect).accessibilityIdentifier("disconnectGoogle") } }.disabled(model.busy)
                Link("Google native-app OAuth setup", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
            }
            Section("Monitoring") {
                Toggle("Poll Drive every 60 seconds while the app is running", isOn: Binding(get: { model.autoRefresh }, set: model.setPolling)).disabled(!model.connected || model.isDemo).accessibilityIdentifier("automaticPolling")
                Toggle("Native watch notifications", isOn: Binding(get: { model.notifications }, set: { if $0 { model.requestNotifications() } else { model.notifications = false } })).accessibilityIdentifier("watchNotifications")
                Text("The first Activity poll requests the previous seven days under My Drive and each accessible Shared Drive. Further polls overlap by five minutes. Shared-with-me items outside those ancestors may lack Activity evidence; metadata Changes still cover accessible items.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local data") {
                HStack { Button(model.isDemo ? "Leave demo workspace" : "Explore demo workspace", action: model.toggleDemo).accessibilityIdentifier("toggleDemo"); Spacer(); Button("Clear local history…") { confirmHistory = true }; Button("Rebuild local index…") { confirmCache = true } }.disabled(model.busy)
                Text("Demo and account data use separate local databases. Disconnect deletes OAuth tokens but retains cached metadata. Rebuild clears indexed files, cursors and history; the next refresh creates a new baseline. Data is not encrypted by this app; use macOS FileVault for disk protection.").font(.caption).foregroundStyle(.secondary)
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.progress); Spacer(); Button("Cancel", action: model.cancel) } }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.formStyle(.grouped)
        .confirmationDialog("Clear recorded history?", isPresented: $confirmHistory) { Button("Clear history", role: .destructive, action: model.clearHistory) } message: { Text("Deletes local events and snapshots in the current workspace. Files in Google Drive are unaffected.") }
        .confirmationDialog("Rebuild this workspace’s index?", isPresented: $confirmCache) { Button("Clear index", role: .destructive, action: model.clearCache) } message: { Text("Deletes cached files, events, snapshots and sync cursors. The next refresh scans again.") }
    }
}
