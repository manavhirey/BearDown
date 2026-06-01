import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class WorkoutDetailViewModelTests: XCTestCase {
    private var env: AppEnvironment!
    private var w: Workout!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.detail.\(UUID().uuidString)"),
            anthropic: FakeAnthropicClient()
        )
        _ = try env.plans.createPlan(title: "P", startDate: .now, endDate: .now.addingTimeInterval(86400))
        w = try env.workouts.upsert(.init(date: .now, title: "Push", summary: "Bench", blocks: []))
    }

    func test_markCompleted_savesStatusAndNote() throws {
        let vm = WorkoutDetailViewModel(env: env, workout: w)
        vm.draftNote = "felt good"
        try vm.markCompleted()
        XCTAssertEqual(w.status, .completed)
        XCTAssertEqual(w.completionNote, "felt good")
    }

    func test_markFailed_savesStatusAndNote() throws {
        let vm = WorkoutDetailViewModel(env: env, workout: w)
        vm.draftNote = "bench too heavy"
        try vm.markFailed()
        XCTAssertEqual(w.status, .failed)
        XCTAssertEqual(w.completionNote, "bench too heavy")
    }

    func test_skipNote_savesStatusWithNilNote() throws {
        let vm = WorkoutDetailViewModel(env: env, workout: w)
        vm.draftNote = ""
        try vm.markCompleted()
        XCTAssertEqual(w.status, .completed)
        XCTAssertNil(w.completionNote)
    }
}
