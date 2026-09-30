import Foundation
import DriveCore

struct FilePreview: Identifiable, Sendable {
    let id: UUID
    let name: String
    let url: URL
}

/// App-owned temporary content. Names from Drive never become local paths.
actor PreviewStore {
    private let root: URL
    init(root: URL) { self.root = root }
    func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func remove(_ url: URL) throws {
        guard url.deletingLastPathComponent() == root else { throw MonitorError.invalid("Preview cleanup refused a path outside its temporary directory.") }
        try FileManager.default.removeItem(at: url)
    }
    func save(_ content: PreviewContent, name: String) throws -> FilePreview {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID()
        let url = root.appendingPathComponent(id.uuidString).appendingPathExtension(content.fileExtension)
        try content.data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return FilePreview(id: id, name: name, url: url)
    }
}
