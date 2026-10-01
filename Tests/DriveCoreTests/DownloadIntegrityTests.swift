import Foundation
import Testing
@testable import DriveCore

@Test func streamedChecksumHandlesChunksEmptyFilesInvalidMetadataAndCancellation() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 120, count: 2 * 1_048_576 + 13).write(to: url)
    var file = DriveFile(id: "chunk-test", name: "Chunks.bin", mimeType: "application/octet-stream")
    file.sha256Checksum = "67DBA8E132CB5BAB6ABE6EE3F23725859BD6AAF3A75F51AEC0554E02F4764037"
    try validateDownloadChecksum(url, file: file)
    for invalid in ["", "xyz", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
        var malformed = file; malformed.sha256Checksum = invalid
        #expect(throws: MonitorError.self) { try validateDownloadChecksum(url, file: malformed) }
    }
    let selected = file
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try validateDownloadChecksum(url, file: selected)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    try Data().write(to: url)
    file.sha256Checksum = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    try validateDownloadChecksum(url, file: file)
    file.sha256Checksum = nil
    try validateDownloadChecksum(url, file: file)
    try FileManager.default.removeItem(at: url)
}
