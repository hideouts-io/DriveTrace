import Foundation

public struct FileDownload: Sendable {
    public let name: String
    public let exportMIME: String?
}

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
    let name = file.name.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))).joined(separator: "_")
    guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name != ".", name != ".." else { throw MonitorError.invalid("The file has no usable download name. Rename it in Google Drive first.") }
    let filename = format.map { name.lowercased().hasSuffix("." + $0.suffix) ? name : name + "." + $0.suffix } ?? name
    return FileDownload(name: filename, exportMIME: format?.mime)
}

extension GoogleClient {
    /// URLSession streams to disk. The destination is replaced only after a complete successful response.
    public func download(file selected: DriveFile, to destination: URL) async throws {
        guard destination.isFileURL else { throw MonitorError.invalid("Choose a local file destination for the download.") }
        let current = try await file(id: selected.id)
        guard current.name == selected.name, current.mimeType == selected.mimeType else { throw MonitorError.invalid("The file's name or type changed. Select Download again to review its new format and destination.") }
        let format = try fileDownload(current)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(current.id)\(format.exportMIME == nil ? "" : "/export")")!
        components.queryItems = format.exportMIME.map { [URLQueryItem(name: "mimeType", value: $0)] } ?? [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        var refresh = false
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let token = try await tokens.accessToken(forceRefresh: refresh)
            guard await tokens.grantedScopes().contains("https://www.googleapis.com/auth/drive") else { throw MonitorError.authentication("Downloading requires the optional file management connection. Choose View files and Move to Trash in the connection guide and sign in again.") }
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (temporary, response) = try await session.download(for: request)
                do {
                    guard let http = response as? HTTPURLResponse else { throw MonitorError.invalid("File download returned a non-HTTP response.") }
                    guard http.statusCode == 200 else {
                        let handle = try FileHandle(forReadingFrom: temporary)
                        let body = try handle.read(upToCount: 4096) ?? Data()
                        try handle.close()
                        throw MonitorError.http(http.statusCode, "Download file=\(current.id); export=\(format.exportMIME ?? "original"); response=\(String(decoding: body, as: UTF8.self))")
                    }
                    try Task.checkCancellation()
                    try saveDownloadedFile(temporary, to: destination)
                } catch {
                    try removeFailedDownload(temporary, cause: error)
                    throw error
                }
                try FileManager.default.removeItem(at: temporary)
                return
            } catch let MonitorError.http(status, _) where attempt < 3 && [401, 429, 500, 502, 503, 504].contains(status) {
                refresh = status == 401
                logger.warning("Download retry status=\(status) attempt=\(attempt + 1)")
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            } catch let error as URLError where attempt < 3 && [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) {
                logger.warning("Download network retry code=\(error.errorCode) attempt=\(attempt + 1)")
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw MonitorError.invalid("Download retries ended without a response.")
    }
}

/// Stage on the destination volume so replacing an existing file cannot expose a partial download.
func saveDownloadedFile(_ source: URL, to destination: URL) throws {
    let manager = FileManager.default
    let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
    do {
        let staged = staging.appendingPathComponent(UUID().uuidString)
        try manager.copyItem(at: source, to: staged)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly) }
        else { try manager.moveItem(at: staged, to: destination) }
    } catch {
        try removeFailedDownload(staging, cause: error)
        throw error
    }
    do { try manager.removeItem(at: staging) }
    catch { throw MonitorError.invalid("The download was saved, but its staging directory could not be removed: \(error.localizedDescription)") }
}

private func removeFailedDownload(_ url: URL, cause: Error) throws {
    do { try FileManager.default.removeItem(at: url) }
    catch { throw MonitorError.invalid("Download failed: \(cause.localizedDescription). Temporary-file cleanup also failed: \(error.localizedDescription)") }
}
