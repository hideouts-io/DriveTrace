import Foundation
import Darwin
import DriveCore

struct FilePreview: Identifiable, Sendable {
    let id: UUID
    let name: String
    let url: URL
}

struct PreviewCleanupError: LocalizedError {
    let temporary: URL
    let cause: any Error
    var errorDescription: String? {
        "The temporary preview at \(temporary.path) could not be removed: \(cause.localizedDescription). Check that location's permissions and close any viewer using it, then quit and reopen DriveTrace to retry temporary-preview cleanup."
    }
}

/// Persistence failed before publication and cleanup failed too; retain both causes for recovery.
struct PreviewSaveCleanupError: LocalizedError {
    let temporary: URL
    let cause: any Error
    let cleanup: any Error
    var errorDescription: String? {
        "Preparing the preview failed: \(cause.localizedDescription). Its temporary content at \(temporary.path) could not be removed: \(cleanup.localizedDescription). No new preview was opened. Check the temporary location's permissions and remove the leftover content before retrying."
    }
}

private struct PreviewSaveError: LocalizedError {
    let temporary: URL
    let cause: any Error
    var errorDescription: String? {
        "The preview could not be saved at \(temporary.path): \(cause.localizedDescription). Check temporary-folder permissions and available disk space, then request the preview again."
    }
}

private struct PreviewWriteCloseError: LocalizedError {
    let cause: any Error
    let closing: any Error
    var errorDescription: String? {
        "Writing the temporary preview failed: \(cause.localizedDescription). Closing its output file also failed: \(closing.localizedDescription)."
    }
}

/// App-owned temporary content. Names from Drive never become paths; interrupted saves remove only their own file.
actor PreviewStore {
    private let root: URL
    init(root: URL) { self.root = root }
    func clear() throws {
        guard root.isFileURL else { throw MonitorError.invalid("Preview cleanup requires a local temporary directory.") }
        do {
            var attributes = stat()
            if lstat(root.path, &attributes) != 0 {
                guard errno == ENOENT else { throw previewFilesystemError("Inspect preview directory", code: errno) }
                return
            }
            guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw MonitorError.invalid("Preview cleanup refused a non-directory or symbolic link at its temporary directory.")
            }
            try FileManager.default.removeItem(at: root)
        } catch { throw PreviewCleanupError(temporary: root, cause: error) }
    }
    func remove(_ url: URL) throws {
        guard url.isFileURL, url.deletingLastPathComponent() == root else { throw MonitorError.invalid("Preview cleanup refused a path outside its temporary directory.") }
        do {
            var attributes = stat()
            guard lstat(root.path, &attributes) == 0 else { throw previewFilesystemError("Inspect preview directory before cleanup", code: errno) }
            guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw MonitorError.invalid("Preview cleanup refused a non-directory or symbolic link at its temporary directory.")
            }
            try FileManager.default.removeItem(at: url)
        }
        catch { throw PreviewCleanupError(temporary: url, cause: error) }
    }
    func save(_ content: PreviewContent, name: String) throws -> FilePreview {
        try Task.checkCancellation()
        guard root.isFileURL else { throw MonitorError.invalid("Choose a local temporary directory for previews.") }
        guard !content.fileExtension.isEmpty, content.fileExtension.utf8.count <= 16,
              content.fileExtension.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else {
            throw MonitorError.invalid("The preview has no supported safe filename extension. Open the file in Google Drive instead.")
        }
        guard content.data.count <= 20 * 1024 * 1024 else {
            throw MonitorError.invalid("The preview exceeds the 20 MiB in-app limit. Open the file in Google Drive instead.")
        }
        do {
            var attributes = stat()
            if lstat(root.path, &attributes) == 0 {
                guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    throw MonitorError.invalid("Preview storage refused a non-directory or symbolic link at its temporary directory.")
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            } else {
                guard errno == ENOENT else { throw previewFilesystemError("Inspect preview directory", code: errno) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch { throw PreviewSaveError(temporary: root, cause: error) }
        try Task.checkCancellation()
        let id = UUID()
        let url = root.appendingPathComponent(id.uuidString).appendingPathExtension(content.fileExtension)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw PreviewSaveError(temporary: url, cause: previewFilesystemError("Create private preview", code: errno)) }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            do {
                try Task.checkCancellation()
                try writer.write(contentsOf: content.data)
                try Task.checkCancellation()
            } catch {
                let cause = error
                do { try writer.close() }
                catch { throw PreviewWriteCloseError(cause: cause, closing: error) }
                throw cause
            }
            try writer.close()
            try Task.checkCancellation()
            return FilePreview(id: id, name: name, url: url)
        } catch {
            let cause = error
            do { try FileManager.default.removeItem(at: url) }
            catch { throw PreviewSaveCleanupError(temporary: url, cause: cause, cleanup: error) }
            if cause is CancellationError { throw cause }
            throw PreviewSaveError(temporary: url, cause: cause)
        }
    }
}

private func previewFilesystemError(_ operation: String, code: Int32) -> MonitorError {
    .invalid("\(operation) failed: \(String(cString: strerror(code))) (errno \(code)).")
}
