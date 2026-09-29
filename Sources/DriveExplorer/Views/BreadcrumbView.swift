import SwiftUI
import DriveCore

struct BreadcrumbView: View {
    let components: [Breadcrumb]
    let current: String
    let navigate: (String) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(components) { component in
                    if component.id != components.first?.id { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true) }
                    if let id = component.folderID {
                        Button(component.label) { navigate(id) }.buttonStyle(.link).disabled(id == current)
                            .accessibilityLabel("Browse " + component.label).accessibilityIdentifier("breadcrumb-" + id)
                    } else { Text(component.label).foregroundStyle(.secondary) }
                }
            }.lineLimit(1).padding(.vertical, 3)
        }.font(.caption).accessibilityIdentifier("folderBreadcrumbs")
    }
}
