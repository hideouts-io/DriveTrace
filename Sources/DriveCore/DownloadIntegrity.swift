import Foundation
import CryptoKit

/// Verify Google's optional binary SHA-256 before committing a download. Missing checksums prove no integrity.
func validateDownloadChecksum(_ temporary: URL, file: DriveFile) throws {
    try Task.checkCancellation()
    guard let expected = file.sha256Checksum else { return }
    guard expected.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
        throw MonitorError.invalid("Google returned an invalid SHA-256 checksum for file \(file.id). Refresh its metadata before downloading again.")
    }
    let actual = try downloadedSHA256(temporary)
    guard actual == expected.lowercased() else {
        throw MonitorError.invalid("Download SHA-256 mismatch for file \(file.id): expected \(expected), received \(actual). The content may be damaged or the source changed during transfer. The destination was not changed; refresh and retry.")
    }
}

/// Bound each disk read to 1 MiB and check cancellation between chunks.
private func downloadedSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    var hash = SHA256()
    do {
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
    } catch {
        let cause = error
        do { try handle.close() }
        catch { throw MonitorError.invalid("Download checksum validation failed: \(cause.localizedDescription). Closing the temporary file also failed: \(error.localizedDescription)") }
        throw cause
    }
    try handle.close()
    try Task.checkCancellation()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
