import Foundation

public struct PreviewContent: Sendable {
    public let data: Data
    public let fileExtension: String
    public init(data: Data, fileExtension: String) { self.data = data; self.fileExtension = fileExtension }
}

extension GoogleClient {
    /// Re-read the capability and identity immediately before the confirmed, recoverable mutation.
    public func moveToTrash(confirmed: DriveFile) async throws -> DriveFile {
        let current = try await file(id: confirmed.id)
        guard current.name == confirmed.name, current.parents == confirmed.parents else {
            throw MonitorError.invalid("This item's name or location changed after confirmation. Refresh and review it before moving it to Trash.")
        }
        guard current.capabilities?.canTrash == true, current.trashed != true else {
            throw MonitorError.invalid("Google does not currently allow moving this item to Trash, or it is already trashed. Refresh its metadata and check your ownership or Shared Drive role.")
        }
        let updated = try await request("files/\(current.id)", query: ["supportsAllDrives": "true", "fields": Self.fileFields], body: Data(#"{"trashed":true}"#.utf8), method: "PATCH", requiredScope: "https://www.googleapis.com/auth/drive", type: DriveFile.self)
        try validateFile(updated)
        guard updated.id == confirmed.id, updated.trashed == true else {
            throw MonitorError.invalid("Google did not confirm that the requested item was trashed. Refresh before attempting the action again.")
        }
        return updated
    }

    /// Download only on explicit preview request. Workspace documents are exported as PDF.
    public func previewContent(file: DriveFile) async throws -> PreviewContent {
        let format = try previewFormat(file: file)
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(file.id)\(format.exportPDF ? "/export" : "")")!
        url.queryItems = format.exportPDF ? [URLQueryItem(name: "mimeType", value: "application/pdf")] : [URLQueryItem(name: "alt", value: "media"), URLQueryItem(name: "supportsAllDrives", value: "true")]
        let limit = 20 * 1024 * 1024
        var refresh = false
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let access = try await tokens.accessToken(forceRefresh: refresh)
            guard await tokens.grantedScopes().contains("https://www.googleapis.com/auth/drive") else {
                throw MonitorError.authentication("File previews require the optional file management connection. Choose View files and Move to Trash in the connection guide and sign in again.")
            }
            var request = URLRequest(url: url.url!); request.timeoutInterval = 60
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw MonitorError.invalid("Preview returned a non-HTTP response.") }
                guard (200..<300).contains(http.statusCode) else {
                    var message = Data()
                    for try await byte in bytes { message.append(byte); if message.count >= 4096 { break } }
                    throw MonitorError.http(http.statusCode, "File preview; response=\(String(decoding: message, as: UTF8.self))")
                }
                guard response.expectedContentLength <= limit else { throw MonitorError.invalid("This file exceeds the 20 MiB in-app preview limit. Open it in Google Drive instead.") }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < limit else { throw MonitorError.invalid("This download exceeded the 20 MiB preview limit. Open it in Google Drive instead.") }
                    data.append(byte)
                    if data.count.isMultiple(of: 65536) { try Task.checkCancellation() }
                }
                try Task.checkCancellation()
                return PreviewContent(data: data, fileExtension: format.fileExtension)
            } catch let MonitorError.http(status, _) where attempt < 3 && [401, 429, 500, 502, 503, 504].contains(status) {
                refresh = status == 401
                logger.warning("Preview retry status=\(status) attempt=\(attempt + 1)")
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            } catch let failure as URLError where attempt < 3 && [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(failure.code) {
                logger.warning("Preview network retry code=\(failure.errorCode) attempt=\(attempt + 1)")
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw MonitorError.invalid("Preview retries ended without a response.")
    }
}

public func previewFormat(file: DriveFile) throws -> (exportPDF: Bool, fileExtension: String) {
    guard file.id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw MonitorError.invalid("Preview file ID is invalid.") }
    guard !file.isFolder, file.shortcutDetails == nil else { throw MonitorError.invalid("Browse this folder or inspect the shortcut target before requesting a preview.") }
    guard file.capabilities?.canDownload == true else { throw MonitorError.invalid("Google has not granted download/export permission for this file. Open it in Google Drive to inspect access restrictions.") }
    let pdfTypes: Set<String> = ["application/vnd.google-apps.document", "application/vnd.google-apps.spreadsheet", "application/vnd.google-apps.presentation", "application/vnd.google-apps.drawing"]
    if pdfTypes.contains(file.mimeType) { return (true, "pdf") }
    guard !file.mimeType.hasPrefix("application/vnd.google-apps.") else { throw MonitorError.invalid("This Google file type has no supported native preview. Open it in Google Drive.") }
    guard file.bytes.map({ $0 <= 20 * 1024 * 1024 }) != false else { throw MonitorError.invalid("This file exceeds the 20 MiB in-app preview limit. Open it in Google Drive instead.") }
    let suffix = (file.name as NSString).pathExtension.lowercased()
    guard !suffix.isEmpty, suffix.count <= 16, suffix.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil else {
        throw MonitorError.invalid("This file has no supported filename extension for Quick Look. Open it in Google Drive instead.")
    }
    return (false, suffix)
}
