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

public struct FolderNode: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let children: [FolderNode]?
}
public struct FileNavigation: Sendable {
    public let index: [String: DriveFile]
    public let locations: [String: String]
    public let roots: [String: [FolderNode]]
}
/// Prepares navigation once per index reload, rather than rescanning every file for each sidebar folder.
public func prepareNavigation(files: [DriveFile], root: DriveFile?, roots: [String]) throws -> FileNavigation {
    var index = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
    if var root { root.parents = []; index[root.id] = root }
    var children: [String: [DriveFile]] = [:]
    for file in files where file.isFolder {
        try Task.checkCancellation()
        for parent in file.parents ?? [] { children[parent, default: []].append(file) }
    }
    func nodes(_ parent: String, visited: Set<String>) throws -> [FolderNode] {
        try Task.checkCancellation()
        return try (children[parent] ?? []).filter { !visited.contains($0.id) }.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.id < rhs.id : lhs.name < rhs.name
        }.map { file in
            let nested = try nodes(file.id, visited: visited.union([file.id]))
            return FolderNode(id: file.id, name: file.name, children: nested.isEmpty ? nil : nested)
        }
    }
    let trees = try Dictionary(uniqueKeysWithValues: Set(roots).map { ($0, try nodes($0, visited: [$0])) })
    let locations = try Dictionary(uniqueKeysWithValues: files.map { file in
        try Task.checkCancellation()
        return (file.id, filePath(file.id, index: index, visited: []))
    })
    return FileNavigation(index: index, locations: locations, roots: trees)
}
