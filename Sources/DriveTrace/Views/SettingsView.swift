import SwiftUI
import DriveCore

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
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
                LabeledContent("Desktop client", value: model.hasClient ? "Saved in Keychain" : "Not imported")
                LabeledContent("Sign-in", value: model.connected ? "Saved · verify access with a sync" : "Not signed in")
                Text("Follow five steps to set up your Google project, import a Desktop client, sign in and verify synchronization.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Connect Google Drive…") { openWindow(id: "setup") }.accessibilityIdentifier("openConnectionGuide")
                    if model.connected { Button("Disconnect", action: model.disconnect).disabled(model.busy).accessibilityIdentifier("disconnectGoogle") }
                }
            }
            Section("Monitoring") {
                Toggle("Poll Drive every 60 seconds while the app is running", isOn: Binding(get: { model.autoRefresh }, set: model.setPolling)).disabled(!model.connected || model.isDemo).accessibilityIdentifier("automaticPolling")
                Toggle("Native watch notifications", isOn: Binding(get: { model.notifications }, set: { if $0 { model.requestNotifications() } else { model.notifications = false } })).disabled(model.busy).accessibilityIdentifier("watchNotifications")
                LabeledContent("macOS permission", value: model.notificationStatusText).accessibilityIdentifier("notificationPermissionStatus")
                HStack {
                    Button("Test notification", action: model.testNotification).disabled(model.busy).accessibilityIdentifier("testNotification")
                    Button("Check permission") { Task { await model.refreshNotificationStatus() } }.accessibilityIdentifier("checkNotificationPermission")
                }
                Text("Test delivery without Google. To change permission, open System Settings → Notifications → DriveTrace. Focus or disabled alerts can prevent banners.").font(.caption).foregroundStyle(.secondary)
                if let notice = model.notificationTestNotice { Text(notice).font(.caption).textSelection(.enabled).accessibilityIdentifier("notificationTestResult") }
                Text("The first Activity poll requests the previous seven days under My Drive and each observed Shared Drive. Further polls overlap by five minutes. Shared-with-me items outside those ancestors may lack Activity evidence; metadata Changes still cover accessible items.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Local data") {
                HStack { Button(model.isDemo ? "Leave demo workspace" : "Explore demo workspace", action: model.toggleDemo).accessibilityIdentifier("toggleDemo"); Spacer(); Button("Clear local history…") { confirmHistory = true }; Button("Rebuild local index…") { confirmCache = true } }.disabled(model.busy)
                Text("Demo and account data use separate local databases. Disconnect deletes OAuth tokens but retains cached metadata. Rebuild clears indexed files, cursors and history; the next refresh creates a new baseline. Data is not encrypted by this app; use macOS FileVault for disk protection.").font(.caption).foregroundStyle(.secondary)
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.progress); Spacer(); Button("Cancel", action: model.cancel) } }
        }.formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding().background(.regularMaterial)
                    .accessibilityIdentifier("settingsError")
            }
        }
        .task { await model.refreshNotificationStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshNotificationStatus() } }
        }
        .confirmationDialog("Clear recorded history?", isPresented: $confirmHistory) { Button("Clear history", role: .destructive, action: model.clearHistory) } message: { Text("Deletes local events and snapshots in the current workspace. Files in Google Drive are unaffected.") }
        .confirmationDialog("Rebuild this workspace’s index?", isPresented: $confirmCache) { Button("Clear index", role: .destructive, action: model.clearCache) } message: { Text("Deletes cached files, events, snapshots and sync cursors. The next refresh scans again.") }
    }
}
