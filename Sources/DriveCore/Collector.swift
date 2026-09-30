import Foundation

public struct SyncProgress: Sendable {
    public let message: String; public let count: Int
    public init(message: String, count: Int) { self.message = message; self.count = count }
}
public struct SyncResult: Sendable { public let drives: [SharedDrive]; public let gaps: [String] }
public func synchronize(client: GoogleClient, database: Database, progress: @Sendable (SyncProgress) async -> Void) async throws -> SyncResult {
    // The Shared Drive directory endpoint requires content-readable OAuth scopes.
    // Discover only drive IDs observed in metadata and retain earlier observations.
    var drives: [SharedDrive] = []
    if let stored = try await database.setting("drives") {
        drives = try JSONDecoder().decode([SharedDrive].self, from: Data(stored.utf8))
    }
    var gaps: [String] = []; var page: String?; var visited: Set<String> = []
    var scopes: [(String, String?)] = [("user", nil)]
    var scopeIndex = 0
    while scopeIndex < scopes.count {
        let (stream, drive) = scopes[scopeIndex]
        scopeIndex += 1
        try Task.checkCancellation()
        do {
            if try await database.cursor(stream) == nil {
                let token = try await client.startToken(drive: drive)
                try await database.beginBaseline(stream: stream)
                var count = 0; page = nil; visited = []
                repeat {
                    try Task.checkCancellation()
                    let response = try await client.files(query: "", drive: drive, page: page)
                    guard response.incompleteSearch != true else { throw MonitorError.invalid("Google marked scope \(stream) incomplete; baseline was not promoted.") }
                    try await database.stage(response.files ?? [], stream: stream)
                    count += response.files?.count ?? 0
                    await progress(SyncProgress(message: "Indexing \(drive == nil ? "My Drive and shared items" : stream)", count: count))
                    page = response.nextPageToken
                    if let page, !visited.insert(page).inserted { throw MonitorError.invalid("File pagination repeated a cursor for \(stream).") }
                } while page != nil
                try await database.promote(stream: stream, cursor: token, detected: timestamp(Date()))
            }
            guard var token = try await database.cursor(stream) else { throw MonitorError.database("Missing cursor after baseline for \(stream).") }
            visited = []
            while true {
                try Task.checkCancellation()
                guard visited.insert(token).inserted else { throw MonitorError.invalid("Changes pagination repeated a cursor for \(stream).") }
                let response = try await client.changes(drive: drive, page: token)
                try await database.apply(response, stream: stream, detected: timestamp(Date()))
                await progress(SyncProgress(message: "Updating changes · \(stream)", count: response.changes?.count ?? 0))
                guard let next = response.nextPageToken else { break }; token = next
            }
        } catch is CancellationError { throw CancellationError() }
        catch { gaps.append("Scope \(stream): \(error.localizedDescription)") }
        if drive == nil {
            let observedIDs = Set(try await database.files().compactMap(\.driveId))
            let knownIDs = Set(drives.map(\.id))
            drives += observedIDs.subtracting(knownIDs).sorted().map { SharedDrive(id: $0, name: "Shared Drive · " + $0) }
            // Persist discoveries before root lookups so failures never erase known scopes.
            try await database.setSetting("drives", value: encoded(drives))
            for index in drives.indices {
                try Task.checkCancellation()
                do {
                    let root = try await client.file(id: drives[index].id)
                    guard root.id == drives[index].id, root.mimeType == "application/vnd.google-apps.folder" else {
                        throw MonitorError.invalid("Shared Drive root metadata did not identify the requested folder.")
                    }
                    drives[index] = SharedDrive(id: root.id, name: root.name)
                } catch is CancellationError { throw CancellationError() }
                catch { gaps.append("Shared Drive root \(drives[index].id): \(error.localizedDescription)") }
            }
            try await database.setSetting("drives", value: encoded(drives))
            scopes += drives.map { ($0.id, Optional($0.id)) }
        }
    }
    for (stream, ancestor) in [("user", "root")] + drives.map({ ($0.id, $0.id) }) {
        do {
            let key = "activity.watermark." + stream
            let previous = try await database.setting(key)
            let since = timestamp((parseDate(previous) ?? Date().addingTimeInterval(-7 * 86400)).addingTimeInterval(-300))
            let watermark = timestamp(Date()); page = nil; visited = []
            repeat {
                try Task.checkCancellation()
                let response = try await client.activity(ancestor: ancestor, since: since, page: page)
                let events = try (response.activities ?? []).flatMap { try normalizeActivity($0, detected: watermark) }
                page = response.nextPageToken
                if let page, !visited.insert(page).inserted { throw MonitorError.invalid("Activity pagination repeated a cursor.") }
                try await database.recordActivity(events, watermark: nil)
                await progress(SyncProgress(message: "Reading Activity evidence · \(stream)", count: events.count))
            } while page != nil
            try await database.setSetting(key, value: watermark)
        } catch is CancellationError { throw CancellationError() }
        catch { gaps.append("Activity \(stream): \(error.localizedDescription)") }
    }
    return SyncResult(drives: drives, gaps: gaps)
}
