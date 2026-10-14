import Foundation

public enum DownloadFileOperation: String, Sendable {
    case stagingInput = "download staging input"
    case stagingOutput = "download staging output"
    case checksumInput = "download checksum input"
    case errorResponse = "download error response"
}

/// Closing did not finish cleanly; retain any earlier operation failure without hiding the close failure.
public struct DownloadFileCloseError: LocalizedError {
    public let file: URL
    public let operation: DownloadFileOperation
    public let cause: (any Error)?
    public let closing: any Error
    public var cancelled: Bool { cause.map(downloadWasCancelled) ?? false }
    public var errorDescription: String? {
        (cancelled ? "Download cancelled before completion. " : "")
            + (cause.map { "Original failure: \($0.localizedDescription). " } ?? "")
            + "Closing the \(operation.rawValue) at \(file.path) failed: \(closing.localizedDescription). Review this temporary location and correct any file or volume errors before retrying."
    }
}

/// Only explicit primary causes establish cancellation; a secondary close/cleanup error is still actionable.
func downloadWasCancelled(_ error: any Error) -> Bool {
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
    if let failure = error as? DownloadFileCloseError { return failure.cancelled }
    if let failure = error as? FailedDownloadCleanupError { return failure.cancelled }
    return false
}

/// Own the handle through one operation and close it exactly once, preserving both typed failure causes.
func withDownloadFileHandle<Value>(_ handle: FileHandle, file: URL, operation: DownloadFileOperation, body: (FileHandle) throws -> Value) throws -> Value {
    try withDownloadFileHandle(handle, file: file, operation: operation, closing: { try $0.close() }, body: body)
}

/// Keep the closing system boundary explicit so controlled I/O failures can validate error propagation.
func withDownloadFileHandle<Value>(_ handle: FileHandle, file: URL, operation: DownloadFileOperation, closing: (FileHandle) throws -> Void, body: (FileHandle) throws -> Value) throws -> Value {
    let result = Result { try body(handle) }
    do { try closing(handle) }
    catch {
        let cause: (any Error)?
        switch result {
        case .success: cause = nil
        case let .failure(failure): cause = failure
        }
        throw DownloadFileCloseError(file: file, operation: operation, cause: cause, closing: error)
    }
    return try result.get()
}
