import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class PlanRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repo: PlanRepository!

    override func setUpWithError() throws {
        container = try .beardownInMemory()
        repo = PlanRepository(context: container.mainContext)
    }

    func test_activePlan_returnsNilWhenNoneExists() throws {
        XCTAssertNil(try repo.activePlan())
    }

    func test_createPlan_setsItAsActive() throws {
        let plan = try repo.createPlan(title: "Block 1",
                                       startDate: .now,
                                       endDate: .now.addingTimeInterval(28 * 86400))
        XCTAssertTrue(plan.isActive)
        XCTAssertEqual(try repo.activePlan()?.id, plan.id)
    }

    func test_creatingASecondPlan_archivesTheFirst() throws {
        let first = try repo.createPlan(title: "A", startDate: .now, endDate: .now.addingTimeInterval(86400))
        let second = try repo.createPlan(title: "B", startDate: .now, endDate: .now.addingTimeInterval(86400))

        XCTAssertEqual(try repo.activePlan()?.id, second.id)
        let ctx = container.mainContext
        let refreshed = try ctx.fetch(FetchDescriptor<TrainingPlan>())
        let archived = try XCTUnwrap(refreshed.first { $0.id == first.id })
        XCTAssertFalse(archived.isActive)
        XCTAssertNotNil(archived.archivedAt)
    }

    func test_extendEndDateIfNeeded_growsEndDate() throws {
        let plan = try repo.createPlan(title: "P",
                                       startDate: .now,
                                       endDate: .now.addingTimeInterval(7 * 86400))
        let newEnd = plan.endDate.addingTimeInterval(7 * 86400)
        try repo.extendActivePlan(throughDate: newEnd)
        XCTAssertEqual(try repo.activePlan()?.endDate, newEnd)
    }

    func test_extendEndDateIfNeeded_doesNothingIfDateInside() throws {
        let plan = try repo.createPlan(title: "P",
                                       startDate: .now,
                                       endDate: .now.addingTimeInterval(28 * 86400))
        let originalEnd = plan.endDate
        try repo.extendActivePlan(throughDate: .now.addingTimeInterval(5 * 86400))
        XCTAssertEqual(try repo.activePlan()?.endDate, originalEnd)
    }

    func test_allPlans_ordersActiveFirstThenCreatedAtDesc() throws {
        let older = try repo.createPlan(title: "Older",
                                        startDate: .now.addingTimeInterval(-10 * 86400),
                                        endDate: .now.addingTimeInterval(-3 * 86400))
        // Force a measurable createdAt difference. SwiftData stores Date with
        // sub-millisecond precision but tests run fast; nudge older back.
        older.createdAt = .now.addingTimeInterval(-3600)
        older.isActive = false
        older.archivedAt = .now.addingTimeInterval(-1800)

        let newerArchived = try repo.createPlan(title: "Newer Archived",
                                                startDate: .now.addingTimeInterval(-5 * 86400),
                                                endDate: .now)
        // createPlan marks it active and archives `older`. Flip newerArchived inactive.
        newerArchived.isActive = false
        newerArchived.archivedAt = .now

        let active = try repo.createPlan(title: "Active Block",
                                         startDate: .now,
                                         endDate: .now.addingTimeInterval(7 * 86400))

        let listed = try repo.allPlans()
        XCTAssertEqual(listed.map(\.title), ["Active Block", "Newer Archived", "Older"])
        XCTAssertEqual(listed.first?.id, active.id)
    }

    func test_planById_returnsMatchingPlan() throws {
        let plan = try repo.createPlan(title: "A", startDate: .now, endDate: .now.addingTimeInterval(86400))
        let fetched = try repo.plan(id: plan.id)
        XCTAssertEqual(fetched?.id, plan.id)
    }

    func test_planById_returnsNilWhenAbsent() throws {
        let missing = try repo.plan(id: UUID())
        XCTAssertNil(missing)
    }

    func test_activate_archivesPriorActiveAndSetsTarget() throws {
        let first = try repo.createPlan(title: "First",
                                        startDate: .now,
                                        endDate: .now.addingTimeInterval(86400))
        let second = try repo.createPlan(title: "Second",
                                         startDate: .now,
                                         endDate: .now.addingTimeInterval(86400))
        // createPlan auto-archives first. Now activate first again.
        try repo.activate(planId: first.id)
        XCTAssertEqual(try repo.activePlan()?.id, first.id)

        let all = try repo.allPlans()
        let secondReloaded = try XCTUnwrap(all.first { $0.id == second.id })
        XCTAssertFalse(secondReloaded.isActive)
        XCTAssertNotNil(secondReloaded.archivedAt)
    }

    func test_activate_isIdempotentOnAlreadyActive() throws {
        let plan = try repo.createPlan(title: "A",
                                       startDate: .now,
                                       endDate: .now.addingTimeInterval(86400))
        let originalUpdated = plan.updatedAt
        try repo.activate(planId: plan.id)
        XCTAssertEqual(try repo.activePlan()?.id, plan.id)
        // Idempotent — no archival of self, no updatedAt churn.
        XCTAssertEqual(plan.updatedAt, originalUpdated)
    }

    func test_delete_cascadesWorkoutsAndFiresCancelHookPerWorkout() throws {
        var cancelled: [UUID] = []
        let hook: @Sendable (UUID) -> Void = { id in cancelled.append(id) }
        let repoWithHook = PlanRepository(context: container.mainContext, onCancel: hook)

        let plan = try repoWithHook.createPlan(title: "P",
                                               startDate: .now,
                                               endDate: .now.addingTimeInterval(7 * 86400))
        let workouts = WorkoutRepository(context: container.mainContext, plans: repoWithHook)
        let w1 = try workouts.upsert(.init(date: .now, title: "A", summary: "", blocks: []))
        let w2 = try workouts.upsert(.init(date: .now.addingTimeInterval(86400),
                                           title: "B", summary: "", blocks: []))

        try repoWithHook.delete(planId: plan.id)

        // Plan gone, workouts gone (cascade), hook fired once per workout id.
        XCTAssertNil(try repoWithHook.plan(id: plan.id))
        let remaining = try container.mainContext.fetch(FetchDescriptor<Workout>())
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(Set(cancelled), Set([w1.id, w2.id]))
    }

    func test_delete_activePlan_leavesNoActivePlan() throws {
        let active = try repo.createPlan(title: "Active",
                                         startDate: .now,
                                         endDate: .now.addingTimeInterval(86400))
        try repo.delete(planId: active.id)
        XCTAssertNil(try repo.activePlan())
    }

    func test_findOrCreatePlan_caseInsensitiveTitleMatch() throws {
        let original = try repo.findOrCreatePlan(title: "Race Prep", goal: "g", anchorDate: .now)
        let again = try repo.findOrCreatePlan(title: "race prep", goal: "x", anchorDate: .now)
        XCTAssertEqual(again.id, original.id)
    }

    func test_findOrCreatePlan_createsInactiveByDefault() throws {
        let plan = try repo.findOrCreatePlan(title: "Race Prep",
                                             goal: "3.5mi race goal",
                                             anchorDate: .now)
        XCTAssertFalse(plan.isActive)
        XCTAssertEqual(plan.goal, "3.5mi race goal")
        XCTAssertEqual(plan.startDate, Calendar.current.startOfDay(for: .now))
        XCTAssertEqual(plan.endDate, plan.startDate)
    }

    func test_findOrCreatePlan_doesNotOverwriteGoalOnSecondCall() throws {
        let first = try repo.findOrCreatePlan(title: "Race Prep",
                                              goal: "original goal",
                                              anchorDate: .now)
        let again = try repo.findOrCreatePlan(title: "Race Prep",
                                              goal: "new goal",
                                              anchorDate: .now)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.goal, "original goal")
    }
}
