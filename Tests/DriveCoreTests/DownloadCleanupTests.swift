import Foundation
import Testing
@testable import DriveCore

@Test func stagingCleanupFailurePreservesSavedBytesAndBatchOutcome() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var staging: URL?
    defer {
        do {
            if let staging {
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
                try manager.removeItem(at: staging)
            }
            try manager.removeItem(at: root)
        } catch { Issue.record(error) }
    }
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("saved.txt")
    let bytes = Data("real filesystem cleanup check".utf8)
    try bytes.write(to: source)
    do {
        try stageDownloadedFile(source, destination: destination) { staged in
            let directory = staged.deletingLastPathComponent()
            staging = directory
            try manager.moveItem(at: staged, to: destination)
            try Data("task-owned cleanup obstruction".utf8).write(to: directory.appendingPathComponent("obstruction"))
            try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        }
        Issue.record("Removing the inaccessible staging directory must report a saved-file cleanup failure.")
    } catch let failure as SavedDownloadCleanupError {
        #expect(failure.destination == destination)
        #expect(failure.failures.count == 1)
        let detail = try #require(failure.failures.first)
        #expect(detail.temporary == staging)
        #expect((detail.cause as NSError).domain == NSCocoaErrorDomain)
        #expect((detail.cause as NSError).code == NSFileWriteNoPermissionError)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
        #expect(failure.localizedDescription.contains("was saved"))
        #expect(failure.localizedDescription.contains("before downloading again"))
        #expect(failure.localizedDescription.contains(try #require(staging).path))

        let result = DownloadResult.savedWithCleanupFailure(failure, path: destination.lastPathComponent, id: UUID())
        let report = BatchDownloadReport(directory: root, planned: 1, results: [result], issues: [], unattempted: [], cancelled: false)
        let reportURL = root.appendingPathComponent("download-report.json")
        try JSONEncoder().encode(report).write(to: reportURL, options: .withoutOverwriting)
        let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: reportURL))
        #expect(saved.completed == 1); #expect(saved.failures == 0); #expect(saved.remaining == 0)
        #expect(saved.cleanupWarnings == 1)
        #expect(saved.results.first?.outcome == .downloaded)
        #expect(saved.results.first?.message == failure.localizedDescription)
        #expect(saved.summary.contains("1 files saved"))
        #expect(saved.summary.contains("1 cleanup warnings"))
    }
}

@Test func transferTemporaryCleanupFailurePreservesCommittedOutcomeAndCause() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let privateDirectory = root.appendingPathComponent("temporary", isDirectory: true)
    try manager.createDirectory(at: privateDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer {
        do {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateDirectory.path)
            try manager.removeItem(at: root)
        } catch { Issue.record(error) }
    }
    let destination = root.appendingPathComponent("saved.txt")
    let temporary = privateDirectory.appendingPathComponent("URLSession-temporary")
    let bytes = Data("committed download".utf8)
    try bytes.write(to: destination)
    try bytes.write(to: temporary)
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: privateDirectory.path)
    do {
        try removeSavedDownloadTemporary(temporary, destination: destination)
        Issue.record("An inaccessible transfer temporary must report cleanup failure after save.")
    } catch {
        #expect(error.destination == destination)
        #expect(error.failures.count == 1)
        let failure = try #require(error.failures.first)
        #expect(failure.temporary == temporary)
        #expect((failure.cause as NSError).code == NSFileWriteNoPermissionError)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(error.localizedDescription.contains(temporary.path))
    }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateDirectory.path)
    #expect(try Data(contentsOf: temporary) == bytes)
}
