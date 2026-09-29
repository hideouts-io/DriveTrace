import Foundation

/// Validates ranges before local or remote search; malformed input is never presented as an empty result.
public func validateDateRange(after: String, before: String, label: String) throws {
    let lower = parseDate(after), upper = parseDate(before)
    if (!after.isEmpty && lower == nil) || (!before.isEmpty && upper == nil) {
        throw MonitorError.invalid("\(label): enter a complete RFC3339 timestamp, for example 2026-09-01T00:00:00Z, or leave the field empty.")
    }
    if let lower, let upper, lower > upper { throw MonitorError.invalid("\(label): the after date must not be later than the before date.") }
}
public func validateFilter(_ filter: FileFilter) throws {
    if let minimum = filter.minimumBytes, minimum < 0 { throw MonitorError.invalid("Minimum size must be a nonnegative whole number of bytes.") }
    if let maximum = filter.maximumBytes, maximum < 0 { throw MonitorError.invalid("Maximum size must be a nonnegative whole number of bytes.") }
    if let minimum = filter.minimumBytes, let maximum = filter.maximumBytes, minimum > maximum { throw MonitorError.invalid("Minimum size must not exceed maximum size.") }
    try validateDateRange(after: filter.createdAfter, before: filter.createdBefore, label: "Created range")
    try validateDateRange(after: filter.modifiedAfter, before: filter.modifiedBefore, label: "Modified range")
    try validateDateRange(after: filter.discoveredAfter, before: filter.discoveredBefore, label: "Discovery range")
}
