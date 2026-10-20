import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

@MainActor private func waitForFileResults(_ model: AppModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.searching {
        guard ContinuousClock.now < deadline else { throw MonitorError.invalid("File-selection results did not finish before the test deadline.") }
        await Task.yield()
    }
}

/// Real SQLite reloads retain surviving identities; a new query clears even an identical result set.
@Test @MainActor func fileSelectionSurvivesReloadAndPrunesRemovedIDs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drivetrace-selection-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let database = try Database(path: directory.appendingPathComponent("drive.sqlite").path)
    let first = sample("one", name: "Report A", size: "10")
    let second = sample("two", name: "Report B", size: "20")
    let third = sample("three", name: "Report C", size: "30")
    try await database.stage([first, second, third], stream: "user")
    try await database.promote(stream: "user", cursor: "first", detected: "2026-10-19T12:00:00Z")
    let model = AppModel()
    model.database = database
    try await model.reload()
    try await waitForFileResults(model)
    model.selectedFiles = ["one", "two"]
    try await model.reload()
    try await waitForFileResults(model)
    #expect(model.selectedFiles == ["one", "two"])

    let renamed = sample("one", name: "Report Z", size: "10")
    try await database.beginBaseline(stream: "user")
    try await database.stage([renamed, third], stream: "user")
    try await database.promote(stream: "user", cursor: "second", detected: "2026-10-19T12:01:00Z")
    try await model.reload()
    try await waitForFileResults(model)
    #expect(model.results.map(\.id) == ["three", "one"])
    #expect(model.selectedFiles == ["one"])
    #expect(model.selected?.name == "Report Z")

    model.filter.text = "Report"
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.results.map(\.id) == ["three", "one"])
    #expect(model.selectedFiles.isEmpty)
    try await database.close()
    try FileManager.default.removeItem(at: directory)
}

/// Paging never retains hidden action targets, including when a refresh moves a row across the boundary.
@Test @MainActor func fileSelectionRefreshKeepsPageAndOnlyVisibleIDs() async throws {
    let model = AppModel()
    model.files = (0..<502).map { index in
        let id = String(format: "%04d", index)
        return sample(id, name: "Item " + id, size: "10")
    }
    model.updateResults()
    try await waitForFileResults(model)
    model.filePage = 1
    model.selectedFiles = ["0500", "0501"]
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.filePage == 1)
    #expect(model.selectedFiles == ["0500", "0501"])

    model.files.removeFirst()
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.filePage == 1)
    #expect(model.selectedFiles == ["0501"])
    model.filePage = 0
    #expect(model.selectedFiles.isEmpty)

    model.filePage = 1
    model.selectedFiles = ["0501"]
    model.files.removeLast()
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.filePage == 0)
    #expect(model.selectedFiles.isEmpty)
}

/// Publishing refresh results must use the current selection, not restore one captured before processing.
@Test @MainActor func fileSelectionChangesDuringRefreshAreNotRestored() async throws {
    let model = AppModel()
    model.files = [sample("one", name: "One", size: "10"), sample("two", name: "Two", size: "20")]
    model.updateResults()
    try await waitForFileResults(model)
    model.selectedFiles = ["one"]
    model.updateResults()
    model.selectedFiles = ["two"]
    try await waitForFileResults(model)
    #expect(model.selectedFiles == ["two"])
    model.updateResults()
    model.selectedFiles = []
    try await waitForFileResults(model)
    #expect(model.selectedFiles.isEmpty)

    model.selectedFiles = ["one", "two"]
    model.ascending = false
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.selectedFiles.isEmpty)
    model.selectedFiles = ["one"]
    model.minimumSizeInput = "invalid"
    model.updateResults()
    #expect(model.filterValidationError != nil)
    #expect(model.results.isEmpty)
    #expect(model.selectedFiles.isEmpty)
}

/// Google-only identities are selectable without being present in the local index.
@Test @MainActor func fileSelectionRetainsGoogleOnlyResultsUntilSourceOrWorkspaceChanges() async throws {
    let model = AppModel()
    let remote = sample("remote", name: "Remote", size: "10")
    model.serverResults = [remote]
    model.updateResults()
    try await waitForFileResults(model)
    model.selectedFiles = ["remote"]
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.files.isEmpty)
    #expect(model.selectedFiles == ["remote"])

    model.files = [remote]
    model.serverResults = nil
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.selectedFiles.isEmpty)
    model.selectedFiles = ["remote"]
    model.rootID = "another-account-root"
    model.updateResults()
    try await waitForFileResults(model)
    #expect(model.selectedFiles.isEmpty)
}
