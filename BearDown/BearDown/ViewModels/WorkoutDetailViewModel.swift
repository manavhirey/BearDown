import Combine
import Foundation

@MainActor
public final class WorkoutDetailViewModel: ObservableObject {

    @Published public var draftNote: String = ""

    private let env: AppEnvironment
    public let workout: Workout

    public init(env: AppEnvironment, workout: Workout) {
        self.env = env
        self.workout = workout
        self.draftNote = workout.completionNote ?? ""
    }

    public func markCompleted() throws { try set(.completed) }
    public func markFailed()    throws { try set(.failed) }
    public func markPending()   throws { try set(.pending) }

    private func set(_ status: WorkoutStatus) throws {
        let trimmed = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        try env.workouts.markStatus(workoutId: workout.id,
                                    status: status,
                                    note: trimmed.isEmpty ? nil : trimmed)
    }
}
