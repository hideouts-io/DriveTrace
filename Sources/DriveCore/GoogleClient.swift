import Foundation
import OSLog

public protocol TokenProvider: Sendable { func accessToken(forceRefresh: Bool) async throws -> String }
public struct ActivityPage: Decodable, Sendable { public let activities: [JSONValue]?; public let nextPageToken: String? }
public actor GoogleClient {
    private let tokens: any TokenProvider
    private let session: URLSession
    private let logger = Logger(subsystem: "local.driveexplorer", category: "GoogleAPI")
    public static let fileFields = "id,name,mimeType,parents,driveId,size,quotaBytesUsed,createdTime,modifiedTime,sharedWithMeTime,trashed,shared,owners(displayName,emailAddress,permissionId),webViewLink,md5Checksum,sha1Checksum,sha256Checksum,fileExtension,shortcutDetails,permissions(id,type,role,emailAddress,domain,allowFileDiscovery),ownedByMe"
    public init(tokens: any TokenProvider, session: URLSession) { self.tokens = tokens; self.session = session }
    private func request<T: Decodable & Sendable>(_ path: String, query: [String: String], body: Data?, type: T.Type) async throws -> T {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/\(path)")!
        if path == "activity" { components = URLComponents(string: "https://driveactivity.googleapis.com/v2/activity:query")! }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw MonitorError.invalid("Cannot form Google endpoint URL for \(path).") }
        var refresh = false
        for attempt in 0..<4 {
            try Task.checkCancellation()
            var request = URLRequest(url: url); request.timeoutInterval = 60
            request.setValue("Bearer \(try await tokens.accessToken(forceRefresh: refresh))", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let data: Data; let response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch let error as URLError {
                guard attempt < 3, [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(error.code) else { throw error }
                logger.warning("Transient network failure; retry attempt=\(attempt + 1) code=\(error.errorCode)")
                try await Task.sleep(for: .seconds(pow(2, Double(attempt)))); continue
            }
            guard let http = response as? HTTPURLResponse else { throw MonitorError.invalid("Google \(path) returned a non-HTTP response.") }
            if (200..<300).contains(http.statusCode) { return try JSONDecoder().decode(T.self, from: data) }
            let failure = MonitorError.http(http.statusCode, "\(path); query=\(query.filter { $0.key != "pageToken" }); response=\(String(decoding: data.prefix(4096), as: UTF8.self))")
            guard attempt < 3, [401, 429, 500, 502, 503, 504].contains(http.statusCode) else { throw failure }
            refresh = http.statusCode == 401
            logger.warning("Google request retry status=\(http.statusCode) attempt=\(attempt + 1)")
            let delay = min(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt)), 60)
            try await Task.sleep(for: .seconds(delay))
        }
        throw MonitorError.invalid("Google retry loop exited without a response.")
    }
    public func files(query: String, drive: String?, page: String?) async throws -> FilePage {
        var params = ["q": query, "pageSize": "1000", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true", "fields": "nextPageToken,incompleteSearch,files(\(Self.fileFields))", "corpora": drive == nil ? "user" : "drive"]
        if let drive { params["driveId"] = drive }; if let page { params["pageToken"] = page }
        let response = try await request("files", query: params, body: nil, type: FilePage.self)
        for file in response.files ?? [] { try validateFile(file) }
        return response
    }
    public func file(id: String) async throws -> DriveFile {
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw MonitorError.invalid("File ID contains invalid URL characters.") }
        let file = try await request("files/\(id)", query: ["supportsAllDrives": "true", "fields": Self.fileFields], body: nil, type: DriveFile.self)
        try validateFile(file); return file
    }
    public func startToken(drive: String?) async throws -> String {
        var query = ["supportsAllDrives": "true"]
        if let drive { query["driveId"] = drive }
        return try await request("changes/startPageToken", query: query, body: nil, type: StartPage.self).startPageToken
    }
    public func changes(drive: String?, page: String) async throws -> ChangePage {
        var query = ["pageToken": page, "pageSize": "1000", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true", "includeRemoved": "true", "fields": "nextPageToken,newStartPageToken,changes(changeType,time,fileId,removed,driveId,file(\(Self.fileFields)))"]
        if let drive { query["driveId"] = drive }
        let response = try await request("changes", query: query, body: nil, type: ChangePage.self)
        for change in response.changes ?? [] { if let file = change.file { try validateFile(file) } }
        return response
    }
    public func activity(ancestor: String, since: String, page: String?) async throws -> ActivityPage {
        var values: [String: JSONValue] = ["ancestorName": .string("items/" + ancestor), "pageSize": .number(100), "filter": .string("time >= \"\(since)\""), "consolidationStrategy": .object(["none": .object([:])])]
        if let page { values["pageToken"] = .string(page) }
        return try await request("activity", query: [:], body: JSONEncoder().encode(JSONValue.object(values)), type: ActivityPage.self)
    }
}
