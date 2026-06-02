import Foundation

@MainActor
public final class ProposalApplyService {
    public enum ApplyMode { case addInactive, addAndSwitch, update }

    public struct ApplyResult: Equatable {
        public let planId: UUID
        public let appliedMode: ProposalEnvelope.AppliedMode
    }

    public enum ApplyError: Error, Equatable {
        case missingPlanId          // update mode without envelope.planId
        case noWorkoutsWritten      // upsert never produced a plan attachment
    }

    private let plans: PlanRepository
    private let workouts: WorkoutRepository

    public init(plans: PlanRepository, workouts: WorkoutRepository) {
        self.plans = plans
        self.workouts = workouts
    }

    public func apply(_ envelope: ProposalEnvelope,
                      mode: ApplyMode) throws -> ApplyResult {
        guard !envelope.workouts.isEmpty else { throw ApplyError.noWorkoutsWritten }
        let resolvedTitle = envelope.planTitle
        let resolvedGoal = envelope.planGoal

        var firstPlanId: UUID?
        for w in envelope.workouts.sorted(by: { $0.date < $1.date }) {
            let input = WorkoutInput(
                date: w.date,
                title: w.title,
                summary: w.summary,
                blocks: w.blocks.map(toBlockInput),
                planTitle: resolvedTitle,
                planGoal: resolvedGoal
            )
            let written = try workouts.upsert(input)
            if firstPlanId == nil, let pid = written.plan?.id { firstPlanId = pid }
        }
        guard let planId = firstPlanId else { throw ApplyError.noWorkoutsWritten }

        let appliedMode: ProposalEnvelope.AppliedMode
        switch mode {
        case .addInactive:
            appliedMode = .inactive
        case .addAndSwitch:
            try plans.activate(planId: planId)
            appliedMode = .switchPlan
        case .update:
            // Update never changes activation. WorkoutRepository.upsert routes by title
            // (findOrCreatePlan), which resolves to the same row the envelope identifies.
            appliedMode = .update
        }
        return ApplyResult(planId: planId, appliedMode: appliedMode)
    }

    private func toBlockInput(_ b: ProposalBlock) -> BlockInput {
        BlockInput(
            order: b.order, kind: b.kind, title: b.title, notes: b.notes,
            exercises: b.exercises.map {
                ExerciseInput(order: $0.order, name: $0.name, sets: $0.sets, reps: $0.reps,
                              load: $0.load, restSeconds: $0.restSeconds)
            },
            cardio: b.cardio.map {
                CardioInput(modality: $0.modality,
                            durationMinutes: $0.durationMinutes,
                            distanceMeters: $0.distanceMeters,
                            targetDescription: $0.targetDescription)
            }
        )
    }
}
