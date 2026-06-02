import Combine
import Foundation

@MainActor
public final class PlansListViewModel: ObservableObject {

    public struct PlanSummary: Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public let goal: String
        public let startDate: Date
        public let endDate: Date
        public let isActive: Bool
        public let completed: Int
        public let total: Int
    }

    @Published public private(set) var plans: [PlanSummary] = []

    private let env: AppEnvironment
    public init(env: AppEnvironment) {
        self.env = env
    }

    public func refresh() {
        let rows = (try? env.plans.allPlans()) ?? []
        plans = rows.map { p in
            let total = p.workouts.count
            let done = p.workouts.filter { $0.status == .completed }.count
            return PlanSummary(id: p.id, title: p.title, goal: p.goal,
                               startDate: p.startDate, endDate: p.endDate,
                               isActive: p.isActive, completed: done, total: total)
        }
    }

    public func plan(id: UUID) -> TrainingPlan? {
        try? env.plans.plan(id: id)
    }
}
