import Foundation
import OSLog

enum GoogleRetryTimingError: Error, LocalizedError {
    case invalidHeader, waitBudgetExceeded, invalidPolicy

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "Google returned an invalid Retry-After header. Automatic retries stopped; try again later."
        case .waitBudgetExceeded: "The next retry would exceed the 60-second automatic retry wait budget. No early retry was sent; wait before trying again."
        case .invalidPolicy: "The Google retry timing policy is invalid. Automatic retries stopped."
        }
    }
}

/// Honor the server's minimum delay, with jittered exponential backoff and a bounded sleep budget.
/// Invalid headers fail explicitly; large server delays are never shortened to fit the budget.
func googleRetryDelay(retryAfter: String?, attempt: Int, now: Date, remainingWait: TimeInterval, jitter: TimeInterval) throws -> TimeInterval {
    guard (0..<3).contains(attempt), now.timeIntervalSinceReferenceDate.isFinite, remainingWait.isFinite, (0...60).contains(remainingWait), jitter.isFinite, (0...1).contains(jitter) else {
        throw GoogleRetryTimingError.invalidPolicy
    }
    let backoff = pow(2, Double(attempt)) + jitter
    let minimum: TimeInterval
    if let retryAfter {
        let value = retryAfter.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !value.isEmpty else { throw GoogleRetryTimingError.invalidHeader }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = Double(value), seconds.isFinite else { throw GoogleRetryTimingError.waitBudgetExceeded }
            minimum = seconds
        } else {
            minimum = max(0, try googleRetryDate(value, now: now).timeIntervalSince(now))
        }
    } else { minimum = 0 }
    let delay = max(minimum, backoff)
    guard delay.isFinite, delay <= remainingWait else { throw GoogleRetryTimingError.waitBudgetExceeded }
    return delay
}

private func googleRetryDate(_ value: String, now: Date) throws -> Date {
    let day = "(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)"
    let month = "(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
    let time = "[0-9]{2}:[0-9]{2}:[0-9]{2}"
    let formats: [(pattern: String, format: String)] = [
        ("^\(day), [0-9]{2} \(month) [0-9]{4} \(time) GMT$", "EEE, dd MMM yyyy HH:mm:ss 'GMT'"),
        ("^(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), [0-9]{2}-\(month)-[0-9]{2} \(time) GMT$", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'"),
        ("^\(day) \(month) (?:[0-9]{2}| [0-9]) \(time) [0-9]{4}$", "EEE MMM dd HH:mm:ss yyyy")
    ]
    guard let format = formats.first(where: { value.range(of: $0.pattern, options: .regularExpression) != nil }) else {
        throw GoogleRetryTimingError.invalidHeader
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    formatter.calendar = calendar
    formatter.timeZone = .gmt
    formatter.isLenient = false
    formatter.dateFormat = format.format
    let century = calendar.component(.year, from: now) / 100 * 100
    guard let centuryStart = calendar.date(from: DateComponents(year: century, month: 1, day: 1)),
          let futureLimit = calendar.date(byAdding: .year, value: 50, to: now) else { throw GoogleRetryTimingError.invalidHeader }
    formatter.twoDigitStartDate = centuryStart
    let normalized = value.replacingOccurrences(of: "  ", with: " 0")
    // HTTP permits second 60; Foundation dates represent it as the following instant.
    let calendarText = normalized.replacingOccurrences(of: ":60 ", with: ":59 ")
    guard var date = formatter.date(from: calendarText) else { throw GoogleRetryTimingError.invalidHeader }
    if format.format.contains("-yy "), date > futureLimit {
        guard let previousCentury = calendar.date(byAdding: .year, value: -100, to: date) else { throw GoogleRetryTimingError.invalidHeader }
        date = previousCentury
    }
    guard formatter.string(from: date) == calendarText else { throw GoogleRetryTimingError.invalidHeader }
    return calendarText == normalized ? date : date.addingTimeInterval(1)
}

/// Cancellation interrupts retry sleep before any subsequent request. Preserve the last HTTP failure.
func waitForGoogleRetry(retryAfter: String?, attempt: Int, waited: TimeInterval, failure: any Error, logger: Logger) async throws -> TimeInterval {
    let delay: TimeInterval
    do {
        delay = try googleRetryDelay(retryAfter: retryAfter, attempt: attempt, now: Date(), remainingWait: 60 - waited, jitter: Double.random(in: 0...1))
    } catch let timing as GoogleRetryTimingError {
        if case let MonitorError.http(status, context) = failure {
            throw MonitorError.http(status, context + "; " + timing.localizedDescription)
        }
        throw MonitorError.invalid("\(failure.localizedDescription); \(timing.localizedDescription)")
    }
    if case let MonitorError.http(status, _) = failure {
        logger.warning("Google retry wait attempt=\(attempt + 1) status=\(status) delaySeconds=\(delay)")
    } else if let network = failure as? URLError {
        logger.warning("Google retry wait attempt=\(attempt + 1) networkCode=\(network.errorCode) delaySeconds=\(delay)")
    }
    try await Task.sleep(for: .seconds(delay))
    return waited + delay
}
