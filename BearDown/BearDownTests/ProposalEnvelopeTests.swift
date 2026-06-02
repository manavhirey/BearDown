import XCTest
@testable import BearDown

final class ProposalEnvelopeTests: XCTestCase {
    func test_addModeEnvelope_buildsWithExpectedFields() {
        let env = ProposalEnvelope(
            mode: .add,
            status: .pending,
            planTitle: "Race Prep — June 24",
            planGoal: "3.5mi race goal",
            planId: nil,
            appliedPlanId: nil,
            appliedAt: nil,
            appliedMode: nil,
            workouts: [
                .init(date: dateFromIso("2026-06-03"),
                      title: "Upper Push", summary: "Compound-led",
                      blocks: [])
            ]
        )
        XCTAssertEqual(env.mode, .add)
        XCTAssertEqual(env.status, .pending)
        XCTAssertEqual(env.planTitle, "Race Prep — June 24")
        XCTAssertEqual(env.workouts.count, 1)
        XCTAssertEqual(env.workouts.first?.title, "Upper Push")
    }

    func test_updateModeEnvelope_carriesPlanId() {
        let pid = UUID()
        let env = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Race Prep", planGoal: "",
            planId: pid, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
        )
        XCTAssertEqual(env.mode, .update)
        XCTAssertEqual(env.planId, pid)
    }

    func test_modeAndStatus_rawValues() {
        XCTAssertEqual(ProposalEnvelope.Mode.add.rawValue, "add")
        XCTAssertEqual(ProposalEnvelope.Mode.update.rawValue, "update")
        XCTAssertEqual(ProposalEnvelope.Status.pending.rawValue, "pending")
        XCTAssertEqual(ProposalEnvelope.Status.applied.rawValue, "applied")
        XCTAssertEqual(ProposalEnvelope.Status.dismissed.rawValue, "dismissed")
        XCTAssertEqual(ProposalEnvelope.AppliedMode.inactive.rawValue, "inactive")
        XCTAssertEqual(ProposalEnvelope.AppliedMode.switchPlan.rawValue, "switch")
        XCTAssertEqual(ProposalEnvelope.AppliedMode.update.rawValue, "update")
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}
