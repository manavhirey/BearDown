import Combine
import Foundation

@MainActor
public final class PlanDetailViewModel: ObservableObject {

    public struct WeekSection: Identifiable {
        public let id: Date          // weekStart
        public let workouts: [Workout]
    }

    @Published public private(set) var weeks: [WeekSection] = []
    @Published public private(set) var title: String = ""
    @Published public private(set) var goal: String = ""
    @Published public private(set) var startDate: Date = .now
    @Published public private(set) var endDate: Date = .now
    @Published public private(set) var isActive: Bool = false

    public let planId: UUID
    private let plan: TrainingPlan

    public init(plan: TrainingPlan) {
        self.plan = plan
        self.planId = plan.id
    }

    public func refresh() {
        title = plan.title
        goal = plan.goal
        startDate = plan.startDate
        endDate = plan.endDate
        isActive = plan.isActive

        let cal = Calendar.current
        let ws = plan.workouts.sorted { $0.date < $1.date }
        let grouped = Dictionary(grouping: ws) { cal.dateInterval(of: .weekOfYear, for: $0.date)!.start }
        weeks = grouped.keys.sorted().map { weekStart in
            let items = grouped[weekStart]!.sorted { $0.date < $1.date }
            return WeekSection(id: weekStart, workouts: items)
        }
    }
}
