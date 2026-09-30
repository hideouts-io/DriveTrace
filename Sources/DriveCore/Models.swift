import Foundation

public struct DriveFile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let mimeType: String
    public var parents: [String]?
    public var driveId: String?
    public var size: String?
    public var quotaBytesUsed: String?
    public var createdTime: String?
    public var modifiedTime: String?
    public var sharedWithMeTime: String?
    public var trashed: Bool?
    public var shared: Bool?
    public var owners: [Person]?
    public var webViewLink: String?
    public var md5Checksum: String?
    public var sha1Checksum: String?
    public var sha256Checksum: String?
    public var fileExtension: String?
    public var shortcutDetails: Shortcut?
    public var permissions: [Permission]?
    public var ownedByMe: Bool?
    public var capabilities: FileCapabilities?
    public init(id: String, name: String, mimeType: String) {
        self.id = id; self.name = name; self.mimeType = mimeType
    }
    public var bytes: Int64? { size.flatMap(Int64.init) }
    public var quotaBytes: Int64? { quotaBytesUsed.flatMap(Int64.init) }
    public var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    public var ownerLabel: String { owners?.compactMap { $0.displayName ?? $0.emailAddress }.joined(separator: ", ") ?? "Unavailable" }
    public var typeLabel: String {
        if isFolder { return "Folder" }
        return mimeType.replacingOccurrences(of: "application/vnd.google-apps.", with: "Google ")
    }
}
public struct FileCapabilities: Codable, Hashable, Sendable {
    public let canDownload: Bool?
    public let canTrash: Bool?
}
public struct Person: Codable, Hashable, Sendable {
    public let displayName: String?
    public let emailAddress: String?
    public let permissionId: String?
    public init(displayName: String?, emailAddress: String?, permissionId: String?) {
        self.displayName = displayName; self.emailAddress = emailAddress; self.permissionId = permissionId
    }
}
public struct Shortcut: Codable, Hashable, Sendable { public let targetId: String; public let targetMimeType: String? }
public struct Permission: Codable, Hashable, Sendable {
    public let id: String; public let type: String; public let role: String
    public let emailAddress: String?; public let domain: String?; public let allowFileDiscovery: Bool?
}
public struct SharedDrive: Codable, Identifiable, Hashable, Sendable { public let id: String; public let name: String }
public struct FilePage: Decodable, Sendable { public let files: [DriveFile]?; public let nextPageToken: String?; public let incompleteSearch: Bool? }
public struct StartPage: Decodable, Sendable { public let startPageToken: String }
public struct Change: Codable, Sendable {
    public let changeType: String; public let time: String; public let fileId: String?
    public let removed: Bool?; public let file: DriveFile?; public let driveId: String?
    public init(changeType: String, time: String, fileId: String?, removed: Bool?, file: DriveFile?, driveId: String?) {
        self.changeType = changeType; self.time = time; self.fileId = fileId
        self.removed = removed; self.file = file; self.driveId = driveId
    }
}
public struct ChangePage: Codable, Sendable {
    public let changes: [Change]?; public let nextPageToken: String?; public let newStartPageToken: String?
    public init(changes: [Change]?, nextPageToken: String?, newStartPageToken: String?) {
        self.changes = changes; self.nextPageToken = nextPageToken; self.newStartPageToken = newStartPageToken
    }
}
public enum EvidenceSource: String, Codable, Sendable { case changes, activity, demo }
public struct DriveEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: String; public let fileID: String; public let name: String; public let action: String
    public let time: String; public let detected: String; public let source: EvidenceSource
    public let actor: String?; public let parents: [String]; public let previousParents: [String]
    public let previousName: String?; public let raw: String
    public init(id: String, fileID: String, name: String, action: String, time: String,
                detected: String, source: EvidenceSource, actor: String?, parents: [String],
                previousParents: [String], previousName: String?, raw: String) {
        self.id = id; self.fileID = fileID; self.name = name; self.action = action; self.time = time
        self.detected = detected; self.source = source; self.actor = actor; self.parents = parents
        self.previousParents = previousParents; self.previousName = previousName; self.raw = raw
    }
    public var explanation: String {
        switch source {
        case .demo: "Simulated evidence. No Google account used."
        case .activity: "Direct Google Activity action. Actor availability is determined by Google."
        case .changes: "Metadata transition. Actor unknown; removal can mean deletion or lost access."
        }
    }
}
public struct WatchRule: Codable, Identifiable, Sendable {
    public let id: String; public var name: String; public var actions: [String]
    public var enabled: Bool; public var cooldown: Int
    public init(id: String, name: String, actions: [String], enabled: Bool, cooldown: Int) {
        self.id = id; self.name = name; self.actions = actions; self.enabled = enabled; self.cooldown = cooldown
    }
}
public enum MonitorError: Error, LocalizedError, Sendable {
    case invalid(String), database(String), http(Int, String), authentication(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let text), .database(let text), .authentication(let text): text
        case .http(410, let endpoint): "Google rejected the saved cursor (HTTP 410): \(endpoint). Use Settings → Rebuild local index, then refresh to create a new baseline."
        case .http(let code, let endpoint): "Google request failed (HTTP \(code)): \(endpoint). Check access, API enablement and quota."
        }
    }
}
public func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}
public func parseDate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    return (try? fractional.parse(text)) ?? (try? whole.parse(text))
}
public func encoded<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Checks semantic fields that Codable alone cannot validate; absent optional metadata stays absent.
public func validateFile(_ file: DriveFile) throws {
    guard !file.id.isEmpty, !file.mimeType.isEmpty else { throw MonitorError.invalid("Google file metadata requires a nonempty ID and MIME type.") }
    for (field, value) in [("size", file.size), ("quotaBytesUsed", file.quotaBytesUsed)] {
        if let value { guard let bytes = Int64(value), bytes >= 0 else { throw MonitorError.invalid("File \(file.id) has an invalid \(field): \(value).") } }
    }
    for (field, value) in [("createdTime", file.createdTime), ("modifiedTime", file.modifiedTime)] {
        if let value, parseDate(value) == nil { throw MonitorError.invalid("File \(file.id) has an invalid \(field): \(value).") }
    }
}

public struct SnapshotRecord: Codable, Identifiable, Sendable {
    public var id: String { observedAt }
    public let observedAt: String
    public let file: DriveFile
    public let reconstructedPath: String
    public let provenance: String
    public init(observedAt: String, file: DriveFile, reconstructedPath: String, provenance: String) {
        self.observedAt = observedAt; self.file = file; self.reconstructedPath = reconstructedPath; self.provenance = provenance
    }
}
