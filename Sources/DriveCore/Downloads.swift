import Foundation
import Darwin

public struct FileDownload: Sendable {
    public let name: String
    public let exportMIME: String?
}

public struct DownloadCleanupFailure: Sendable {
    public let temporary: URL
    public let cause: any Error
}

/// The destination was committed successfully. Retrying cannot resolve leftover temporary data.
public struct SavedDownloadCleanupError: LocalizedError {
    public let destination: URL
    public let failures: [DownloadCleanupFailure]
    public var errorDescription: String? {
        let details = failures.map { "\($0.temporary.path): \($0.cause.localizedDescription)" }.joined(separator: " · ")
        return "The download was saved at \(destination.path), but temporary data could not be removed: \(details). Review the saved file before downloading again. Check the temporary paths and their permissions before removing leftover data."
    }
}

/// The transfer failed before commit and its temporary output also needs attention.
public struct FailedDownloadCleanupError: LocalizedError {
    public let temporary: URL
    public let cause: any Error
    public let cleanup: any Error
    public var cancelled: Bool { downloadWasCancelled(cause) }
    public var errorDescription: String? {
        "Download \(cancelled ? "cancelled before completion" : "failed"): \(cause.localizedDescription). Temporary data could not be removed at \(temporary.path): \(cleanup.localizedDescription). Review that temporary location and correct its permissions before removing leftover data or retrying."
    }
}

public struct DownloadDestinationError: LocalizedError {
    public let destination: URL
    public let cause: any Error
    public var errorDescription: String? {
        "Could not prepare the download destination at \(destination.path): \(cause.localizedDescription). Choose an existing local folder you can open and write to, with available space. Correct its permissions or choose another folder; existing files are unchanged."
    }
}

private let maximumDownloadNameBytes = 240

/// Fixed, editable document exports; Drive names are suggested filenames, never local paths.
public func fileDownload(_ file: DriveFile) throws -> FileDownload {
    guard file.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw MonitorError.invalid("Download file ID contains invalid URL characters.") }
    guard !file.isFolder, file.shortcutDetails == nil else { throw MonitorError.invalid("Download individual files inside this folder, or inspect the shortcut target first.") }
    guard file.capabilities?.canDownload == true else { throw MonitorError.invalid("Google does not allow downloading this file. Check its owner or Shared Drive download restrictions.") }
    let format: (mime: String, suffix: String)?
    switch file.mimeType {
    case "application/vnd.google-apps.document": format = ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")
    case "application/vnd.google-apps.spreadsheet": format = ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx")
    case "application/vnd.google-apps.presentation": format = ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx")
    case "application/vnd.google-apps.drawing": format = ("application/pdf", "pdf")
    default:
        guard !file.mimeType.hasPrefix("application/vnd.google-apps.") else { throw MonitorError.invalid("This Google file type does not support this app's download formats. Open it in Google Drive.") }
        format = nil
    }
    let name = try downloadName(file.name)
    let filename: String
    if let format, !name.lowercased().hasSuffix("." + format.suffix) {
        filename = try downloadNameAppendingSuffix(name, suffix: "." + format.suffix)
    } else { filename = name }
    return FileDownload(name: filename, exportMIME: format?.mime)
}

public func downloadName(_ name: String) throws -> String {
    let value = name.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))).joined(separator: "_")
    guard !value.trimmingCharacters(in: .whitespaces).isEmpty, value != ".", value != "..", value.utf8.count <= maximumDownloadNameBytes else { throw MonitorError.invalid("The file or folder has no usable local name, or its name exceeds \(maximumDownloadNameBytes) UTF-8 bytes. Rename it in Google Drive first.") }
    return value
}

/// Preserve the generated suffix and shorten only complete Unicode characters in the original stem.
func downloadNameAppendingSuffix(_ stem: String, suffix: String) throws -> String {
    let remaining = maximumDownloadNameBytes - suffix.utf8.count
    guard remaining > 0 else { throw MonitorError.invalid("The generated filename suffix or preserved extension leaves no room for a name within \(maximumDownloadNameBytes) UTF-8 bytes. Use a shorter original filename extension.") }
    var shortened = ""
    var bytes = 0
    for character in stem {
        let count = String(character).utf8.count
        guard bytes + count <= remaining else { break }
        shortened.append(character); bytes += count
    }
    guard !shortened.isEmpty else { throw MonitorError.invalid("The filename stem cannot retain a complete Unicode character alongside its generated suffix within \(maximumDownloadNameBytes) UTF-8 bytes. Use a shorter original name or extension.") }
    return try downloadName(shortened + suffix)
}

extension GoogleClient {
    /// URLSession streams to disk. The destination is replaced only after a complete successful response.
    public func download(file selected: DriveFile, to destination: URL) async throws {
        guard destination.isFileURL else { throw MonitorError.invalid("Choose a local file destination for the download.") }
        try await transferDownload(file: selected, destination: destination) { try saveDownloadedFile($0, to: destination) }
    }
    public func downloadNewFile(file: DriveFile, to destination: URL) async throws {
        guard destination.isFileURL else { throw MonitorError.invalid("Choose a local file destination for the download.") }
        let save = saveNewFile
        try await transferDownload(file: file, destination: destination) { try save($0, destination) }
    }
    private func transferDownload(file selected: DriveFile, destination: URL, save: @Sendable (URL) throws -> Void) async throws {
        let current = try await file(id: selected.id)
        guard current.name == selected.name, current.mimeType == selected.mimeType else { throw MonitorError.invalid("The file's name or type changed. Select Download again to review its new format and destination.") }
        let format = try fileDownload(current)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(current.id)\(format.exportMIME == nil ? "" : "/export")")!
        components.queryItems = format.exportMIME.map { [URLQueryItem(name: "mimeType", value: $0)] } ?? [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        var refresh = false
        var refreshed = false
        var retryWait: TimeInterval = 0
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: refresh)
            refresh = false
            guard await tokens.grantedScopes().contains("https://www.googleapis.com/auth/drive") else { throw MonitorError.authentication("Downloading requires the optional file management connection. Choose View files and Move to Trash in the connection guide and sign in again.") }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            var retryAfter: String?
            do {
                let (temporary, response) = try await session.download(for: request)
                do {
                    guard let http = response as? HTTPURLResponse else { throw MonitorError.invalid("File download returned a non-HTTP response.") }
                    retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                    guard http.statusCode == 200 else {
                        let handle = try FileHandle(forReadingFrom: temporary)
                        let body = try withDownloadFileHandle(handle, file: temporary, operation: .errorResponse) { try $0.read(upToCount: 4097) ?? Data() }
                        throw googleHTTPFailure(status: http.statusCode, responseData: body, operation: format.exportMIME == nil ? .fileDownload : .documentExport)
                    }
                    try Task.checkCancellation()
                    // Workspace metadata size is not the size of a converted export.
                    if format.exportMIME == nil, let recordedSize = current.size {
                        guard let expected = Int64(recordedSize), expected >= 0 else {
                            throw MonitorError.invalid("Google returned an invalid byte size for file \(current.id): \(recordedSize). Refresh its metadata before downloading again.")
                        }
                        let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        guard let actual, Int64(actual) == expected else {
                            throw MonitorError.invalid("Download size mismatch for file \(current.id): Google metadata expected \(expected) bytes, received \(actual.map(String.init) ?? "unknown"). The response may be incomplete or the source changed during transfer. The destination was not changed; refresh and retry.")
                        }
                    }
                    if format.exportMIME == nil { try validateDownloadChecksum(temporary, file: current) }
                    try save(temporary)
                } catch let failure as SavedDownloadCleanupError {
                    do { try removeSavedDownloadTemporary(temporary, destination: destination) }
                    catch { throw SavedDownloadCleanupError(destination: destination, failures: failure.failures + error.failures) }
                    throw failure
                } catch {
                    try removeFailedDownload(temporary, cause: error)
                    throw error
                }
                try removeSavedDownloadTemporary(temporary, destination: destination)
                return
            } catch let failure as MonitorError where attempt < 3 {
                guard case let .http(status, _) = failure, [401, 429, 500, 502, 503, 504].contains(status) else { throw failure }
                guard status != 401 || !refreshed else { throw failure }
                refresh = status == 401
                if refresh { refreshed = true }
                retryWait = try await waitForGoogleRetry(retryAfter: retryAfter, attempt: attempt, waited: retryWait, failure: failure, logger: logger)
            } catch let error as URLError where attempt < 3 && [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) {
                retryWait = try await waitForGoogleRetry(retryAfter: nil, attempt: attempt, waited: retryWait, failure: error, logger: logger)
            }
        }
        throw MonitorError.invalid("Download retries ended without a response.")
    }
}

/// Stage on the destination volume so replacing an existing file cannot expose a partial download.
func saveDownloadedFile(_ source: URL, to destination: URL) throws {
    try stageDownloadedFile(source, destination: destination) { staged in
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly) }
        else { try manager.moveItem(at: staged, to: destination) }
    }
}

/// Commit on the destination volume without replacing an existing file or symlink.
func saveNewDownloadedFile(_ source: URL, to destination: URL) throws {
    try stageDownloadedFile(source, destination: destination) { staged in
        guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            throw MonitorError.invalid("Could not commit the completed download at \(destination.path) without replacing an existing item: \(String(cString: strerror(code))) (errno \(code)). Choose a writable volume supporting exclusive rename; existing files are never overwritten.")
        }
    }
}

/// Reject incompatible destinations before discovery or network content transfer.
public func validateBatchDestination(_ directory: URL) throws {
    guard directory.isFileURL else { throw MonitorError.invalid("Choose a local folder for batch downloads.") }
    let values: URLResourceValues
    do { values = try directory.resourceValues(forKeys: [.isDirectoryKey, .volumeSupportsExclusiveRenamingKey]) }
    catch { throw DownloadDestinationError(destination: directory, cause: error) }
    guard values.isDirectory == true else { throw MonitorError.invalid("The download destination is not a directory: \(directory.path). Choose an existing folder.") }
    guard values.volumeSupportsExclusiveRenaming == true else {
        throw MonitorError.invalid("The destination volume does not report support for exclusive rename: \(directory.path). Choose a supported local volume, such as APFS, so completed files can be saved without overwriting existing items.")
    }
    // This is an early usability check; mkdir and exclusive commit still enforce the current filesystem state.
    guard access(directory.path, W_OK | X_OK) == 0 else {
        let code = errno
        throw DownloadDestinationError(destination: directory, cause: NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
    }
}

func stageDownloadedFile(_ source: URL, destination: URL, commit: (URL) throws -> Void) throws {
    try Task.checkCancellation()
    let manager = FileManager.default
    let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
    try stageDownloadedFile(source, destination: destination, staging: staging, commit: commit)
}

/// Consume a caller-owned staging directory; failures remove unfinished content, successful commits keep the destination.
func stageDownloadedFile(_ source: URL, destination: URL, staging: URL, commit: (URL) throws -> Void) throws {
    do {
        let staged = staging.appendingPathComponent(UUID().uuidString)
        try copyDownloadChunks(source, to: staged)
        try Task.checkCancellation()
        try commit(staged)
    } catch {
        try removeFailedDownload(staging, cause: error)
        throw error
    }
    try removeSavedDownloadTemporary(staging, destination: destination)
}

/// Cleanup is a separate failure after a successful commit; preserve that outcome and its cause.
func removeSavedDownloadTemporary(_ temporary: URL, destination: URL) throws(SavedDownloadCleanupError) {
    do { try FileManager.default.removeItem(at: temporary) }
    catch { throw SavedDownloadCleanupError(destination: destination, failures: [DownloadCleanupFailure(temporary: temporary, cause: error)]) }
}

/// Copy to a new private staging file with bounded memory and cancellation between disk operations.
func copyDownloadChunks(_ source: URL, to destination: URL) throws {
    try Task.checkCancellation()
    let reader = try FileHandle(forReadingFrom: source)
    try withDownloadFileHandle(reader, file: source, operation: .stagingInput) { reader in
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            throw MonitorError.invalid("Could not create download staging file at \(destination.path): \(String(cString: strerror(code))) (errno \(code)). Choose a writable destination with available space.")
        }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try withDownloadFileHandle(writer, file: destination, operation: .stagingOutput) { writer in
            while true {
                try Task.checkCancellation()
                // Foundation read/write buffers must leave their autorelease pool after each bounded chunk.
                let copied = try autoreleasepool {
                    guard let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
                    try Task.checkCancellation()
                    try writer.write(contentsOf: chunk)
                    return true
                }
                if !copied { break }
            }
        }
    }
    try Task.checkCancellation()
}

func removeFailedDownload(_ url: URL, cause: any Error) throws {
    do { try FileManager.default.removeItem(at: url) }
    catch { throw FailedDownloadCleanupError(temporary: url, cause: cause, cleanup: error) }
}
