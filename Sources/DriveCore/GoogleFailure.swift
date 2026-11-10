import Foundation

enum GoogleFailureOperation: String {
    case fileListing = "Listing Drive files"
    case fileMetadata = "Reading Drive file metadata"
    case changeListing = "Reading Drive changes"
    case changeCursor = "Starting Drive change tracking"
    case activityQuery = "Reading Drive activity"
    case fileUpdate = "Updating the reviewed Drive item"
    case fileDownload = "Downloading a Drive file"
    case documentExport = "Exporting a Google document"
    case filePreview = "Previewing a Drive file"
    case documentPreview = "Previewing a Google document"
    case request = "Requesting Google Drive data"

    var apiName: String { self == .activityQuery ? "Google Drive Activity API" : "Google Drive API" }
}

func googleRequestOperation(_ path: String, method: String) -> GoogleFailureOperation {
    switch (method, path) {
    case ("GET", "files"): .fileListing
    case ("GET", "changes"): .changeListing
    case ("GET", "changes/startPageToken"): .changeCursor
    case ("POST", "activity"): .activityQuery
    case ("GET", let value) where value.hasPrefix("files/"): .fileMetadata
    case ("PATCH", let value) where value.hasPrefix("files/"): .fileUpdate
    default: .request
    }
}

private struct GoogleFailureResponse: Decodable {
    let error: GoogleFailureEnvelope
}

private struct GoogleFailureEnvelope: Decodable {
    let code: Int
    let errors: [GoogleFailureReasonRecord]?
    let details: [GoogleFailureDetail]?
}

private struct GoogleFailureReasonRecord: Decodable {
    let reason: String
    let domain: String

    var valid: Bool {
        reason.range(of: "^[A-Za-z][A-Za-z0-9_]{0,62}\\z", options: .regularExpression) != nil
            && domain.utf8.count <= 255
            && domain.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*\\z", options: .regularExpression) != nil
    }

    var validInfrastructure: Bool {
        valid && reason.range(of: "^[A-Z][A-Z0-9_]+[A-Z0-9]\\z", options: .regularExpression) != nil
    }
}

private enum GoogleFailureDetail: Decodable {
    case errorInfo(GoogleFailureReasonRecord)
    case unrelated

    private enum CodingKeys: String, CodingKey { case type = "@type" }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "type.googleapis.com/google.rpc.ErrorInfo" {
            self = .errorInfo(try GoogleFailureReasonRecord(from: decoder))
        } else { self = .unrelated }
    }
}

private enum GoogleFailureReason: String {
    case accessNotConfigured, authError, insufficientPermissions, insufficientFilePermissions
    case appNotAuthorizedToFile, domainPolicy, dailyLimitExceeded, userRateLimitExceeded, rateLimitExceeded
    case downloadQuotaExceeded, exportSizeLimitExceeded, fileNotDownloadable, fileNotExportable, notFound, backendError
    case downloadRestricted = "download_restricted_for_revision"
    case serviceDisabled = "SERVICE_DISABLED"
    case apiDisabled = "API_DISABLED"
    case scopeInsufficient = "ACCESS_TOKEN_SCOPE_INSUFFICIENT"
    case tokenExpired = "ACCESS_TOKEN_EXPIRED"
    case tokenInvalid = "ACCESS_TOKEN_INVALID"

    var infrastructure: Bool {
        switch self {
        case .serviceDisabled, .apiDisabled, .scopeInsufficient, .tokenExpired, .tokenInvalid: true
        default: false
        }
    }

    func permits(_ status: Int) -> Bool {
        switch self {
        case .authError, .tokenExpired, .tokenInvalid: status == 401
        case .notFound: status == 404
        case .backendError: (500...599).contains(status)
        case .rateLimitExceeded, .userRateLimitExceeded: status == 403 || status == 429
        default: status == 403
        }
    }

    func guidance(_ operation: GoogleFailureOperation) -> String {
        switch self {
        case .accessNotConfigured, .serviceDisabled, .apiDisabled:
            "The API is disabled or unavailable to this project. Verify \(operation.apiName) is enabled in the OAuth client's Google Cloud project; allow recent enablement to propagate before retrying."
        case .authError, .tokenExpired, .tokenInvalid:
            "Google rejected the connection's authorization. Open Connect Google Drive and sign in again before retrying."
        case .insufficientPermissions, .scopeInsufficient:
            "The connection does not authorize this request. Review the requested action and granted access in Connect Google Drive before signing in again."
        case .insufficientFilePermissions, .appNotAuthorizedToFile:
            "Google denied access to this item. Check its permissions in Google Drive and ask its owner for the access required by this action."
        case .domainPolicy:
            "The organization's policy blocks this app or action. Ask the Google Workspace administrator to review the policy before retrying."
        case .dailyLimitExceeded:
            "The project's daily API quota was exceeded. Ask the project owner to review Google Cloud quotas and wait for the quota to reset before retrying."
        case .userRateLimitExceeded, .rateLimitExceeded:
            "Google's request rate limit was reached. Wait before retrying; if this continues, ask the project owner to review API quotas."
        case .downloadQuotaExceeded:
            "Google's download quota was exceeded. Wait before downloading again and check the item's download availability in Google Drive."
        case .exportSizeLimitExceeded:
            "The document exceeds Google's export size limit. Open it in Google Drive and review available download options."
        case .downloadRestricted, .fileNotDownloadable, .fileNotExportable:
            "Google does not permit this download or export. Open the item in Google Drive to review its format and download restrictions."
        case .notFound:
            "The item is unavailable or inaccessible. Refresh the listing and check its location and permissions in Google Drive."
        case .backendError:
            "Google could not complete the request. Wait before retrying."
        }
    }
}

private func googleStatusGuidance(_ status: Int, operation: GoogleFailureOperation) -> String {
    switch status {
    case 400: "Google rejected the request. Review the requested action or search parameters before retrying."
    case 401: "Google rejected the connection's authorization. Open Connect Google Drive and sign in again before retrying."
    case 403: "Google denied this request. Check item permissions, organization policy and API access in Google Drive or Google Cloud Console."
    case 404: "The item is unavailable or inaccessible. Refresh the listing and check its location and permissions in Google Drive."
    case 410: operation == .changeListing || operation == .changeCursor
        ? "Google rejected the saved change cursor. Use Settings → Rebuild local index after reviewing its confirmation, then refresh."
        : "Google reports that the requested resource is no longer available. Refresh the listing and review the item's location and access before retrying."
    case 429: "Google's request rate limit was reached. Wait before retrying."
    case 500...599: "Google could not complete the request. Wait before retrying."
    default: "Google rejected this request. Refresh and review the requested action before retrying."
    }
}

/// Decode only bounded reason/domain/code fields from Google's documented error formats.
/// Public failures exclude provider messages, queries, metadata, resource IDs and raw bodies.
/// https://developers.google.com/workspace/drive/api/guides/handle-errors
/// https://docs.cloud.google.com/network-connectivity/docs/reference/networkconnectivity/rest/v1/ErrorInfo
func googleHTTPFailure(status: Int, responseData: Data, operation: GoogleFailureOperation) -> MonitorError {
    let confirmation = operation == .fileUpdate ? "The requested change is unconfirmed. Refresh the item in Google Drive before considering another attempt. " : ""
    let prefix = operation.rawValue + ". " + confirmation
    let guidance = googleStatusGuidance(status, operation: operation)
    guard !responseData.isEmpty else { return .http(status, prefix + "Google returned an empty error response. " + guidance) }
    guard responseData.count <= 4096 else { return .http(status, prefix + "Google's error response exceeded the 4096-byte diagnostic limit. " + guidance) }
    let response: GoogleFailureResponse
    do { response = try JSONDecoder().decode(GoogleFailureResponse.self, from: responseData) }
    catch { return .http(status, prefix + "Google returned a malformed or incomplete structured error response. " + guidance) }
    guard response.error.code == status else { return .http(status, prefix + "Google's structured error code did not match the HTTP status. " + guidance) }
    guard (response.error.errors?.count ?? 0) <= 16, (response.error.details?.count ?? 0) <= 16 else {
        return .http(status, prefix + "Google returned too many structured error details. " + guidance)
    }
    let legacy = response.error.errors ?? []
    let details = (response.error.details ?? []).compactMap { detail -> GoogleFailureReasonRecord? in
        guard case .errorInfo(let record) = detail else { return nil }
        return record
    }
    let records = legacy + details
    guard legacy.allSatisfy(\.valid), details.allSatisfy(\.validInfrastructure) else { return .http(status, prefix + "Google returned invalid structured reason fields. " + guidance) }
    guard !records.isEmpty else { return .http(status, prefix + "Google did not provide a structured error reason. " + guidance) }
    let legacyReasons: [GoogleFailureReason] = legacy.filter { ["global", "usageLimits"].contains($0.domain) }.compactMap { record in
        guard let reason = GoogleFailureReason(rawValue: record.reason), !reason.infrastructure else { return nil }
        return reason
    }
    let infrastructureReasons: [GoogleFailureReason] = details.filter { $0.domain == "googleapis.com" }.compactMap { record in
        guard let reason = GoogleFailureReason(rawValue: record.reason), reason.infrastructure else { return nil }
        return reason
    }
    let reasons = legacyReasons + infrastructureReasons
    guard let reason = reasons.first else { return .http(status, prefix + "Google returned an unrecognized structured error reason. " + guidance) }
    guard reason.permits(status) else { return .http(status, prefix + "Google's structured reason conflicted with the HTTP status. " + guidance) }
    return .http(status, prefix + "Reason: " + reason.rawValue + ". " + reason.guidance(operation))
}
