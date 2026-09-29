import Foundation

public struct Breadcrumb: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let folderID: String?
}

/// Resolves a first-parent trail without inventing ancestors; unknowns and cycles remain visible.
public func folderTrail(_ id: String, index: [String: DriveFile], roots: [String: String]) -> [Breadcrumb] {
    var trail: [Breadcrumb] = []
    var visited: Set<String> = []
    var current: String = id
    while true {
        guard visited.insert(current).inserted else {
            trail.append(Breadcrumb(id: "cycle:" + current, label: "Cycle: " + current, folderID: nil)); break
        }
        if let name = roots[current] {
            trail.append(Breadcrumb(id: current, label: name, folderID: current)); break
        }
        guard let file = index[current] else {
            trail.append(Breadcrumb(id: "missing:" + current, label: "Unobserved parent: " + current, folderID: nil)); break
        }
        trail.append(Breadcrumb(id: file.id, label: file.name, folderID: file.isFolder ? file.id : nil))
        guard let parents = file.parents else {
            trail.append(Breadcrumb(id: "unknown:" + current, label: "Parent unavailable", folderID: nil)); break
        }
        if parents.count > 1 {
            trail.append(Breadcrumb(id: "multiple:" + current, label: "Multiple parents; first shown", folderID: nil))
        }
        guard let parent = parents.first else { break }
        current = parent
    }
    return trail.reversed()
}

public struct ObservedFile: Identifiable, Codable, Sendable {
    public var id: String { file.id }
    public let observedAt: String
    public let file: DriveFile
    public init(observedAt: String, file: DriveFile) { self.observedAt = observedAt; self.file = file }
}
