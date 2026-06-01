import Foundation
import SwiftData

@MainActor
public final class PlanRepository {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
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
}
