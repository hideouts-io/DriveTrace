import AppKit
import DriveCore

/// Own one save-sheet wait. Task cancellation ends only this sheet, and completion hides it before recovery.
@MainActor func selectDownloadDestination(panel: NSSavePanel, window: NSWindow) async throws -> URL? {
    let response = try await filePanelResponse(panel: panel, window: window)
    switch response {
    case .cancel: return nil
    case .OK:
        guard let destination = panel.url, destination.isFileURL else {
            throw MonitorError.invalid("The download save panel returned no valid local destination. Choose Download again and select a writable file location.")
        }
        return destination
    case .abort:
        throw MonitorError.invalid("macOS could not display the download save panel. Close other sheets on this window and choose Download again.")
    default:
        throw MonitorError.invalid("The download save panel returned an unexpected response (\(response.rawValue)). Choose Download again to review the destination.")
    }
}

@MainActor func selectReportCopyDestination(panel: NSSavePanel, window: NSWindow) async throws -> URL? {
    let response = try await filePanelResponse(panel: panel, window: window)
    switch response {
    case .cancel: return nil
    case .OK:
        guard let destination = panel.url, destination.isFileURL, destination.pathExtension.lowercased() == "json" else {
            throw MonitorError.invalid("Choose a new local JSON filename for the report. The retained download results are unchanged.")
        }
        return destination
    case .abort: throw MonitorError.invalid("macOS could not display the report save panel. Close other panels, then choose Save Report Copy again.")
    default: throw MonitorError.invalid("The report save panel returned an unexpected response (\(response.rawValue)). Results are retained; choose Save Report Copy to retry.")
    }
}

/// Cancellation belongs to this exact panel; completion hides it before another action can present a sheet.
@MainActor private func filePanelResponse(panel: NSSavePanel, window: NSWindow) async throws -> NSApplication.ModalResponse {
    try Task.checkCancellation()
    guard window.attachedSheet == nil, panel.sheetParent == nil else {
        throw MonitorError.invalid("A file selection panel cannot open while another sheet is active. Close that sheet before choosing a location again.")
    }
    let response: NSApplication.ModalResponse = await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                panel.orderOut(nil)
                continuation.resume(returning: response)
            }
        }
    } onCancel: {
        Task { @MainActor in
            if panel.sheetParent === window { window.endSheet(panel, returnCode: .cancel) }
        }
    }
    try Task.checkCancellation()
    return response
}
