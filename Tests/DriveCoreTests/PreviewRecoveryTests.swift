import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

@Test func cancelledPreviewPersistenceDoesNotCreateTemporaryContent() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PreviewStore(root: root)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await store.save(PreviewContent(data: Data("cancelled preview".utf8), fileExtension: "txt"), name: "cancelled")
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!manager.fileExists(atPath: root.path))
    if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
}

@Test func previewPersistenceSecuresAnExistingDirectoryAndRetainsEarlierContent() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    defer { do { try manager.removeItem(at: root) } catch { Issue.record(error) } }
    let store = PreviewStore(root: root)
    let firstContent = Data("earlier usable preview".utf8)
    let first = try await store.save(PreviewContent(data: firstContent, fileExtension: "txt"), name: "earlier")
    let nextContent = Data("new preview".utf8)
    let next = try await store.save(PreviewContent(data: nextContent, fileExtension: "txt"), name: "../../not-a-local-path.txt")
    #expect(next.url.deletingLastPathComponent() == root)
    #expect(next.url.lastPathComponent == next.id.uuidString + ".txt")
    #expect(try Data(contentsOf: first.url) == firstContent)
    #expect(try Data(contentsOf: next.url) == nextContent)
    #expect(try manager.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
    #expect(try manager.attributesOfItem(atPath: next.url.path)[.posixPermissions] as? Int == 0o600)
    try await store.remove(next.url)
    #expect(!manager.fileExists(atPath: next.url.path))
    #expect(try Data(contentsOf: first.url) == firstContent)
}

@Test func unsafeOrOversizedPreviewContentDoesNotMutateStorage() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    defer { do { try manager.removeItem(at: root) } catch { Issue.record(error) } }
    let existing = root.appendingPathComponent("existing.txt")
    let content = Data("existing usable preview".utf8)
    try content.write(to: existing, options: .withoutOverwriting)
    let store = PreviewStore(root: root)
    for suffix in ["../txt", "txt/other", "TXT", "", "txt\n", "12345678901234567"] {
        await #expect(throws: MonitorError.self) {
            try await store.save(PreviewContent(data: Data(), fileExtension: suffix), name: "invalid")
        }
    }
    await #expect(throws: MonitorError.self) {
        try await store.save(PreviewContent(data: Data(repeating: 120, count: 20 * 1024 * 1024 + 1), fileExtension: "txt"), name: "oversized")
    }
    #expect(try manager.contentsOfDirectory(atPath: root.path) == ["existing.txt"])
    #expect(try Data(contentsOf: existing) == content)
    #expect(try manager.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o755)
}

@Test func previewStorageRefusesRedirectedRootAndCleanupOutsideItsDirectory() async throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { do { try manager.removeItem(at: directory) } catch { Issue.record(error) } }
    let target = directory.appendingPathComponent("other-content", isDirectory: true)
    try manager.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    let original = target.appendingPathComponent("original.txt")
    let content = Data("not preview-owned".utf8)
    try content.write(to: original, options: .withoutOverwriting)
    let root = directory.appendingPathComponent("redirected-root", isDirectory: true)
    try manager.createSymbolicLink(at: root, withDestinationURL: target)
    let store = PreviewStore(root: root)
    do {
        _ = try await store.save(PreviewContent(data: Data("new".utf8), fileExtension: "txt"), name: "new")
        Issue.record("A symbolic-link preview root must not be followed.")
    } catch { #expect(error.localizedDescription.contains("symbolic link")) }
    do {
        try await store.clear()
        Issue.record("A symbolic-link root must not be cleared.")
    } catch let failure as PreviewCleanupError { #expect(failure.cause.localizedDescription.contains("symbolic link")) }
    do {
        try await store.remove(root.appendingPathComponent("original.txt"))
        Issue.record("Preview cleanup must not follow a redirected root.")
    } catch let failure as PreviewCleanupError { #expect(failure.cause.localizedDescription.contains("symbolic link")) }
    await #expect(throws: MonitorError.self) { try await store.remove(original) }
    #expect(try Data(contentsOf: original) == content)
    #expect(try manager.contentsOfDirectory(atPath: target.path) == ["original.txt"])
    #expect(try manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o755)
    #expect(try manager.destinationOfSymbolicLink(atPath: root.path) == target.path)
}

@Test func inaccessiblePreviewCleanupReportsItsCauseAndRetainsContent() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = PreviewStore(root: root)
    let content = Data("private cleanup fixture".utf8)
    let preview = try await store.save(PreviewContent(data: content, fileExtension: "txt"), name: "private")
    defer {
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try manager.removeItem(at: root)
        } catch { Issue.record(error) }
    }
    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    do {
        try await store.remove(preview.url)
        Issue.record("An inaccessible preview must report cleanup failure.")
    } catch let failure as PreviewCleanupError {
        #expect(failure.temporary == preview.url)
        #expect((failure.cause as NSError).domain == NSCocoaErrorDomain)
        #expect((failure.cause as NSError).code == NSFileWriteNoPermissionError)
        #expect(failure.localizedDescription.contains("permissions"))
    }
    do {
        try await store.clear()
        Issue.record("Clearing inaccessible preview content must report cleanup failure.")
    } catch let failure as PreviewCleanupError {
        #expect(failure.temporary == root)
        #expect((failure.cause as NSError).code == NSFileWriteNoPermissionError)
    }
    #expect(try Data(contentsOf: preview.url) == content)
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try await store.remove(preview.url)
    #expect(try manager.contentsOfDirectory(atPath: root.path).isEmpty)
}
