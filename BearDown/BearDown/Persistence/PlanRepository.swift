import Foundation
import SwiftData

@MainActor
public final class PlanRepository {
    private let context: ModelContext
    private let onCancel: CancelHook?

    public init(context: ModelContext, onCancel: CancelHook? = nil) {
        self.context = context
        self.onCancel = onCancel
    }

    public func activePlan() throws -> TrainingPlan? {
        var descriptor = FetchDescriptor<TrainingPlan>(
            predicate: #Predicate { $0.isActive == true },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    @discardableResult
    public func createPlan(title: String, startDate: Date, endDate: Date) throws -> TrainingPlan {
        // Archive any existing active plan.
        if let existing = try activePlan() {
            existing.isActive = false
            existing.archivedAt = .now
            existing.updatedAt = .now
        }
        let plan = TrainingPlan(
            title: title,
            startDate: Calendar.current.startOfDay(for: startDate),
            endDate: Calendar.current.startOfDay(for: endDate),
            isActive: true
        )
        context.insert(plan)
        try context.save()
        return plan
    }

    public func extendActivePlan(throughDate date: Date) throws {
        guard let plan = try activePlan() else { return }
        let day = Calendar.current.startOfDay(for: date)
        if day > plan.endDate {
            plan.endDate = day
            plan.updatedAt = .now
            try context.save()
        }
    }

    public func delete(planId: UUID) throws {
        guard let target = try plan(id: planId) else { return }
        let workoutIds = target.workouts.map(\.id)
        context.delete(target)
        try context.save()
        if let onCancel { for id in workoutIds { onCancel(id) } }
    }

    public func allPlans() throws -> [TrainingPlan] {
        let descriptor = FetchDescriptor<TrainingPlan>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = try context.fetch(descriptor)
        // Active first, then createdAt desc among the rest.
        return rows.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.createdAt > rhs.createdAt
        }
    }

    public func plan(id: UUID) throws -> TrainingPlan? {
        var descriptor = FetchDescriptor<TrainingPlan>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public func plan(title: String) throws -> TrainingPlan? {
        let normalized = title.lowercased()
        let rows = try context.fetch(FetchDescriptor<TrainingPlan>())
        return rows.first(where: { $0.title.lowercased() == normalized })
    }

    public func findOrCreatePlan(title: String, goal: String, anchorDate: Date) throws -> TrainingPlan {
        let normalized = title.lowercased()
        let rows = try context.fetch(FetchDescriptor<TrainingPlan>())
        if let existing = rows.first(where: { $0.title.lowercased() == normalized }) {
            return existing
        }
        let day = Calendar.current.startOfDay(for: anchorDate)
        let plan = TrainingPlan(title: title, goal: goal,
                                startDate: day, endDate: day,
                                isActive: false)
        context.insert(plan)
        try context.save()
        return plan
    }

    public func activate(planId: UUID) throws {
        guard let target = try plan(id: planId) else { return }
        if target.isActive { return }  // idempotent — no churn

        if let current = try activePlan(), current.id != target.id {
            current.isActive = false
            current.archivedAt = .now
            current.updatedAt = .now
        }
        target.isActive = true
        target.archivedAt = nil
        target.updatedAt = .now
        try context.save()
    }
}
