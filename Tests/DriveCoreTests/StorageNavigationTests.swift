import Foundation
import Testing
@testable import DriveCore
@testable import DriveExplorer

@Test @MainActor func storageCategoryNavigationMatchesTotalsAndKeepsFiltersScoped() async throws {
    var first = DriveFile(id: "first", name: "First", mimeType: "chemical/x-pdb"); first.size = "10"; first.parents = ["a"]
    var second = DriveFile(id: "second", name: "Second", mimeType: "chemical/x-xyz"); second.size = "20"; second.parents = ["b"]
    var unknown = DriveFile(id: "unknown", name: "Unknown", mimeType: "chemical/x-pdb"); unknown.parents = ["a"]
    var trashed = first; trashed = DriveFile(id: "trashed", name: "Trashed", mimeType: "chemical/x-pdb"); trashed.trashed = true
    let doc = DriveFile(id: "doc", name: "Document", mimeType: "application/vnd.google-apps.document")
    let binary = DriveFile(id: "binary", name: "Binary", mimeType: "application/octet-stream")
    let folder = DriveFile(id: "folder", name: "Folder", mimeType: "application/vnd.google-apps.folder")
    let files = [first, second, unknown, trashed, doc, binary, folder]
    let groups = storageGroups(files, key: storageType, label: { storageTitle($0, index: [:], drives: []) })
    let chemical = try #require(groups.first { $0.scope == .mimeFamily("chemical") })
    #expect(chemical.count == 3); #expect(chemical.bytes == 30); #expect(chemical.unknown == 1)
    let model = AppModel(); model.files = files; model.filter.text = "stale search"; model.selectedFile = "binary"
    model.openStorageGroup(chemical)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while model.searching && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.searching); #expect(model.results.map(\.id) == ["second", "first", "unknown"])
    #expect(model.title == "Chemical"); #expect(model.selectedFiles.isEmpty)
    var narrowed = model.filter; narrowed.text = "First"
    #expect(files.filter { matches($0, filter: narrowed) }.map(\.id) == ["first"])
    let restored = try JSONDecoder().decode(FileFilter.self, from: JSONEncoder().encode(narrowed))
    #expect(restored == narrowed)
    #expect(throws: MonitorError.self) { try serverQuery(restored) }
    let legacyData = try JSONEncoder().encode(FileFilter())
    #expect(try JSONDecoder().decode(FileFilter.self, from: legacyData).storage == nil)
    model.navigate("storage")
    #expect(model.filter.storage == nil); #expect(model.title == "Storage overview")
}

@Test func storageParentAndDriveGroupsUseIdentityInsteadOfNames() throws {
    let parentA = DriveFile(id: "a", name: "Same name", mimeType: "application/vnd.google-apps.folder")
    let parentB = DriveFile(id: "b", name: "Same name", mimeType: "application/vnd.google-apps.folder")
    var first = DriveFile(id: "first", name: "First", mimeType: "text/plain"); first.parents = ["a"]; first.driveId = "drive-a"
    var second = DriveFile(id: "second", name: "Second", mimeType: "text/plain"); second.parents = ["b"]; second.driveId = "drive-b"
    let orphan = DriveFile(id: "orphan", name: "Orphan", mimeType: "text/plain")
    let files = [first, second, orphan]
    let index = ["a": parentA, "b": parentB]
    let groups = storageGroups(files, key: { .parent($0.parents?.first) }, label: { storageTitle($0, index: index, drives: []) })
    #expect(groups.count == 3); #expect(groups.filter { $0.title == "Same name" }.count == 2)
    for group in groups { #expect(files.filter { matchesStorage($0, scope: group.scope) }.count == group.count) }
    #expect(files.filter { matchesStorage($0, scope: .parent(nil)) }.map(\.id) == ["orphan"])
    #expect(files.filter { matchesStorage($0, scope: .drive(nil)) }.map(\.id) == ["orphan"])
    #expect(files.filter { matchesStorage($0, scope: .drive("drive-a")) }.map(\.id) == ["first"])
    #expect(storageType(DriveFile(id: "empty", name: "Empty MIME", mimeType: "")) == .mimeFamily(""))
}
