import Foundation

public enum ExportFormat: String, CaseIterable, Sendable { case csv, json, jsonl }
public func exportFiles(_ files: [DriveFile], format: ExportFormat) throws -> Data {
    switch format {
    case .json: return Data(try encoded(files).utf8)
    case .jsonl:
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(try files.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n").appending("\n").utf8)
    case .csv:
        let rows = files.map { [$0.id, $0.name, $0.mimeType, $0.size ?? "", $0.quotaBytesUsed ?? "", $0.createdTime ?? "", $0.modifiedTime ?? "", $0.ownerLabel, ($0.parents ?? []).joined(separator: ";"), $0.driveId ?? "", $0.trashed.map(String.init) ?? ""] }
        let header = ["id", "name", "mimeType", "sizeBytes", "quotaBytesUsed", "createdTime", "modifiedTime", "owners", "parents", "driveId", "trashed"]
        return Data(([header] + rows).map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n").appending("\r\n").utf8)
    }
}

private func csvCell(_ value: String) -> String {
    let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix) ? "'" + value : value
    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
public func exportEvents(_ events: [DriveEvent], format: ExportFormat) throws -> Data {
    switch format {
    case .json: return Data(try encoded(events).utf8)
    case .jsonl:
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n").appending("\n").utf8)
    case .csv:
        let header = ["recordID", "fileID", "name", "action", "actionTime", "detectedTime", "source", "actor", "previousName", "previousParents", "parents", "raw"]
        let rows = events.map { [$0.id, $0.fileID, $0.name, $0.action, $0.time, $0.detected, $0.source.rawValue, $0.actor ?? "", $0.previousName ?? "", $0.previousParents.joined(separator: ";"), $0.parents.joined(separator: ";"), $0.raw] }
        return Data(([header] + rows).map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n").appending("\r\n").utf8)
    }
}
