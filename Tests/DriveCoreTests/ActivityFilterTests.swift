import Foundation
import Testing
@testable import DriveCore
@testable import DriveTrace

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
