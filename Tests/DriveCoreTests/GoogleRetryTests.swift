import Foundation
import Testing
@testable import DriveCore

@Test func retryTimingHonorsServerMinimumAndBoundedJitter() throws {
    let now = Date(timeIntervalSince1970: 0)
    #expect(try googleRetryDelay(retryAfter: nil, attempt: 0, now: now, remainingWait: 60, jitter: 0.5) == 1.5)
    #expect(try googleRetryDelay(retryAfter: "0", attempt: 2, now: now, remainingWait: 60, jitter: 1) == 5)
    #expect(try googleRetryDelay(retryAfter: " \t30\t ", attempt: 1, now: now, remainingWait: 60, jitter: 0.5) == 30)
    #expect(throws: GoogleRetryTimingError.waitBudgetExceeded) {
        try googleRetryDelay(retryAfter: "120", attempt: 0, now: now, remainingWait: 60, jitter: 0)
    }
    #expect(throws: GoogleRetryTimingError.waitBudgetExceeded) {
        try googleRetryDelay(retryAfter: "30", attempt: 1, now: now, remainingWait: 20, jitter: 0)
    }
    #expect(throws: GoogleRetryTimingError.waitBudgetExceeded) {
        try googleRetryDelay(retryAfter: String(repeating: "9", count: 400), attempt: 0, now: now, remainingWait: 60, jitter: 0)
    }
}

@Test func retryTimingParsesHTTPDatesAndRejectsInvalidValues() throws {
    let date = try #require(parseDate("1994-11-06T08:49:07Z"))
    for header in ["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994"] {
        #expect(try googleRetryDelay(retryAfter: header, attempt: 0, now: date, remainingWait: 60, jitter: 0) == 30)
        #expect(try googleRetryDelay(retryAfter: header, attempt: 0, now: date.addingTimeInterval(60), remainingWait: 60, jitter: 0) == 1)
    }
    let modern = try #require(parseDate("2026-10-09T00:00:00Z"))
    #expect(try googleRetryDelay(retryAfter: "Sunday, 06-Nov-94 08:49:37 GMT", attempt: 0, now: modern, remainingWait: 60, jitter: 0) == 1)
    let leap = try #require(parseDate("2016-12-31T23:59:30Z"))
    #expect(try googleRetryDelay(retryAfter: "Sat, 31 Dec 2016 23:59:60 GMT", attempt: 0, now: leap, remainingWait: 60, jitter: 0) == 30)
    for header in ["NaN", "inf", "-1", "+1", "1.5", "1e2", "", "1, 2", "Sun, 31 Feb 1994 08:49:37 GMT", "Sun, 06 Nov 1994 08:49:37 GMT extra", "Sun, 06 Nov 1994 08:49:37 UTC"] {
        #expect(throws: GoogleRetryTimingError.invalidHeader) {
            try googleRetryDelay(retryAfter: header, attempt: 0, now: date, remainingWait: 60, jitter: 0)
        }
    }
}
