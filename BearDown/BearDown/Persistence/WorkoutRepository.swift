import Foundation
import SwiftData

public struct WorkoutInput: Sendable, Equatable {
    public var date: Date
    public var title: String
    public var summary: String
    public var blocks: [BlockInput]

    public init(date: Date, title: String, summary: String, blocks: [BlockInput]) {
        self.date = date
        self.title = title
        self.summary = summary
        self.blocks = blocks
    }
}

public struct BlockInput: Sendable, Equatable {
    public var order: Int
    public var kind: BlockKind
    public var title: String
    public var notes: String
    public var exercises: [ExerciseInput]
    public var cardio: CardioInput?

    public init(order: Int, kind: BlockKind, title: String, notes: String,
                exercises: [ExerciseInput] = [], cardio: CardioInput? = nil) {
        self.order = order
        self.kind = kind
        self.title = title
        self.notes = notes
        self.exercises = exercises
        self.cardio = cardio
    }
}

public struct ExerciseInput: Sendable, Equatable {
    public var order: Int
    public var name: String
    public var sets: Int
    public var reps: String
    public var load: String?
    public var restSeconds: Int?

    public init(order: Int, name: String, sets: Int, reps: String,
                load: String? = nil, restSeconds: Int? = nil) {
        self.order = order
        self.name = name
        self.sets = sets
        self.reps = reps
        self.load = load
        self.restSeconds = restSeconds
    }
}

public struct CardioInput: Sendable, Equatable {
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

public struct HistoryEntry: Sendable, Equatable {
    public let date: Date
    public let title: String
    public let status: WorkoutStatus
    public let note: String?
    public let blocksSummary: String
}

public enum RepositoryError: Error, Equatable {
    case noActivePlan
    case workoutNotFound
}

public typealias ScheduleHook = @Sendable (Workout, _ enabled: Bool) -> Void
public typealias CancelHook = @Sendable (UUID) -> Void

@MainActor
public final class WorkoutRepository {
    private let context: ModelContext
    private let plans: PlanRepository
    private let onChange: ScheduleHook?
    private let onCancel: CancelHook?
    private let notificationsEnabled: @Sendable () -> Bool

    public init(context: ModelContext,
                plans: PlanRepository,
                onChange: ScheduleHook? = nil,
                onCancel: CancelHook? = nil,
                notificationsEnabled: @escaping @Sendable () -> Bool = { false }) {
        self.context = context
        self.plans = plans
        self.onChange = onChange
        self.onCancel = onCancel
        self.notificationsEnabled = notificationsEnabled
    }

    @discardableResult
    public func upsert(_ input: WorkoutInput) throws -> Workout {
        guard let plan = try plans.activePlan() else {
            throw RepositoryError.noActivePlan
        }
        try plans.extendActivePlan(throughDate: input.date)

        let day = Calendar.current.startOfDay(for: input.date)
        let next = day.addingTimeInterval(86400)
        let existing = try context.fetch(FetchDescriptor<Workout>(
            predicate: #Predicate { $0.date >= day && $0.date < next }
        )).first

        if let existing { context.delete(existing) }

        let w = Workout(date: day, title: input.title, summary: input.summary)
        w.plan = plan
        context.insert(w)

        for b in input.blocks.sorted(by: { $0.order < $1.order }) {
            let block = WorkoutBlock(order: b.order, kind: b.kind, title: b.title, notes: b.notes)
            block.workout = w
            context.insert(block)

            for e in b.exercises.sorted(by: { $0.order < $1.order }) {
                let ex = Exercise(order: e.order, name: e.name, sets: e.sets,
                                  reps: e.reps, load: e.load, restSeconds: e.restSeconds)
                ex.block = block
                context.insert(ex)
            }
            if let c = b.cardio {
                let cd = CardioDetail(modality: c.modality, durationMinutes: c.durationMinutes,
                                      distanceMeters: c.distanceMeters, targetDescription: c.targetDescription)
                cd.block = block
                context.insert(cd)
            }
        }
        try context.save()
        onChange?(w, notificationsEnabled())
        return w
    }

    public func delete(date: Date) throws {
        let day = Calendar.current.startOfDay(for: date)
        let next = day.addingTimeInterval(86400)
        let toDelete = try context.fetch(FetchDescriptor<Workout>(
            predicate: #Predicate { $0.date >= day && $0.date < next }
        ))
        let cancelledIds = toDelete.map(\.id)
        for w in toDelete { context.delete(w) }
        try context.save()
        if let onCancel { for id in cancelledIds { onCancel(id) } }
    }

    public func workoutsBetween(start: Date, end: Date) throws -> [Workout] {
        try context.fetch(FetchDescriptor<Workout>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        ))
    }

    public func markStatus(workoutId: UUID, status: WorkoutStatus, note: String?) throws {
        let all = try context.fetch(FetchDescriptor<Workout>(
            predicate: #Predicate { $0.id == workoutId }
        ))
        guard let w = all.first else { throw RepositoryError.workoutNotFound }
        w.status = status
        w.completionNote = note
        w.completedAt = (status == .pending) ? nil : .now
        w.updatedAt = .now
        try context.save()
        onChange?(w, notificationsEnabled())
    }

    public func recentHistory(days: Int) throws -> [HistoryEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let start = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        let end = today.addingTimeInterval(86400)
        let ws = try context.fetch(FetchDescriptor<Workout>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))
        return ws.map { w in
            let summary = w.blocks
                .sorted(by: { $0.order < $1.order })
                .map { "\($0.kind.rawValue):\($0.title)" }
                .joined(separator: ", ")
            return HistoryEntry(date: w.date, title: w.title, status: w.status,
                                note: w.completionNote, blocksSummary: summary)
        }
    }
}
