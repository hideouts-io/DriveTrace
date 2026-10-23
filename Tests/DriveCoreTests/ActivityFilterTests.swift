import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

/// Smaller native evidence pages retain every ordered record, including a partial final page.
@Test func evidenceTablePagesCoverFullAndPartialWorkloads() {
    for total in [0, 1, 99, 100, 101, 1_536, 8_454, 10_000] {
        let source = Array(0..<total)
        let pages = (0...max(0, (total - 1) / 100)).map { tablePageRange(total: total, page: $0, pageSize: 100) }
        #expect(pages.allSatisfy { $0.count <= 100 })
        #expect(pages.flatMap { Array(source[$0]) } == source)
    }
    #expect(tablePageRange(total: 8_454, page: Int.max, pageSize: 100) == 8_400..<8_454)
    #expect(tablePageRange(total: 10_000, page: 99, pageSize: 100) == 9_900..<10_000)
    #expect(tablePageRange(total: 0, page: Int.max, pageSize: 100).isEmpty)
    #expect(tablePageRange(total: Int.max, page: Int.max, pageSize: 100).upperBound == Int.max)
}

/// Correcting or resetting filters must not change the loaded source evidence or invent an actor.
@Test @MainActor func activityFiltersRecoverWithoutChangingLoadedEvidence() {
    let model = AppModel()
    let records = [
        DriveEvent(id: "activity-record", fileID: "report", name: "Report.txt", action: "MODIFIED", time: "2026-10-08T12:00:00Z", detected: "2026-10-08T12:01:00Z", source: .activity, actor: "Fixture actor", parents: ["folder"], previousParents: [], previousName: nil, raw: "{\"fixture\":\"activity\"}"),
        DriveEvent(id: "changes-record", fileID: "notes", name: "Notes.txt", action: "DISCOVERED", time: "2026-10-07T12:00:00Z", detected: "2026-10-08T12:01:00Z", source: .changes, actor: nil, parents: [], previousParents: [], previousName: nil, raw: "{\"fixture\":\"changes\"}")
    ]
    model.events = records
    model.activityActor = "Fixture"
    model.activityAction = "MODIFIED"
    model.activityTarget = "report"
    model.activityAfter = "2026-10-08T00:00:00Z"
    model.activityBefore = "2026-10-09T00:00:00Z"
    #expect(model.filteredEvents == [records[0]])
    model.activityActor = "No such actor"
    #expect(model.filteredEvents.isEmpty)
    #expect(model.activityValidationError == nil)
    model.activityAfter = "invalid date"
    #expect(model.activityValidationError != nil)
    #expect(model.filteredEvents.isEmpty)
    #expect(model.activityAfter == "invalid date")
    #expect(model.events == records)

    model.resetActivityFilters()
    #expect(model.activityActor.isEmpty)
    #expect(model.activityAction.isEmpty)
    #expect(model.activityTarget.isEmpty)
    #expect(model.activityAfter.isEmpty)
    #expect(model.activityBefore.isEmpty)
    #expect(model.activityValidationError == nil)
    #expect(model.filteredEvents == records)
    #expect(model.events[1].actor == nil)
    #expect(model.events[1].source == .changes)
    #expect(model.events.map(\.raw) == records.map(\.raw))
}
