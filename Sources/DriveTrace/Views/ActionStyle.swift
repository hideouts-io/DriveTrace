import SwiftUI

/// Delegate interaction, focus and disabled rendering to native styles; retain opaque controls when requested.
private struct GlassActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct PrimaryActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// Related actions share one sampling region without painting a second glass surface behind native buttons.
private struct ActionGroupModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

extension View {
    func driveGlassAction() -> some View { modifier(GlassActionModifier()) }
    func drivePrimaryAction() -> some View { modifier(PrimaryActionModifier()) }
    func driveActionGroup() -> some View { modifier(ActionGroupModifier()) }
}
