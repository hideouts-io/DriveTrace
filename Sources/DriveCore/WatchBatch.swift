import Foundation

public struct WatchBatch: Sendable {
    public let recordIDs: [String]
    public let deliveryDue: Bool
}
/// Batches source records without merging their identities or inferring an actor.
/// Callers persist recordIDs before delivery and acknowledge them only after the notification API succeeds.
public func watchBatch(rule: WatchRule, files: [DriveFile], events: [DriveEvent], pending: [String], lastSent: String?, now: Date) throws -> WatchBatch {
    guard rule.cooldown >= 0 else { throw MonitorError.invalid("Watch cooldown must not be negative.") }
    let last: Date?
    if let lastSent {
        guard let date = parseDate(lastSent) else { throw MonitorError.database("Watch delivery time is invalid for rule \(rule.id). Inspect the local watch state before retrying.") }
        last = date
    } else { last = nil }
    let ids = descendants(rule.id, files: files)
    let relevant = events.filter { event in
        (ids.contains(event.fileID) || !ids.isDisjoint(with: event.parents + event.previousParents)) &&
        (rule.actions.isEmpty || rule.actions.contains(event.action))
    }
    let records = Set(pending).union(relevant.map(\.id)).sorted()
    let due = rule.enabled && !records.isEmpty && (last.map { now.timeIntervalSince($0) >= Double(rule.cooldown) } ?? true)
    return WatchBatch(recordIDs: records, deliveryDue: due)
}
