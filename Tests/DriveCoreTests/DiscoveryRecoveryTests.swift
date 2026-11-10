import Foundation
import Testing
@testable import DriveCore

private actor DiscoveryProgress {
    var values: [BatchProgress] = []
    func record(_ value: BatchProgress) { values.append(value) }
    func latest() -> BatchProgress? { values.last }
}

extension GoogleIntegrationTests {
    @Test func cancellationFromFinalDiscoveryProgressDoesNotReturnAPlan() async throws {
        let file = #"{"id":"file","name":"Selected.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        await FixtureProtocol.fixture.prepare([(200, file)])
        let task = Task {
            try await fixtureClient(FixtureTokens()).planDownloads(ids: ["file"]) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/drive/v3/files/file")
    }

    @Test func rejectedSelectedMetadataPublishesItsDiscoveryFailure() async throws {
        let denied = #"{"error":{"code":403,"message":"private provider text","errors":[{"reason":"insufficientFilePermissions","domain":"global"}]}}"#
        let progress = DiscoveryProgress()
        await FixtureProtocol.fixture.prepare([(403, denied)])
        let plan = try await fixtureClient(FixtureTokens()).planDownloads(ids: ["denied"]) { value in await progress.record(value) }
        #expect(plan.items.isEmpty)
        let issue = try #require(plan.issues.first)
        #expect(plan.issues.count == 1)
        #expect(issue.path == "denied")
        #expect(issue.reason.contains("403"))
        #expect(issue.reason.contains("insufficientFilePermissions"))
        #expect(!issue.reason.contains("private provider text"))
        let latest = try #require(await progress.latest())
        #expect(latest.current == "denied")
        #expect(latest.discovered == 0)
        #expect(latest.failed == 1)
    }

    @Test func failedFolderPaginationKeepsItsGapAndAllowsACompleteFreshRetry() async throws {
        let folder = #"{"id":"folder","name":"Project","mimeType":"application/vnd.google-apps.folder"}"#
        let first = #"{"id":"a","name":"First.txt","mimeType":"text/plain","size":"5","capabilities":{"canDownload":true}}"#
        let second = #"{"id":"b","name":"Second.txt","mimeType":"text/plain","size":"6","capabilities":{"canDownload":true}}"#
        let denied = #"{"error":{"code":403,"message":"private page detail","errors":[{"reason":"insufficientFilePermissions","domain":"global"}]}}"#
        let tokens = FixtureTokens(); await tokens.grantManagement()
        let client = fixtureClient(tokens)
        let progress = DiscoveryProgress()
        await FixtureProtocol.fixture.prepare([
            (200, folder), (200, "{\"files\":[" + first + "],\"nextPageToken\":\"second-page\"}"), (403, denied)
        ])
        let failed = try await client.planDownloads(ids: ["folder"]) { value in await progress.record(value) }
        #expect(failed.items.map(\.file.id) == ["folder"])
        #expect(failed.issues.count == 1)
        let issue = try #require(failed.issues.first)
        #expect(issue.path == "Project")
        #expect(issue.reason.contains("none of its children from this listing will be downloaded"))
        #expect(issue.reason.contains("403"))
        #expect(issue.reason.contains("insufficientFilePermissions"))
        #expect(!issue.reason.contains("private page detail"))
        #expect(await progress.latest()?.failed == 1)
        let requests = await FixtureProtocol.fixture.allRequests()
        #expect(requests.count == 3)
        let pageURL = try #require(requests.last?.url)
        #expect(URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value == "second-page")

        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent("DriveTrace Discovery Recovery " + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { do { try manager.removeItem(at: parent) } catch { Issue.record(error) } }
        let sentinel = parent.appendingPathComponent("existing.txt")
        try Data("retained".utf8).write(to: sentinel, options: .withoutOverwriting)
        await FixtureProtocol.fixture.prepare([])
        let failedReport = try await client.downloadBatch(plan: failed, parent: parent, progress: { _ in })
        #expect(failedReport.completed == 0)
        #expect(failedReport.failures == 1)
        #expect(failedReport.summary.hasPrefix("Finished with gaps"))
        #expect(try manager.contentsOfDirectory(atPath: failedReport.directory.appendingPathComponent("Files/Project").path).isEmpty)
        let recordedGap = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: failedReport.directory.appendingPathComponent("download-report.json")))
        #expect(recordedGap.issues.first?.reason == issue.reason)

        await FixtureProtocol.fixture.prepare([
            (200, folder), (200, "{\"files\":[" + first + "],\"nextPageToken\":\"second-page\"}"), (200, "{\"files\":[" + second + "]}")
        ])
        let retry = try await client.planDownloads(ids: ["folder"], progress: { _ in })
        #expect(retry.issues.isEmpty)
        #expect(retry.items.map(\.file.id) == ["folder", "a", "b"])
        await FixtureProtocol.fixture.prepare([(200, first), (200, "first"), (200, second), (200, "second")])
        let retryReport = try await client.downloadBatch(plan: retry, parent: parent, progress: { _ in })
        #expect(retryReport.directory != failedReport.directory)
        #expect(retryReport.completed == 2)
        #expect(retryReport.failures == 0)
        #expect(retryReport.unattempted.isEmpty)
        #expect(try Data(contentsOf: retryReport.directory.appendingPathComponent("Files/Project/First.txt")) == Data("first".utf8))
        #expect(try Data(contentsOf: retryReport.directory.appendingPathComponent("Files/Project/Second.txt")) == Data("second".utf8))
        #expect(try Data(contentsOf: sentinel) == Data("retained".utf8))
        #expect(try manager.contentsOfDirectory(atPath: failedReport.directory.appendingPathComponent("Files/Project").path).isEmpty)
        let savedRetry = try JSONDecoder().decode(BatchDownloadReport.self, from: Data(contentsOf: retryReport.directory.appendingPathComponent("download-report.json")))
        #expect(savedRetry.completed == 2)
        #expect(savedRetry.issues.isEmpty)
        #expect(savedRetry.results.map(\.path) == ["Project", "Project/First.txt", "Project/Second.txt"])
    }

    @Test func incompleteAndRepeatedFolderPagesPublishGapsWithoutPlanningPartialChildren() async throws {
        let folder = #"{"id":"folder","name":"Project","mimeType":"application/vnd.google-apps.folder"}"#
        let child = #"{"id":"child","name":"Partial.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        let first = "{\"files\":[" + child + "],\"nextPageToken\":\"next-page\"}"
        let pages = [
            [(200, folder), (200, first), (200, #"{"files":[],"incompleteSearch":true}"#)],
            [(200, folder), (200, first), (200, #"{"files":[],"nextPageToken":"next-page"}"#)]
        ]
        for responses in pages {
            let progress = DiscoveryProgress()
            await FixtureProtocol.fixture.prepare(responses)
            let plan = try await fixtureClient(FixtureTokens()).planDownloads(ids: ["folder"]) { value in await progress.record(value) }
            #expect(plan.items.map(\.file.id) == ["folder"])
            #expect(plan.issues.count == 1)
            #expect(plan.issues.first?.reason.contains("none of its children from this listing will be downloaded") == true)
            let latest = try #require(await progress.latest())
            #expect(latest.current == "Project")
            #expect(latest.discovered == 1)
            #expect(latest.failed == 1)
            #expect(await FixtureProtocol.fixture.allRequests().count == 3)
        }
    }

    @Test func selectedFolderAndChildPublishTheSkippedDuplicateWithoutPlanningTwoCopies() async throws {
        let folder = #"{"id":"folder","name":"Project","mimeType":"application/vnd.google-apps.folder"}"#
        let child = #"{"id":"a","name":"Selected.txt","mimeType":"text/plain","capabilities":{"canDownload":true}}"#
        let progress = DiscoveryProgress()
        await FixtureProtocol.fixture.prepare([(200, child), (200, folder), (200, "{\"files\":[" + child + "]}")])
        let plan = try await fixtureClient(FixtureTokens()).planDownloads(ids: ["folder", "a"]) { value in await progress.record(value) }
        #expect(plan.items.map { $0.components.joined(separator: "/") } == ["Project", "Project/Selected.txt"])
        #expect(plan.issues.count == 1)
        #expect(plan.issues.first?.path == "Selected.txt")
        let latest = try #require(await progress.latest())
        #expect(latest.current == "Selected.txt")
        #expect(latest.discovered == 2)
        #expect(latest.failed == 1)
        #expect(await FixtureProtocol.fixture.allRequests().count == 3)
    }
}
