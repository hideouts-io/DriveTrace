import SwiftUI
import AppKit

@main struct DriveTraceApp: App {
    @NSApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
    @AppStorage("appearance") private var appearance = "system"
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("DriveTrace", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { await model.start(); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About DriveTrace") { NSApp.orderFrontStandardAboutPanel(options: [:]) }
                    .accessibilityIdentifier("aboutDriveTrace")
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Drive", action: model.sync).keyboardShortcut("r").disabled(model.busy || !model.connected || model.isDemo)
                Button("Cancel Current Operation", action: model.cancel).keyboardShortcut(".").disabled(!model.busy)
            }
            CommandMenu("Explore") {
                Button("All Files") { model.navigate("all") }.keyboardShortcut("1")
                Button("Newest Items") { model.navigate("newest") }.keyboardShortcut("2")
                Button("Largest Files") { model.navigate("largest") }.keyboardShortcut("3")
                Button("Activity") { model.navigate("activity") }.keyboardShortcut("4")
                Button("Storage Overview") { model.navigate("storage") }.keyboardShortcut("5")
                Button("Sharing Audit") { model.navigate("security") }.keyboardShortcut("6")
                Button("My Drive") { model.navigate("my") }.keyboardShortcut("7")
                Button("Folder Watches") { model.navigate("watches") }.keyboardShortcut("8")
                Button("Observed History") { model.navigate("history") }.keyboardShortcut("9")
                Divider()
                Button("Find Files") {
                    if ["activity", "history", "storage", "watches"].contains(model.selection ?? "") { model.navigate("all") }
                    model.focusSearchRequested = true
                }.keyboardShortcut("f")
                Button("Advanced Search") { model.showFilters.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Show Inspector") { model.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Window("Connect Google Drive", id: "setup") {
            SetupView(model: model)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }.defaultSize(width: 880, height: 740)
        Settings { SettingsView(model: model).frame(width: 680, height: 720) }
    }
}
