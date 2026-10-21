import SwiftUI
import AppKit

/// Use the button's own window so a nested report-copy sheet belongs to the results, not an unrelated key window.
struct ReportCopyButton: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let enabled: Bool
    let action: @MainActor (NSWindow?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Save Report Copy…", target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.bezelStyle = bezelStyle
        button.setAccessibilityIdentifier("saveBatchReportCopy")
        button.isEnabled = enabled
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.bezelStyle = bezelStyle
        button.isEnabled = enabled; context.coordinator.action = action
    }
    /// Match the SwiftUI action styles while retaining the sender's window for the nested save sheet.
    private var bezelStyle: NSButton.BezelStyle {
        if #available(macOS 26, *), !reduceTransparency, contrast != .increased { return .glass }
        return .rounded
    }
    @MainActor final class Coordinator: NSObject {
        var action: @MainActor (NSWindow?) -> Void
        init(action: @escaping @MainActor (NSWindow?) -> Void) { self.action = action }
        @objc func open(_ sender: NSButton) { action(sender.window) }
    }
}
