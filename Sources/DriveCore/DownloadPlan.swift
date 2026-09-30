import Foundation

public struct DownloadItem: Sendable {
    public let file: DriveFile
    public let components: [String]
}
public struct DownloadIssue: Codable, Sendable, Identifiable {
    public let id: UUID
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { id = UUID(); self.path = path; self.reason = reason }
}
public struct DownloadPlan: Sendable {
    public let items: [DownloadItem]
    public let issues: [DownloadIssue]
}
public struct BatchProgress: Sendable {
    public let current: String
    public let discovered: Int
    public let completed: Int
    public let failed: Int
    public init(current: String, discovered: Int, completed: Int, failed: Int) { self.current = current; self.discovered = discovered; self.completed = completed; self.failed = failed }
}

/// Allocate names conservatively for case-insensitive, normalization-insensitive destination volumes.
public func availableDownloadName(_ name: String, occupied: Set<String>) throws -> String {
    let base = try downloadName(name)
    let key: (String) -> String = { $0.precomposedStringWithCanonicalMapping.lowercased() }
    let names = Set(occupied.map(key))
    if !names.contains(key(base)) { return base }
    let suffix = (base as NSString).pathExtension
    let stem = suffix.isEmpty ? base : (base as NSString).deletingPathExtension
    for number in 2...occupied.count + 2 {
        let candidate = "\(stem) (\(number))" + (suffix.isEmpty ? "" : "." + suffix)
        if !names.contains(key(candidate)) { return try downloadName(candidate) }
    }
    throw MonitorError.invalid("Cannot allocate a unique local name for \(name).")
}

extension GoogleClient {
    /// Discover live folder contents with pagination. Cached metadata never establishes a complete folder copy.
    public func planDownloads(ids: [String], progress: @Sendable (BatchProgress) async -> Void) async throws -> DownloadPlan {
        guard !ids.isEmpty else { throw MonitorError.invalid("Select at least one file or folder to download.") }
        var roots: [DriveFile] = []
        var issues: [DownloadIssue] = []
        for id in Set(ids).sorted() {
            do { try Task.checkCancellation(); roots.append(try await file(id: id)) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { issues.append(DownloadIssue(path: id, reason: error.localizedDescription)) }
        }
        roots.sort { $0.isFolder != $1.isFolder ? $0.isFolder : $0.id < $1.id }
        var pending: [(file: DriveFile, parent: [String])] = roots.reversed().map { ($0, []) }
        var visited: Set<String> = []
        var names: [String: Set<String>] = [:]
        var items: [DownloadItem] = []
        while let next = pending.popLast() {
            try Task.checkCancellation()
            let file = next.file
            let display = (next.parent + [file.name]).joined(separator: "/")
            guard visited.insert(file.id).inserted else {
                issues.append(DownloadIssue(path: display, reason: "Already encountered in this selection; copied only once. A repeated folder may also indicate a cycle.")); continue
            }
            do {
                guard file.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw MonitorError.invalid("Google returned an invalid file ID for folder discovery.") }
                guard file.trashed != true else { throw MonitorError.invalid("Restore this trashed item in Google Drive before downloading it in a batch.") }
                guard file.shortcutDetails == nil else { throw MonitorError.invalid("Shortcut skipped. Select its actual target to download it; shortcuts are not followed automatically.") }
                let proposed = try file.isFolder ? downloadName(file.name) : fileDownload(file).name
                let parentKey = next.parent.joined(separator: "/")
                let name = try availableDownloadName(proposed, occupied: names[parentKey] ?? [])
                names[parentKey, default: []].insert(name)
                let components = next.parent + [name]
                items.append(DownloadItem(file: file, components: components))
                await progress(BatchProgress(current: display, discovered: items.count, completed: 0, failed: issues.count))
                if file.isFolder {
                    var children: [DriveFile] = []
                    var page: String?
                    var tokens: Set<String> = []
                    repeat {
                        try Task.checkCancellation()
                        let response = try await files(query: "'\(file.id)' in parents and trashed = false", drive: file.driveId, page: page)
                        guard response.incompleteSearch != true else { throw MonitorError.invalid("Google reported an incomplete folder listing. This folder has not been fully discovered.") }
                        children += response.files ?? []
                        page = response.nextPageToken
                        if let page, !tokens.insert(page).inserted { throw MonitorError.invalid("Google repeated a folder page token. Folder discovery stopped to avoid an infinite loop.") }
                    } while page != nil
                    pending += children.sorted { $0.id < $1.id }.reversed().map { ($0, components) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { issues.append(DownloadIssue(path: display, reason: error.localizedDescription)) }
        }
        return DownloadPlan(items: items, issues: issues)
    }
}
