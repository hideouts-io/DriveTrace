import Foundation
import Testing
import CSQLite
@testable import DriveCore

func temporaryDatabase() throws -> (Database, String) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("drive-test-\(UUID().uuidString).sqlite").path
    return (try Database(path: path), path)
}
func sample(_ id: String, name: String, size: String?) -> DriveFile {
    var file = DriveFile(id: id, name: name, mimeType: "application/pdf")
    file.size = size; file.trashed = false; file.parents = ["root"]; file.createdTime = "2026-09-01T00:00:00Z"; file.modifiedTime = "2026-09-02T00:00:00Z"
    return file
}
@Test func timestampsRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_790_000_000.123)
    let encoded = timestamp(date)
    #expect(encoded.hasSuffix("Z"))
    #expect(abs(try #require(parseDate(encoded)).timeIntervalSince(date)) < 0.002)
    #expect(parseDate("2026-09-01T00:00:00Z") != nil)
}
@Test func baselineIsAtomicAndSurvivesReopen() async throws {
    let (db, path) = try temporaryDatabase()
    try await db.beginBaseline(stream: "user")
    try await db.stage([sample("one", name: "Original", size: "10")], stream: "user")
    #expect(try await db.files().isEmpty)
    #expect(try await db.cursor("user") == nil)
    try await db.promote(stream: "user", cursor: "start", detected: "2026-09-01T00:00:00Z")
    try await db.beginBaseline(stream: "user")
    try await db.stage([sample("two", name: "Unfinished", size: "20")], stream: "user")
    try await db.close()
    let reopened = try Database(path: path)
    #expect(try await reopened.files().map(\.id) == ["one"])
    #expect(try await reopened.cursor("user") == "start")
    try await reopened.beginBaseline(stream: "user")
    try await reopened.stage([sample("three", name: "Complete", size: nil)], stream: "user")
    try await reopened.promote(stream: "user", cursor: "next", detected: "2026-09-02T00:00:00Z")
    #expect(try await reopened.files().map(\.id) == ["three"])
    try await reopened.close()
}
@Test func malformedPageRollsBackChangesAndCursor() async throws {
    let (db, _) = try temporaryDatabase()
    try await db.stage([sample("one", name: "Original", size: "10")], stream: "user")
    try await db.promote(stream: "user", cursor: "start", detected: "2026-09-01T00:00:00Z")
    let valid = Change(changeType: "file", time: "2026-09-02T00:00:00Z", fileId: "one", removed: false, file: sample("one", name: "Renamed", size: "10"), driveId: nil)
    let bad = Change(changeType: "file", time: "2026-09-02T00:00:00Z", fileId: nil, removed: false, file: nil, driveId: nil)
    await #expect(throws: MonitorError.self) { try await db.apply(ChangePage(changes: [valid,bad], nextPageToken: "next", newStartPageToken: nil), stream: "user", detected: "2026-09-02T00:00:00Z") }
    #expect(try await db.file("one")?.name == "Original")
    #expect(try await db.cursor("user") == "start")
    #expect(try await db.events(fileID: nil, limit: 10).isEmpty)
    try await db.apply(ChangePage(changes: [valid], nextPageToken: nil, newStartPageToken: "next"), stream: "user", detected: "2026-09-02T00:00:00Z")
    #expect(try await db.cursor("user") == "next")
    #expect(try await db.history("one").count == 2)
    #expect(try await db.events(fileID: "one", limit: 10).first?.actor == nil)
    try await db.close()
}
@Test func multiScopeMembershipAndRemoval() async throws {
    let (db, _) = try temporaryDatabase()
    for stream in ["user", "shared"] { try await db.stage([sample("one", name: "Shared", size: nil)], stream: stream); try await db.promote(stream: stream, cursor: "start", detected: "2026-09-01T00:00:00Z") }
    let removal = Change(changeType: "file", time: "2026-09-02T00:00:00Z", fileId: "one", removed: true, file: nil, driveId: nil)
    try await db.apply(ChangePage(changes: [removal], nextPageToken: nil, newStartPageToken: "next"), stream: "user", detected: "2026-09-02T00:00:00Z")
    #expect(try await db.file("one") != nil)
    try await db.apply(ChangePage(changes: [removal], nextPageToken: nil, newStartPageToken: "next"), stream: "shared", detected: "2026-09-02T00:00:00Z")
    #expect(try await db.file("one") == nil)
    #expect(try await db.events(fileID: "one", limit: 10).first?.action == "INACCESSIBLE")
    try await db.close()
}
@Test func activityAttributionAndDeduplication() async throws {
    let payload = Data(#"{"actions":[{"detail":{"create":{"upload":{}}},"actor":{"user":{"knownUser":{"personName":"people/123"}}},"target":{"driveItem":{"name":"items/file1","title":"Example"}},"timestamp":"2026-09-01T00:00:00Z"}]}"#.utf8)
    let normalized = try normalizeActivity(JSONDecoder().decode(JSONValue.self, from: payload), detected: "2026-09-02T00:00:00Z")
    #expect(normalized.first?.actor == "people/123"); #expect(normalized.first?.action == "UPLOADED")
    let (db, _) = try temporaryDatabase()
    try await db.recordActivity(normalized, watermark: nil); try await db.recordActivity(normalized, watermark: nil)
    #expect(try await db.events(fileID: nil, limit: 10).count == 1)
    try await db.close()
}
@Test func compoundFiltersAndSortUnknowns() throws {
    var filter = FileFilter(); filter.text = "report"; filter.minimumBytes = 10; filter.maximumBytes = 100; filter.ext = "pdf"; filter.owner = "alex"; filter.createdAfter = "2026-08-01T00:00:00Z"
    var match = sample("1", name: "Report.pdf", size: "20"); match.owners = [Person(displayName: "Alex", emailAddress: nil, permissionId: nil)]
    #expect(matches(match, filter: filter))
    var missing = match; missing.size = nil; #expect(!matches(missing, filter: filter))
    let facts = FileFacts(firstSeen: [:], lastActivity: [:], activityCounts: [:])
    let files = [sample("a", name: "A", size: nil), sample("b", name: "B", size: "0"), sample("c", name: "C", size: "20")]
    #expect(try orderedFiles(files, order: .size, ascending: true, facts: facts).map(\.id) == ["b","c","a"])
    #expect(try orderedFiles(files, order: .size, ascending: false, facts: facts).map(\.id) == ["c","b","a"])
    #expect(throws: MonitorError.self) { try serverQuery(filter) }
    var google = FileFilter(); google.text = "O'Brien\\draft"
    #expect(try serverQuery(google).contains("O\\'Brien\\\\draft"))
}
@Test func exportsRoundTripAndProtectSpreadsheetCells() throws {
    let files = [sample("one", name: "=SUM(1,2)\n\"quoted\"", size: nil)]
    let json = try exportFiles(files, format: .json)
    #expect(try JSONDecoder().decode([DriveFile].self, from: json) == files)
    let lines = try exportFiles(files, format: .jsonl)
    #expect(String(decoding: lines, as: UTF8.self).split(separator: "\n").count == 1)
    #expect(try JSONDecoder().decode(DriveFile.self, from: lines) == files[0])
    let csv = String(decoding: try exportFiles(files, format: .csv), as: UTF8.self)
    #expect(csv.contains("\"'=SUM(1,2)")); #expect(csv.contains("\"\"quoted\"\""))
}
@Test func folderCyclesTerminate() {
    var a = sample("a", name: "A", size: nil), b = sample("b", name: "B", size: nil)
    a.parents = ["b"]; b.parents = ["a"]
    #expect(filePath("a", index: ["a":a,"b":b], visited: []).contains("cycle"))
    #expect(descendants("a", files: [a,b]) == ["a","b"])
    #expect(filePath("unknown", index: [:], visited: []).contains("unresolved"))
}
@Test func largeIndexSearchAndPersistence() async throws {
    let files = (0..<10000).map { sample("\($0)", name: "File \($0).pdf", size: String($0 * 1024)) }
    let (db, _) = try temporaryDatabase()
    let start = Date()
    try await db.stage(files, stream: "user"); try await db.promote(stream: "user", cursor: "all", detected: "2026-09-01T00:00:00Z")
    let loaded = try await db.files(); #expect(loaded.count == 10000)
    var filter = FileFilter(); filter.minimumBytes = 9_000 * 1024
    let matches = loaded.filter { DriveCore.matches($0, filter: filter) }
    let sorted = try orderedFiles(matches, order: .size, ascending: false, facts: try await db.facts())
    #expect(sorted.count == 1000); #expect(sorted.first?.id == "9999")
    print("10,000-file SQLite stage/promote/load/filter/sort: \(Date().timeIntervalSince(start)) seconds")
    try await db.close()
}
@Test func newerSchemaIsRejectedWithoutDowngrade() async throws {
    let (db, path) = try temporaryDatabase(); try await db.close()
    var handle: OpaquePointer?; #expect(sqlite3_open(path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK); sqlite3_close(handle)
    #expect(throws: MonitorError.self) { try Database(path: path) }
}
@Test func timestampFiltersCompareInstantsNotLexicalOffsets() {
    #expect(within("2026-09-01T01:00:00+02:00", after: "2026-08-31T22:59:59Z", before: "2026-08-31T23:00:01Z"))
    #expect(!within("2026-09-01T00:00:00Z", after: "invalid", before: ""))
}
@Test func eventExportsKeepAttributionAndSource() throws {
    let event = DriveEvent(id: "1", fileID: "a", name: "A", action: "MOVED", time: "2026-09-01T00:00:00Z", detected: "2026-09-02T00:00:00Z", source: .changes, actor: nil, parents: ["new"], previousParents: ["old"], previousName: nil, raw: "{}")
    let data = try exportEvents([event], format: .json)
    #expect(try JSONDecoder().decode([DriveEvent].self, from: data) == [event])
    let line = try exportEvents([event], format: .jsonl)
    #expect(try JSONDecoder().decode(DriveEvent.self, from: line).actor == nil)
    let csv = String(decoding: try exportEvents([event], format: .csv), as: UTF8.self)
    #expect(csv.contains("\"changes\",\"\"")); #expect(csv.contains("\"old\",\"new\""))
}
@Test func invalidMetadataFailsExplicitly() throws {
    #expect(throws: MonitorError.self) { try validateFile(sample("id", name: "Broken", size: "-1")) }
    #expect(throws: MonitorError.self) { try validateFile(sample("id", name: "Broken", size: "not-a-size")) }
    try validateFile(sample("id", name: "Unknown is valid", size: nil))
}
@Test func membershipDoesNotResurrectAfterRestart() async throws {
    let (db, path) = try temporaryDatabase()
    for scope in ["user", "shared"] { try await db.stage([sample("id", name: "Shared", size: nil)], stream: scope); try await db.promote(stream: scope, cursor: "start", detected: "2026-09-01T00:00:00Z") }
    let removal = ChangePage(changes: [Change(changeType: "file", time: "2026-09-02T00:00:00Z", fileId: "id", removed: true, file: nil, driveId: nil)], nextPageToken: nil, newStartPageToken: "next")
    try await db.apply(removal, stream: "shared", detected: "2026-09-02T00:00:00Z"); try await db.close()
    let reopened = try Database(path: path)
    try await reopened.apply(removal, stream: "user", detected: "2026-09-02T00:00:00Z")
    #expect(try await reopened.file("id") == nil)
    try await reopened.close()
}
@Test func retiringDriveScopePreservesHistoryAndOtherMembership() async throws {
    let (db, _) = try temporaryDatabase()
    try await db.stage([sample("personal", name: "Still accessible", size: nil)], stream: "user")
    try await db.promote(stream: "user", cursor: "user-cursor", detected: "2026-09-01T00:00:00Z")
    try await db.stage([sample("personal", name: "Still accessible", size: nil),sample("only-shared", name: "Previously visible", size: nil)], stream: "shared")
    try await db.promote(stream: "shared", cursor: "shared-cursor", detected: "2026-09-01T00:00:00Z")
    try await db.retireScope("shared")
    #expect(try await db.files().map(\.id) == ["personal"])
    #expect(try await db.cursor("shared") == nil)
    #expect(try await db.history("only-shared").count == 1)
    try await db.close()
}
@Test func historicalPathsNeverUseFutureAncestorNames() async throws {
    let (db, _) = try temporaryDatabase()
    var folder = DriveFile(id: "folder", name: "Original folder", mimeType: "application/vnd.google-apps.folder"); folder.parents = ["root"]
    var child = sample("child", name: "Document", size: nil); child.parents = ["folder"]
    try await db.setSetting("rootID", value: "root")
    try await db.stage([folder,child], stream: "user")
    try await db.promote(stream: "user", cursor: "start", detected: "2026-09-01T00:00:00Z")
    var renamed = DriveFile(id: "folder", name: "Future name", mimeType: "application/vnd.google-apps.folder"); renamed.parents = ["root"]
    let change = Change(changeType: "file", time: "2026-09-02T00:00:00Z", fileId: "folder", removed: false, file: renamed, driveId: nil)
    try await db.apply(ChangePage(changes: [change], nextPageToken: nil, newStartPageToken: "next"), stream: "user", detected: "2026-09-02T00:00:00Z")
    #expect(try await db.observedPath("child", at: "2026-09-01T12:00:00Z") == "My Drive/Original folder/Document")
    #expect(try await db.observedPath("child", at: "2026-09-03T00:00:00Z") == "My Drive/Future name/Document")
    #expect(try await db.observedPath("child", at: "2026-08-01T00:00:00Z").contains("not observed"))
    #expect(try await db.snapshotRecords("child").first?.reconstructedPath == "My Drive/Original folder/Document")
    try await db.close()
}
@Test func schemaOneMigratesWithoutLosingFiles() async throws {
    let (db, path) = try temporaryDatabase()
    try await db.stage([sample("id", name: "Retained", size: nil)], stream: "user")
    try await db.promote(stream: "user", cursor: "retained", detected: "2026-09-01T00:00:00Z"); try await db.close()
    var handle: OpaquePointer?; #expect(sqlite3_open(path, &handle) == SQLITE_OK)
    #expect(sqlite3_exec(handle, "DROP TABLE membership; PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK); sqlite3_close(handle)
    let migrated = try Database(path: path)
    #expect(try await migrated.file("id")?.name == "Retained")
    #expect(try await migrated.cursor("user") == "retained")
    try await migrated.retireScope("user")
    #expect(try await migrated.files().isEmpty)
    try await migrated.close()
}

@Test func observedHierarchyUsesCutoffAndRetainsUncertainItems() async throws {
    let (db, path) = try temporaryDatabase()
    var folder = DriveFile(id: "folder", name: "Original folder", mimeType: "application/vnd.google-apps.folder"); folder.parents = ["root"]
    var child = sample("child", name: "Original document", size: "42"); child.parents = ["folder"]
    try await db.setSetting("rootID", value: "root")
    try await db.stage([folder, child], stream: "user")
    try await db.promote(stream: "user", cursor: "first", detected: "2026-09-01T09:00:00Z")
    folder = DriveFile(id: "folder", name: "Later folder", mimeType: "application/vnd.google-apps.folder"); folder.parents = ["root"]
    child = sample("child", name: "Later document", size: "42"); child.parents = ["unobserved"]
    let changes = [folder, child].map { Change(changeType: "file", time: "2026-09-02T09:00:00Z", fileId: $0.id, removed: false, file: $0, driveId: nil) }
    try await db.apply(ChangePage(changes: changes, nextPageToken: nil, newStartPageToken: "second"), stream: "user", detected: "2026-09-02T09:00:00Z")
    let removal = Change(changeType: "file", time: "2026-09-03T09:00:00Z", fileId: "child", removed: true, file: nil, driveId: nil)
    try await db.apply(ChangePage(changes: [removal], nextPageToken: nil, newStartPageToken: "third"), stream: "user", detected: "2026-09-03T09:00:00Z")
    #expect(try await db.observedFiles(at: "2026-09-01T08:59:59Z").isEmpty)
    // The offset cutoff equals 09:00 UTC, so the exact-time observation must be included.
    let early = try await db.observedFiles(at: "2026-09-01T02:00:00-07:00")
    #expect(Set(early.map { $0.file.name }) == ["Original folder", "Original document"])
    #expect(try await db.observedPath("child", at: "2026-09-01T02:00:00-07:00") == "My Drive/Original folder/Original document")
    #expect(try await db.file("child") == nil)
    try await db.close()
    let reopened = try Database(path: path)
    let later = try await reopened.observedFiles(at: "2026-09-04T00:00:00Z")
    #expect(later.count == 2)
    let retained = try #require(later.first { $0.id == "child" })
    #expect(retained.file.name == "Later document")
    #expect(retained.observedAt == "2026-09-02T09:00:00Z")
    let index = Dictionary(uniqueKeysWithValues: later.map { ($0.id, $0.file) })
    #expect(folderTrail("child", index: index, roots: [:]).first?.folderID == nil)
    #expect(folderTrail("child", index: index, roots: [:]).first?.label == "Unobserved parent: unobserved")
    await #expect(throws: MonitorError.self) { try await reopened.observedFiles(at: "yesterday") }
    try await reopened.clearHistory()
    #expect(try await reopened.observedFiles(at: "2026-09-04T00:00:00Z").isEmpty)
    try await reopened.close()
}

@Test func breadcrumbsKeepRootIdentityAndCoverageBoundaries() {
    var parent = DriveFile(id: "parent", name: "Same name", mimeType: "application/vnd.google-apps.folder"); parent.parents = ["shared"]
    var child = DriveFile(id: "child", name: "Same name", mimeType: "application/vnd.google-apps.folder"); child.parents = ["parent"]
    let trail = folderTrail("child", index: [parent.id: parent, child.id: child], roots: ["shared": "Team Drive"])
    #expect(trail.map(\.folderID) == ["shared", "parent", "child"])
    #expect(!trail.contains { $0.label == "My Drive" })
    parent.parents = ["child"]
    let cycle = folderTrail("child", index: [parent.id: parent, child.id: child], roots: [:])
    #expect(cycle.first?.label == "Cycle: child")
    #expect(cycle.first?.folderID == nil)
    #expect(cycle.count == 3)
    child.parents = nil
    #expect(folderTrail("child", index: [child.id: child], roots: [:]).first?.label == "Parent unavailable")
    child.parents = ["shared", "another"]
    let multiple = folderTrail("child", index: [child.id: child], roots: ["shared": "Team Drive"])
    #expect(multiple.contains { $0.label == "Multiple parents; first shown" && $0.folderID == nil })
}

@Test func invalidAndReversedSearchRangesAreRejected() throws {
    var filter = FileFilter(); filter.createdAfter = "yesterday"
    #expect(throws: MonitorError.self) { try validateFilter(filter) }
    #expect(throws: MonitorError.self) { try serverQuery(filter) }
    filter.createdAfter = "2026-09-02T00:00:00Z"; filter.createdBefore = "2026-09-01T00:00:00Z"
    #expect(throws: MonitorError.self) { try validateFilter(filter) }
    filter.createdAfter = "2026-09-01T01:00:00+02:00"
    try validateFilter(filter)
    filter.minimumBytes = 100; filter.maximumBytes = 99
    #expect(throws: MonitorError.self) { try validateFilter(filter) }
    #expect(throws: MonitorError.self) { try validateDateRange(after: "bad", before: "", label: "Activity range") }
}
@Test func cancelledSortStopsAndDateOrderingUsesInstants() async throws {
    var first = sample("first", name: "Z", size: nil), second = sample("second", name: "A", size: nil)
    first.modifiedTime = "2026-09-01T01:00:00+02:00"; second.modifiedTime = "2026-09-01T00:00:00Z"
    let files = [first, second]
    let facts = FileFacts(firstSeen: [:], lastActivity: [:], activityCounts: [:])
    #expect(try orderedFiles(files, order: .modified, ascending: true, facts: facts).map(\.id) == ["first", "second"])
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try orderedFiles(files, order: .modified, ascending: true, facts: facts)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}
@Test func preparedNavigationPreservesRootsAndTerminatesCycles() throws {
    var a = DriveFile(id: "a", name: "A", mimeType: "application/vnd.google-apps.folder")
    var b = DriveFile(id: "b", name: "B", mimeType: "application/vnd.google-apps.folder")
    a.parents = ["root", "b"]; b.parents = ["a"]
    let navigation = try prepareNavigation(files: [a,b], root: nil, roots: ["root", "empty"])
    #expect(navigation.roots["root"]?.first?.children?.first?.id == "b")
    #expect(navigation.roots["root"]?.first?.children?.first?.children == nil)
    #expect(navigation.roots["empty"]?.isEmpty == true)
    #expect(navigation.locations["a"]?.contains("unresolved") == true)
}
