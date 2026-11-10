import Foundation
import Testing
@testable import DriveCore

private func failureMessage(status: Int, body: String, operation: GoogleFailureOperation) throws -> String {
    let failure = googleHTTPFailure(status: status, responseData: Data(body.utf8), operation: operation)
    guard case .http(let receivedStatus, let message) = failure else {
        throw MonitorError.invalid("Google diagnostic did not retain its HTTP failure type.")
    }
    #expect(receivedStatus == status)
    return message
}

@Suite struct GoogleFailureTests {
    @Test func knownLegacyReasonsRetainStatusAndActionableGuidanceWithoutProviderFields() throws {
        let cases: [(Int, String, GoogleFailureOperation, String)] = [
            (401, "authError", .fileMetadata, "sign in again"),
            (403, "insufficientPermissions", .fileDownload, "granted access"),
            (403, "insufficientFilePermissions", .fileUpdate, "ask its owner"),
            (403, "domainPolicy", .activityQuery, "administrator"),
            (403, "exportSizeLimitExceeded", .documentExport, "export size limit"),
            (403, "fileNotDownloadable", .documentPreview, "download restrictions"),
            (429, "userRateLimitExceeded", .fileListing, "rate limit"),
            (404, "notFound", .fileMetadata, "unavailable or inaccessible"),
            (503, "backendError", .fileDownload, "Wait before retrying")
        ]
        let privateValues = ["private_message_canary", "private_file_canary", "private_query_canary", "private_token_canary"]
        for (status, reason, operation, guidance) in cases {
            let body = """
            {"error":{"code":\(status),"message":"private_message_canary","errors":[{"domain":"global","reason":"\(reason)","message":"private_message_canary","location":"private_query_canary"}],"resource":"private_file_canary","token":"private_token_canary"}}
            """
            let message = try failureMessage(status: status, body: body, operation: operation)
            #expect(message.hasPrefix(operation.rawValue))
            #expect(message.contains("Reason: " + reason))
            #expect(message.contains(guidance))
            for value in privateValues { #expect(!message.contains(value)) }
        }
    }

    @Test func errorInfoGuidanceUsesTheRequestedAPIAndIgnoresUnrelatedDetails() throws {
        let body = #"{"error":{"code":403,"message":"private_message_canary","details":[{"@type":"type.googleapis.com/google.rpc.Help","links":[{"url":"https://example.test/private_resource_canary"}]},{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"googleapis.com","metadata":{"service":"private_service_canary","consumer":"private_token_canary"}}]}}"#
        for operation in [GoogleFailureOperation.activityQuery, .fileMetadata, .documentExport] {
            let message = try failureMessage(status: 403, body: body, operation: operation)
            #expect(message.contains("Reason: SERVICE_DISABLED"))
            #expect(message.contains("Verify " + operation.apiName + " is enabled"))
            for value in ["private_message_canary", "private_resource_canary", "private_service_canary", "private_token_canary"] {
                #expect(!message.contains(value))
            }
        }
        let scopeBody = #"{"error":{"code":403,"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT","domain":"googleapis.com"}]}}"#
        #expect(try failureMessage(status: 403, body: scopeBody, operation: .filePreview).contains("granted access"))
        let quotaBody = #"{"error":{"code":403,"errors":[{"reason":"rateLimitExceeded","domain":"usageLimits"}]}}"#
        #expect(try failureMessage(status: 403, body: quotaBody, operation: .fileListing).contains("rate limit"))
    }

    @Test func goneResponsesRecommendRebuildingOnlyForChangeTracking() {
        let body = Data(#"{"error":{"code":410}}"#.utf8)
        for operation in [GoogleFailureOperation.changeListing, .changeCursor] {
            let message = googleHTTPFailure(status: 410, responseData: body, operation: operation).localizedDescription
            #expect(message.contains("HTTP 410"))
            #expect(message.contains("Rebuild local index"))
        }
        for operation in [GoogleFailureOperation.fileDownload, .documentExport, .filePreview, .documentPreview, .fileMetadata] {
            let message = googleHTTPFailure(status: 410, responseData: body, operation: operation).localizedDescription
            #expect(message.contains("HTTP 410"))
            #expect(!message.contains("Rebuild"))
            #expect(!message.contains("saved cursor"))
        }
    }

    @Test func invalidSchemasKeepHTTPStatusAndNeverExposeUnrecognizedProviderContent() throws {
        let cases: [(String, String)] = [
            ("", "empty error response"),
            ("not-json-private_payload_canary", "malformed or incomplete"),
            (#"{"error":{"message":"private_payload_canary"}}"#, "malformed or incomplete"),
            (#"{"error":{"code":"403","message":"private_payload_canary"}}"#, "malformed or incomplete"),
            (#"{"error":{"code":404,"errors":[{"reason":"notFound","domain":"global"}]}}"#, "did not match the HTTP status"),
            (#"{"error":{"code":403}}"#, "did not provide a structured error reason"),
            (#"{"error":{"code":403,"errors":[{"reason":"private_payload_canary","domain":"global"}]}}"#, "unrecognized structured error reason"),
            (#"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions","domain":"private-payload-canary.example"}]}}"#, "unrecognized structured error reason"),
            (#"{"error":{"code":403,"errors":[{"reason":"insufficientPermissions","domain":"googleapis.com"}]}}"#, "unrecognized structured error reason"),
            (#"{"error":{"code":403,"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"global"}]}}"#, "unrecognized structured error reason"),
            (#"{"error":{"code":403,"errors":[{"reason":"SERVICE_DISABLED","domain":"global"}]}}"#, "unrecognized structured error reason"),
            (#"{"error":{"code":403,"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"domainPolicy","domain":"googleapis.com"}]}}"#, "invalid structured reason fields"),
            (#"{"error":{"code":403,"errors":[{"reason":"domainPolicy\n","domain":"global"}]}}"#, "invalid structured reason fields"),
            (#"{"error":{"code":403,"errors":[{"reason":"domainPolicy","domain":"global\n"}]}}"#, "invalid structured reason fields"),
            (#"{"error":{"code":403,"errors":[{"reason":"notFound","domain":"global"}]}}"#, "conflicted with the HTTP status"),
            (#"{"error":{"code":403,"errors":[{"reason":"private_payload_canary<","domain":"global"}]}}"#, "invalid structured reason fields"),
            (#"{"error":{"code":403,"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED"}]}}"#, "malformed or incomplete"),
            (#"{"error":{"code":403,"details":[{"@type":"type.googleapis.com/google.rpc.Help","private":"private_payload_canary"}]}}"#, "did not provide a structured error reason")
        ]
        for (body, explanation) in cases {
            let message = try failureMessage(status: 403, body: body, operation: .fileListing)
            #expect(message.contains(explanation))
            #expect(message.contains("Google denied this request"))
            #expect(!message.contains("private_payload_canary"))
            #expect(!message.contains("private-payload-canary.example"))
            #expect(!message.contains("Reason:"))
        }
    }

    @Test func oversizedResponsesAndExcessiveReasonsStopAtTheDiagnosticBoundary() throws {
        let reason = #"{"reason":"insufficientPermissions","domain":"global"}"#
        let detail = #"{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"SERVICE_DISABLED","domain":"googleapis.com"}"#
        let cases: [(String, String)] = [
            ("{\"error\":{\"code\":403,\"message\":\"" + String(repeating: "private_payload_canary", count: 220) + "\"}}", "4096-byte diagnostic limit"),
            ("{\"error\":{\"code\":403,\"errors\":[" + Array(repeating: reason, count: 17).joined(separator: ",") + "]}}", "too many structured error details"),
            ("{\"error\":{\"code\":403,\"details\":[" + Array(repeating: detail, count: 17).joined(separator: ",") + "]}}", "too many structured error details"),
            ("{\"error\":{\"code\":403,\"errors\":[{\"reason\":\"" + String(repeating: "r", count: 64) + "\",\"domain\":\"global\"}]}}", "invalid structured reason fields"),
            ("{\"error\":{\"code\":403,\"errors\":[{\"reason\":\"insufficientPermissions\",\"domain\":\"" + String(repeating: "d", count: 256) + "\"}]}}", "invalid structured reason fields")
        ]
        for (body, explanation) in cases {
            let message = try failureMessage(status: 403, body: body, operation: .fileDownload)
            #expect(message.contains(explanation))
            #expect(!message.contains("private_payload_canary"))
            #expect(!message.contains("Reason:"))
        }
    }

    @Test func failedMutationsRetainAnUnconfirmedOutcomeAndRequireStateReview() throws {
        let body = #"{"error":{"code":503,"errors":[{"reason":"backendError","domain":"global"}]}}"#
        let mutation = try failureMessage(status: 503, body: body, operation: .fileUpdate)
        #expect(mutation.contains("change is unconfirmed"))
        #expect(mutation.contains("Refresh the item in Google Drive"))
        let download = try failureMessage(status: 503, body: body, operation: .fileDownload)
        #expect(!download.contains("change is unconfirmed"))
    }
}
