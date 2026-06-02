import Foundation

/// Wire-shape mirror of the `bd.proposal/v1` JSON envelope persisted inside
/// `ChatMessage.toolResultsJSON`. See spec §"Envelope schema".
public struct ProposalEnvelope: Equatable {
    public var mode: Mode
    public var status: Status
    public var planTitle: String
    public var planGoal: String
    public var planId: UUID?          // .update mode: target plan id
    public var appliedPlanId: UUID?   // set when status == .applied
    public var appliedAt: Date?
    public var appliedMode: AppliedMode?
    public var workouts: [ProposalWorkout]

    public enum Mode: String, Equatable { case add, update }
    public enum Status: String, Equatable { case pending, applied, dismissed }
    public enum AppliedMode: String, Equatable {
        case inactive
        case switchPlan = "switch"   // `switch` is a reserved word; map manually
        case update
    }

    public init(mode: Mode, status: Status,
                planTitle: String, planGoal: String,
                planId: UUID?, appliedPlanId: UUID?,
                appliedAt: Date?, appliedMode: AppliedMode?,
                workouts: [ProposalWorkout]) {
        self.mode = mode
        self.status = status
        self.planTitle = planTitle
        self.planGoal = planGoal
        self.planId = planId
        self.appliedPlanId = appliedPlanId
        self.appliedAt = appliedAt
        self.appliedMode = appliedMode
        self.workouts = workouts
    }
}

public struct ProposalWorkout: Equatable {
    public var date: Date
    public var title: String
    public var summary: String
    public var blocks: [ProposalBlock]

    public init(date: Date, title: String, summary: String, blocks: [ProposalBlock]) {
        self.date = date; self.title = title; self.summary = summary; self.blocks = blocks
    }
}

public struct ProposalBlock: Equatable {
    public var order: Int
    public var kind: BlockKind
    public var title: String
    public var notes: String
    public var exercises: [ProposalExercise]
    public var cardio: ProposalCardio?

    public init(order: Int, kind: BlockKind, title: String, notes: String,
                exercises: [ProposalExercise] = [], cardio: ProposalCardio? = nil) {
        self.order = order; self.kind = kind; self.title = title; self.notes = notes
        self.exercises = exercises; self.cardio = cardio
    }
}

public struct ProposalExercise: Equatable {
    public var order: Int
    public var name: String
    public var sets: Int
    public var reps: String
    public var load: String?
    public var restSeconds: Int?

    public init(order: Int, name: String, sets: Int, reps: String,
                load: String? = nil, restSeconds: Int? = nil) {
        self.order = order; self.name = name; self.sets = sets; self.reps = reps
        self.load = load; self.restSeconds = restSeconds
    }
}

public struct ProposalCardio: Equatable {
    public var modality: String
    public var durationMinutes: Int?
    public var distanceMeters: Double?
    public var targetDescription: String?

    public init(modality: String, durationMinutes: Int? = nil,
                distanceMeters: Double? = nil, targetDescription: String? = nil) {
        self.modality = modality
        self.durationMinutes = durationMinutes
        self.distanceMeters = distanceMeters
        self.targetDescription = targetDescription
    }
}
