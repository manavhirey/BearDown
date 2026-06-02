import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class ProposalApplyServiceTests: XCTestCase {
    private var env: AppEnvironment!
    private var service: ProposalApplyService!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(modelContainer: container,
                             keychain: KeychainStore(service: "com.beardown.tests.apply.\(UUID().uuidString)"),
                             anthropic: FakeAnthropicClient())
        service = ProposalApplyService(plans: env.plans, workouts: env.workouts)
    }

    private func envelope(mode: ProposalEnvelope.Mode,
                          planTitle: String = "Race Prep — June 24",
                          planGoal: String = "Goal",
                          planId: UUID? = nil,
                          dates: [String] = ["2026-06-03", "2026-06-04"]) -> ProposalEnvelope {
        ProposalEnvelope(
            mode: mode, status: .pending,
            planTitle: planTitle, planGoal: planGoal,
            planId: planId, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: dates.map { d in
                .init(date: dateFromIso(d), title: "W \(d)", summary: "", blocks: [])
            }
        )
    }

    func test_addInactive_createsPlan_inactiveByDefault() throws {
        let result = try service.apply(envelope(mode: .add), mode: .addInactive)
        let p = try env.plans.plan(id: result.planId)
        XCTAssertNotNil(p)
        XCTAssertFalse(p!.isActive)
        XCTAssertEqual(result.appliedMode, .inactive)
    }

    func test_addInactive_doesNotChangeActivePlan() throws {
        let existing = try env.plans.createPlan(
            title: "Existing", startDate: .now,
            endDate: .now.addingTimeInterval(7 * 86400))
        _ = try service.apply(envelope(mode: .add), mode: .addInactive)
        let active = try env.plans.activePlan()
        XCTAssertEqual(active?.id, existing.id, "addInactive must not switch active plan")
    }

    func test_addInactive_writesAllWorkouts() throws {
        let result = try service.apply(envelope(mode: .add,
            dates: ["2026-06-03", "2026-06-04", "2026-06-05"]), mode: .addInactive)
        let plan = try env.plans.plan(id: result.planId)!
        XCTAssertEqual(plan.workouts.count, 3)
    }

    func test_addAndSwitch_createsAndActivatesPlan() throws {
        _ = try env.plans.createPlan(title: "Old",
            startDate: .now, endDate: .now.addingTimeInterval(86400))
        let result = try service.apply(envelope(mode: .add), mode: .addAndSwitch)
        let active = try env.plans.activePlan()
        XCTAssertEqual(active?.id, result.planId)
        XCTAssertEqual(result.appliedMode, .switchPlan)
    }

    func test_addAndSwitch_archivesPriorActivePlan() throws {
        let old = try env.plans.createPlan(title: "Old",
            startDate: .now, endDate: .now.addingTimeInterval(86400))
        _ = try service.apply(envelope(mode: .add), mode: .addAndSwitch)
        let refetched = try env.plans.plan(id: old.id)
        XCTAssertEqual(refetched?.isActive, false)
        XCTAssertNotNil(refetched?.archivedAt)
    }

    func test_update_replacesWorkoutsOnMatchingDates() throws {
        let target = try env.plans.createPlan(title: "Active Block",
            startDate: dateFromIso("2026-06-01"),
            endDate: dateFromIso("2026-06-30"))
        _ = try env.workouts.upsert(.init(date: dateFromIso("2026-06-10"),
            title: "OLD-1", summary: "", blocks: []))
        _ = try env.workouts.upsert(.init(date: dateFromIso("2026-06-11"),
            title: "OLD-2", summary: "", blocks: []))
        let env2 = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Active Block", planGoal: "",
            planId: target.id,
            appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [
                .init(date: dateFromIso("2026-06-10"), title: "NEW-1", summary: "", blocks: []),
                .init(date: dateFromIso("2026-06-11"), title: "NEW-2", summary: "", blocks: []),
            ]
        )
        _ = try service.apply(env2, mode: .update)
        let day = Calendar.current.startOfDay(for: dateFromIso("2026-06-10"))
        let after = try env.workouts.workoutsBetween(start: day, end: day.addingTimeInterval(2 * 86400))
        XCTAssertEqual(after.map(\.title).sorted(), ["NEW-1", "NEW-2"])
    }

    func test_update_addsNewDates_withoutDeletingOthers() throws {
        let target = try env.plans.createPlan(title: "Active",
            startDate: dateFromIso("2026-06-01"),
            endDate: dateFromIso("2026-06-30"))
        _ = try env.workouts.upsert(.init(date: dateFromIso("2026-06-10"),
            title: "KEEP", summary: "", blocks: []))
        let env2 = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Active", planGoal: "",
            planId: target.id,
            appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-06-15"), title: "ADDED",
                             summary: "", blocks: [])]
        )
        _ = try service.apply(env2, mode: .update)
        let allPlanWorkouts = try env.workouts.workoutsBetween(
            start: dateFromIso("2026-06-01"),
            end: dateFromIso("2026-06-30"))
        XCTAssertTrue(allPlanWorkouts.contains(where: { $0.title == "KEEP" }))
        XCTAssertTrue(allPlanWorkouts.contains(where: { $0.title == "ADDED" }))
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}
