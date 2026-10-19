import Foundation
import OSLog

public protocol TokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
    func grantedScopes() async -> Set<String>
}
public struct ActivityPage: Decodable, Sendable { public let activities: [JSONValue]?; public let nextPageToken: String? }
public actor GoogleClient {
    let tokens: any TokenProvider
    let session: URLSession
    let saveNewFile: @Sendable (URL, URL) throws -> Void
    let logger = Logger(subsystem: "local.driveexplorer", category: "GoogleAPI")
    public static let fileFields = "id,name,mimeType,parents,driveId,size,quotaBytesUsed,createdTime,modifiedTime,sharedWithMeTime,trashed,shared,owners(displayName,emailAddress,permissionId),webViewLink,md5Checksum,sha1Checksum,sha256Checksum,fileExtension,shortcutDetails,permissions(id,type,role,emailAddress,domain,allowFileDiscovery),ownedByMe,capabilities(canDownload,canTrash)"
    public init(tokens: any TokenProvider, session: URLSession) {
        self.init(tokens: tokens, session: session, saveNewFile: { try saveNewDownloadedFile($0, to: $1) })
    }
    /// Keep new-file filesystem commits separate from transport; the public client uses exclusive production saves.
    init(tokens: any TokenProvider, session: URLSession, saveNewFile: @escaping @Sendable (URL, URL) throws -> Void) {
        self.tokens = tokens; self.session = session; self.saveNewFile = saveNewFile
    }
    func request<T: Decodable & Sendable>(_ path: String, query: [String: String], body: Data?, method: String, requiredScope: String?, type: T.Type) async throws -> T {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/\(path)")!
        if path == "activity" { components = URLComponents(string: "https://driveactivity.googleapis.com/v2/activity:query")! }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw MonitorError.invalid("Cannot form Google endpoint URL for \(path).") }
        var refresh = false
        var refreshed = false
        var retryWait: TimeInterval = 0
        // Activity POST is a read query; an unconfirmed Trash PATCH must never be replayed.
        let retryableRead = method == "GET" || (method == "POST" && path == "activity")
        for attempt in 0..<4 {
            try Task.checkCancellation()
            var request = URLRequest(url: url); request.timeoutInterval = 60
            let accessToken = try await tokens.accessToken(forceRefresh: refresh)
            refresh = false
            if let requiredScope, !(await tokens.grantedScopes()).contains(requiredScope) {
                throw MonitorError.authentication("This action requires file management access. Open Connect Google Drive → Sign in, choose View files and Move to Trash, and complete Google consent.")
            }
            request.httpMethod = method
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let data: Data; let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch let error as URLError {
                guard retryableRead, attempt < 3, [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) else { throw error }
                retryWait = try await waitForGoogleRetry(retryAfter: nil, attempt: attempt, waited: retryWait, failure: error, logger: logger); continue
            }
            guard let http = response as? HTTPURLResponse else { throw MonitorError.invalid("Google \(path) returned a non-HTTP response.") }
            if (200..<300).contains(http.statusCode) { return try JSONDecoder().decode(T.self, from: data) }
            let failure = googleHTTPFailure(status: http.statusCode, responseData: data, operation: googleRequestOperation(path, method: method))
            guard attempt < 3,
                  (http.statusCode == 401 && !refreshed) || (retryableRead && [429, 500, 502, 503, 504].contains(http.statusCode)) else { throw failure }
            refresh = http.statusCode == 401
            if refresh { refreshed = true }
            retryWait = try await waitForGoogleRetry(retryAfter: http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt, waited: retryWait, failure: failure, logger: logger)
        }
        throw MonitorError.invalid("Google retry loop exited without a response.")
    }
    public func files(query: String, drive: String?, page: String?) async throws -> FilePage {
        var params = ["q": query, "pageSize": "1000", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true", "fields": "nextPageToken,incompleteSearch,files(\(Self.fileFields))", "corpora": drive == nil ? "user" : "drive"]
        if let drive { params["driveId"] = drive }; if let page { params["pageToken"] = page }
        let response = try await request("files", query: params, body: nil, method: "GET", requiredScope: nil, type: FilePage.self)
        for file in response.files ?? [] { try validateFile(file) }
        return response
    }
    public func file(id: String) async throws -> DriveFile {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw MonitorError.invalid("File ID contains invalid URL characters.") }
        let file = try await request("files/\(id)", query: ["supportsAllDrives": "true", "fields": Self.fileFields], body: nil, method: "GET", requiredScope: nil, type: DriveFile.self)
        try validateFile(file)
        guard id == "root" || file.id == id else { throw MonitorError.invalid("Google returned metadata for a different file ID than requested.") }
        return file
    }
    public func startToken(drive: String?) async throws -> String {
        var query = ["supportsAllDrives": "true"]
        if let drive { query["driveId"] = drive }
        return try await request("changes/startPageToken", query: query, body: nil, method: "GET", requiredScope: nil, type: StartPage.self).startPageToken
    }
    public func changes(drive: String?, page: String) async throws -> ChangePage {
        var query = ["pageToken": page, "pageSize": "1000", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true", "includeRemoved": "true", "fields": "nextPageToken,newStartPageToken,changes(changeType,time,fileId,removed,driveId,file(\(Self.fileFields)))"]
        if let drive { query["driveId"] = drive }
        let response = try await request("changes", query: query, body: nil, method: "GET", requiredScope: nil, type: ChangePage.self)
        for change in response.changes ?? [] { if let file = change.file { try validateFile(file) } }
        return response
    }
    public func activity(ancestor: String, since: String, page: String?) async throws -> ActivityPage {
        var values: [String: JSONValue] = ["ancestorName": .string("items/" + ancestor), "pageSize": .number(100), "filter": .string("time >= \"\(since)\""), "consolidationStrategy": .object(["none": .object([:])])]
        if let page { values["pageToken"] = .string(page) }
        return try await request("activity", query: [:], body: JSONEncoder().encode(JSONValue.object(values)), method: "POST", requiredScope: nil, type: ActivityPage.self)
    }
}
