import Foundation

/// Exact storage membership, independent of duplicate folder or drive display names.
public enum StorageScope: Codable, Hashable, Sendable {
    case mimeFamily(String)
    case workspace
    case parent(String?)
    case drive(String?)

    public var key: String {
        switch self {
        case .mimeFamily(let type): "type:" + type
        case .workspace: "workspace"
        case .parent(let id): id.map { "parent:" + $0 } ?? "parent-missing"
        case .drive(let id): id.map { "drive:" + $0 } ?? "drive-personal"
        }
    }
}

public func storageType(_ file: DriveFile) -> StorageScope {
    let mime = file.mimeType.lowercased()
    return mime.hasPrefix("application/vnd.google-apps.") ? .workspace : .mimeFamily(String(mime.split(separator: "/", omittingEmptySubsequences: false)[0]))
}

public func matchesStorage(_ file: DriveFile, scope: StorageScope) -> Bool {
    guard !file.isFolder, file.trashed != true else { return false }
    switch scope {
    case .mimeFamily, .workspace: return storageType(file) == scope
    case .parent(let id): return file.parents?.first == id
    case .drive(let id): return file.driveId == id
    }
}
