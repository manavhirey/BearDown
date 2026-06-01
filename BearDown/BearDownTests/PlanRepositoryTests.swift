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
        let archived = refreshed.first { $0.id == first.id }!
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
}
