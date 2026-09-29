import Foundation
import Darwin
import DriveCore

struct Measurement: Codable {
    let stage: String
    let seconds: Double
    let records: Int
    let peakResidentBytes: Int64
}
func report(_ stage: String, start: Date, records: Int) throws {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw MonitorError.invalid("getrusage failed with errno \(errno).") }
    let result = Measurement(stage: stage, seconds: Date().timeIntervalSince(start), records: records, peakResidentBytes: Int64(usage.ru_maxrss))
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(result) + Data([10]))
}
@main struct DriveBenchmarks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("drive-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try Database(path: directory.appendingPathComponent("synthetic.sqlite").path)
        let files: [DriveFile] = (0..<100_000).map { number in
            let folder = number < 1_000
            var file = DriveFile(id: "synthetic-\(number)", name: "Synthetic \(number)", mimeType: folder ? "application/vnd.google-apps.folder" : "application/pdf")
            file.parents = [folder ? "root" : "synthetic-\(number % 1000)"]
            file.trashed = false
            file.size = folder ? nil : String(number * 1024)
            file.modifiedTime = "2026-09-01T00:00:00Z"
            return file
        }
        var start = Date()
        try await database.stage(files, stream: "user")
        try await database.promote(stream: "user", cursor: "synthetic", detected: "2026-09-01T00:00:00Z")
        try report("sqlite_stage_promote", start: start, records: files.count)
        start = Date()
        let loaded = try await database.files()
        let facts = try await database.facts()
        guard loaded.count == files.count else { throw MonitorError.invalid("Benchmark lost indexed files.") }
        try report("sqlite_load_facts", start: start, records: loaded.count)
        start = Date()
        let sorted = try orderedFiles(loaded, order: .modified, ascending: false, facts: facts)
        guard sorted.count == loaded.count else { throw MonitorError.invalid("Benchmark sort lost files.") }
        try report("modified_sort", start: start, records: sorted.count)
        start = Date()
        var filter = FileFilter(); filter.minimumBytes = 90_000 * 1024
        let found = loaded.filter { matches($0, filter: filter) }
        guard found.count == 10_000 else { throw MonitorError.invalid("Benchmark size search returned the wrong count.") }
        try report("size_filter", start: start, records: found.count)
        start = Date()
        let navigation = try prepareNavigation(files: loaded, root: nil, roots: ["root"])
        guard navigation.roots["root"]?.count == 1_000 else { throw MonitorError.invalid("Benchmark folder hierarchy lost roots.") }
        try report("navigation_paths_and_tree", start: start, records: navigation.index.count)
        let sorting = Task.detached { try orderedFiles(loaded, order: .modified, ascending: false, facts: facts) }
        try await Task.sleep(for: .milliseconds(20))
        start = Date(); sorting.cancel()
        do { _ = try await sorting.value; throw MonitorError.invalid("Benchmark sort ignored cancellation.") }
        catch is CancellationError { try report("inflight_sort_cancellation", start: start, records: loaded.count) }
        try await database.close()
        try FileManager.default.removeItem(at: directory)
    }
}
