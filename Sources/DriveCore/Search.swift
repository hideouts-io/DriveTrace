import Foundation

public enum FileOrder: String, CaseIterable, Codable, Sendable {
    case name, size, quota, created, modified, discovered, activity, activityCount, type, owner, location
}
public struct FileFilter: Codable, Equatable, Sendable {
    public var text: String = ""
    public var fileID: String = ""
    public var mime: String = ""
    public var ext: String = ""
    public var owner: String = ""
    public var parent: String = ""
    public var drive: String = ""
    public var minimumBytes: Int64?
    public var maximumBytes: Int64?
    public var createdAfter: String = ""
    public var createdBefore: String = ""
    public var modifiedAfter: String = ""
    public var modifiedBefore: String = ""
    public var discoveredAfter: String = ""
    public var discoveredBefore: String = ""
    public var trash: String = "active"
    public init() {}
}
public struct SavedSearch: Codable, Identifiable, Sendable {
    public let id: String; public let name: String; public let filter: FileFilter
    public init(id: String, name: String, filter: FileFilter) { self.id = id; self.name = name; self.filter = filter }
}
public struct FileFacts: Sendable {
    public var locations: [String: String] = [:]
    public let firstSeen: [String: String]
    public let lastActivity: [String: String]
    public let activityCounts: [String: Int]
    public init(firstSeen: [String: String], lastActivity: [String: String], activityCounts: [String: Int]) {
        self.firstSeen = firstSeen; self.lastActivity = lastActivity; self.activityCounts = activityCounts
    }
}
public func matches(_ file: DriveFile, filter: FileFilter) -> Bool {
    let checks: [Bool] = [
        filter.text.isEmpty || file.name.localizedStandardContains(filter.text),
        filter.fileID.isEmpty || file.id == filter.fileID,
        filter.mime.isEmpty || file.mimeType.localizedCaseInsensitiveContains(filter.mime),
        filter.ext.isEmpty || (file.fileExtension ?? (file.name as NSString).pathExtension).lowercased() == filter.ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
        filter.owner.isEmpty || file.ownerLabel.localizedCaseInsensitiveContains(filter.owner) || (file.owners ?? []).contains { ($0.emailAddress ?? "").localizedCaseInsensitiveContains(filter.owner) },
        filter.parent.isEmpty || (file.parents ?? []).contains(filter.parent),
        filter.drive.isEmpty || file.driveId == filter.drive,
        filter.minimumBytes == nil || (file.bytes.map { $0 >= filter.minimumBytes! } ?? false),
        filter.maximumBytes == nil || (file.bytes.map { $0 <= filter.maximumBytes! } ?? false),
        filter.trash == "any" || (filter.trash == "trash" ? file.trashed == true : file.trashed != true),
        within(file.createdTime, after: filter.createdAfter, before: filter.createdBefore),
        within(file.modifiedTime, after: filter.modifiedAfter, before: filter.modifiedBefore)
    ]
    return checks.allSatisfy { $0 }
}
public func within(_ value: String?, after: String, before: String) -> Bool {
    if after.isEmpty && before.isEmpty { return true }
    guard let date = parseDate(value) else { return false }
    if !after.isEmpty { guard let lower = parseDate(after), date >= lower else { return false } }
    if !before.isEmpty { guard let upper = parseDate(before), date <= upper else { return false } }
    return true
}
public func orderedFiles(_ files: [DriveFile], order: FileOrder, ascending: Bool, facts: FileFacts) throws -> [DriveFile] {
    try Task.checkCancellation()
    let index = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
    func key(_ file: DriveFile) -> String? {
        switch order {
        case .name: file.name.lowercased()
        case .created: file.createdTime
        case .modified: file.modifiedTime
        case .discovered: facts.firstSeen[file.id]
        case .activity: facts.lastActivity[file.id]
        case .type: file.mimeType
        case .owner: file.owners == nil ? nil : file.ownerLabel.lowercased()
        case .location: facts.locations[file.id] ?? filePath(file.id, index: index, visited: [])
        default: nil
        }
    }
    let dateOrder = [.created, .modified, .discovered, .activity].contains(order)
    var dateKeys: [String: Date] = [:]
    var keys: [String: String] = [:]
    for file in files {
        try Task.checkCancellation()
        if dateOrder { dateKeys[file.id] = parseDate(key(file)) }
        else { keys[file.id] = key(file) }
    }
    return try files.sorted { lhs, rhs in
        try Task.checkCancellation()
        let comparison: ComparisonResult
        if dateOrder {
            let a = dateKeys[lhs.id], b = dateKeys[rhs.id]
            if a == nil && b != nil { return false }; if a != nil && b == nil { return true }
            comparison = a == b ? .orderedSame : (a ?? .distantPast) < (b ?? .distantPast) ? .orderedAscending : .orderedDescending
        } else if order == .size || order == .quota || order == .activityCount {
            let a: Int64? = order == .size ? lhs.bytes : order == .quota ? lhs.quotaBytes : Int64(facts.activityCounts[lhs.id] ?? 0)
            let b: Int64? = order == .size ? rhs.bytes : order == .quota ? rhs.quotaBytes : Int64(facts.activityCounts[rhs.id] ?? 0)
            if a == nil && b != nil { return false }; if a != nil && b == nil { return true }
            comparison = a == b ? .orderedSame : (a ?? 0) < (b ?? 0) ? .orderedAscending : .orderedDescending
        } else {
            let a = keys[lhs.id] ?? nil, b = keys[rhs.id] ?? nil
            if a == nil && b != nil { return false }; if a != nil && b == nil { return true }
            comparison = (a ?? "").localizedStandardCompare(b ?? "")
        }
        if comparison == .orderedSame {
            let names = lhs.name.localizedStandardCompare(rhs.name)
            return names == .orderedSame ? lhs.id < rhs.id : names == .orderedAscending
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
}
public func serverQuery(_ filter: FileFilter) throws -> String {
    try validateFilter(filter)
    guard filter.minimumBytes == nil, filter.maximumBytes == nil, filter.ext.isEmpty, filter.fileID.isEmpty, filter.discoveredAfter.isEmpty, filter.discoveredBefore.isEmpty else {
        throw MonitorError.invalid("Google query does not support this size, extension or file-ID filter. Use Local index, or open a file by ID.")
    }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
    var parts: [String] = []
    if !filter.text.isEmpty { parts.append("name contains \(quote(filter.text))") }
    if !filter.mime.isEmpty { parts.append("mimeType = \(quote(filter.mime))") }
    if !filter.owner.isEmpty { parts.append("\(quote(filter.owner)) in owners") }
    if !filter.parent.isEmpty { parts.append("\(quote(filter.parent)) in parents") }
    if filter.trash != "any" { parts.append("trashed = \(filter.trash == "trash" ? "true" : "false")") }
    for (field, op, value) in [("createdTime", ">=", filter.createdAfter), ("createdTime", "<=", filter.createdBefore), ("modifiedTime", ">=", filter.modifiedAfter), ("modifiedTime", "<=", filter.modifiedBefore)] where !value.isEmpty {
        guard parseDate(value) != nil else { throw MonitorError.invalid("Enter \(field) as a complete RFC3339 timestamp, such as 2026-09-01T00:00:00Z.") }
        parts.append("\(field) \(op) \(quote(value))")
    }
    return parts.joined(separator: " and ")
}
public func byteLabel(_ bytes: Int64?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown" }
