import Foundation
import Testing
@testable import DriveCore

private func longNameFile(_ id: String, name: String, mime: String) -> DriveFile {
    var file = DriveFile(id: id, name: name, mimeType: mime)
    file.capabilities = FileCapabilities(canDownload: true, canTrash: nil)
    return file
}

extension GoogleIntegrationTests {
    @Test func longGeneratedNamesPreserveFolderStructureContentsAndExports() async throws {
        let ascii = String(repeating: "A", count: 236) + ".txt"
        let asciiDuplicate = String(repeating: "a", count: 236) + ".TXT"
        let emoji = "👍🏽"
        #expect(emoji.count == 1); #expect(emoji.utf8.count == 8)
        let unicodeStem = String(repeating: "u", count: 4) + String(repeating: emoji, count: 29)
        let unicode = unicodeStem + ".txt"
        #expect(try downloadName(unicode) == unicode)
        let folderName = String(repeating: "f", count: 240)
        let documentName = String(repeating: "d", count: 240)
        let accent = "e\u{0301}"
        let sheetName = String(repeating: accent, count: 78) + String(repeating: "r", count: 6)
        #expect([ascii, asciiDuplicate, unicode, folderName, documentName, sheetName].allSatisfy { $0.utf8.count == 240 })
        let root = DriveFile(id: "root-folder", name: "Project", mimeType: "application/vnd.google-apps.folder")
        let folderA = DriveFile(id: "05-folder", name: folderName, mimeType: "application/vnd.google-apps.folder")
        let folderB = DriveFile(id: "06-folder", name: folderName, mimeType: "application/vnd.google-apps.folder")
        let childA = longNameFile("child-a", name: "Leaf.txt", mime: "text/plain")
        let childB = longNameFile("child-b", name: "Leaf.txt", mime: "text/plain")
        let top = [
            longNameFile("01-ascii", name: ascii, mime: "text/plain"),
            longNameFile("02-ascii", name: asciiDuplicate, mime: "text/plain"),
            longNameFile("03-unicode", name: unicode, mime: "text/plain"),
            longNameFile("04-unicode", name: unicode, mime: "text/plain"),
            folderA, folderB,
            longNameFile("07-doc", name: documentName, mime: "application/vnd.google-apps.document"),
            longNameFile("08-doc", name: documentName, mime: "application/vnd.google-apps.document"),
            longNameFile("09-sheet", name: sheetName, mime: "application/vnd.google-apps.spreadsheet"),
            longNameFile("10-sheet", name: sheetName, mime: "application/vnd.google-apps.spreadsheet"),
            longNameFile("11-short", name: "Keep.txt", mime: "text/plain"),
            longNameFile("12-short-doc", name: "Short report", mime: "application/vnd.google-apps.document")
        ]
        let topJSON = try top.map { try encoded($0) }.joined(separator: ",")
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        await FixtureProtocol.fixture.prepare([
            (200, try encoded(root)), (200, "{\"files\":[" + topJSON + "]}"),
            (200, "{\"files\":[" + (try encoded(childA)) + "]}"),
            (200, "{\"files\":[" + (try encoded(childB)) + "]}")
        ])
        let plan = try await client.planDownloads(ids: [root.id], progress: { _ in })
        let shortenedFolder = String(repeating: "f", count: 236) + " (2)"
        let expected: [String: [String]] = [
            root.id: ["Project"],
            "01-ascii": ["Project", ascii],
            "02-ascii": ["Project", String(repeating: "a", count: 232) + " (2).TXT"],
            "03-unicode": ["Project", unicode],
            "04-unicode": ["Project", String(repeating: "u", count: 4) + String(repeating: emoji, count: 28) + " (2).txt"],
            folderA.id: ["Project", folderName], folderB.id: ["Project", shortenedFolder],
            childA.id: ["Project", folderName, "Leaf.txt"], childB.id: ["Project", shortenedFolder, "Leaf.txt"],
            "07-doc": ["Project", String(repeating: "d", count: 235) + ".docx"],
            "08-doc": ["Project", String(repeating: "d", count: 231) + " (2).docx"],
            "09-sheet": ["Project", String(repeating: accent, count: 78) + "r.xlsx"],
            "10-sheet": ["Project", String(repeating: accent, count: 77) + " (2).xlsx"],
            "11-short": ["Project", "Keep.txt"], "12-short-doc": ["Project", "Short report.docx"]
        ]
        #expect(plan.issues.isEmpty); #expect(plan.items.count == expected.count)
        for item in plan.items {
            #expect(item.components == expected[item.file.id])
            #expect(item.components.allSatisfy { $0.utf8.count <= 240 })
        }
        let files = plan.items.filter { !$0.file.isFolder }
        let responses: [(Int, String)] = try files.flatMap { item in [(200, try encoded(item.file)), (200, "payload-" + item.file.id)] }
        await FixtureProtocol.fixture.prepare(responses)
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { do { try manager.removeItem(at: parent) } catch { Issue.record(error) } }
        let sentinel = parent.appendingPathComponent("existing.txt")
        try Data("existing bytes".utf8).write(to: sentinel, options: .withoutOverwriting)
        let report = try await client.downloadBatch(plan: plan, parent: parent, progress: { _ in })
        #expect(report.completed == files.count); #expect(report.failures == 0); #expect(report.remaining == 0)
        #expect(report.results.count == plan.items.count); #expect(report.cleanupWarnings == 0); #expect(!report.cancelled)
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "existing bytes")
        for item in files {
            let components = try #require(expected[item.file.id])
            let destination = components.reduce(report.directory.appendingPathComponent("Files", isDirectory: true)) { $0.appendingPathComponent($1) }
            #expect(try String(contentsOf: destination, encoding: .utf8) == "payload-" + item.file.id)
        }
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == files.count * 2)
        for (index, item) in files.enumerated() where item.file.mimeType.hasPrefix("application/vnd.google-apps.") {
            let request = requests[index * 2 + 1]
            #expect(request.url?.path == "/drive/v3/files/" + item.file.id + "/export")
            let url = try #require(request.url)
            let mime = item.file.mimeType == "application/vnd.google-apps.spreadsheet"
                ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                : "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mimeType" }?.value == mime)
        }
        let saved = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: report.directory.appendingPathComponent("download-report.json")))
        #expect(saved.completed == files.count); #expect(saved.failures == 0); #expect(saved.remaining == 0)
        #expect(saved.results.map(\.path) == report.results.map(\.path))
    }

    @Test func impossibleSuffixAndCharacterBoundariesFailExplicitly() throws {
        let name = "a." + String(repeating: "x", count: 238)
        #expect(try availableDownloadName(name, occupiedKeys: []) == name)
        #expect(throws: MonitorError.self) { try availableDownloadName(name, occupiedKeys: [downloadNameKey(name)]) }
        let character = "a" + String(repeating: "\u{0301}", count: 119)
        #expect(character.count == 1); #expect(character.utf8.count == 239)
        let document = longNameFile("one-character", name: character, mime: "application/vnd.google-apps.document")
        #expect(throws: MonitorError.self) { try fileDownload(document) }
        #expect(throws: MonitorError.self) { try downloadNameAppendingSuffix("stem", suffix: String(repeating: "x", count: 240)) }
    }
}
