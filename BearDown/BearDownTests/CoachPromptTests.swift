import XCTest
@testable import BearDown

final class CoachPromptTests: XCTestCase {
    func test_assembled_includesAllThreeLayers() {
        let plan = TrainingPlanSnapshot(title: "Block 1", planId: UUID(),
                                        weekNumber: 2, totalWeeks: 4,
                                        startDate: dateFromIso("2026-05-17"),
                                        endDate: dateFromIso("2026-06-13"))
        let history = [
            HistoryEntry(date: dateFromIso("2026-05-30"), title: "Pull",
                         status: .completed, note: "felt good", blocksSummary: "strength:Pull"),
            HistoryEntry(date: dateFromIso("2026-05-29"), title: "Run",
                         status: .completed, note: nil, blocksSummary: "cardio:Easy"),
        ]
        let s = CoachPrompt.assembled(today: dateFromIso("2026-05-31"),
                                      plan: plan, history: history)
        XCTAssertTrue(s.contains(CoachPrompt.coachingPersona))
        XCTAssertTrue(s.contains(CoachPrompt.toolAddendum))
        XCTAssertTrue(s.contains("<context>"))
        XCTAssertTrue(s.contains("Today: 2026-05-31"))
        XCTAssertTrue(s.contains("Active plan: \"Block 1\""))
        XCTAssertTrue(s.contains("Week 2 of 4"))
        XCTAssertTrue(s.contains("2026-05-30 | Pull"))
        XCTAssertTrue(s.contains("felt good"))
    }

    func test_assembled_withNoPlan_omitsActivePlanLine() {
        let s = CoachPrompt.assembled(today: dateFromIso("2026-05-31"),
                                      plan: nil, history: [])
        XCTAssertTrue(s.contains("Today: 2026-05-31"))
        XCTAssertFalse(s.contains("Active plan:"))
        XCTAssertTrue(s.contains("No active plan yet."))
    }

    func test_toolAddendum_mentionsPlanTitle() {
        XCTAssertTrue(CoachPrompt.toolAddendum.contains("plan_title"),
                      "tool addendum must instruct the model when to use plan_title")
        XCTAssertTrue(CoachPrompt.toolAddendum.contains("new training block"),
                      "tool addendum must frame plan_title as a new-block signal")
    }

    func test_context_includesActivePlanId() {
        let pid = UUID(uuidString: "4DC1F70E-7B16-4F8E-A41C-71BC2A3DF812")!
        let snap = TrainingPlanSnapshot(
            title: "Race Prep — June 24",
            planId: pid,
            weekNumber: 2, totalWeeks: 4,
            startDate: Date(timeIntervalSince1970: 1_780_000_000),
            endDate: Date(timeIntervalSince1970: 1_782_500_000)
        )
        let ctx = CoachPrompt.context(today: .now, plan: snap, history: [])
        XCTAssertTrue(ctx.contains("id=\(pid.uuidString)"),
                      "context must include active plan id; got: \(ctx)")
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}
