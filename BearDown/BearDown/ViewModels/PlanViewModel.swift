import Combine
import Foundation

@MainActor
public final class PlanViewModel: ObservableObject {

    public struct WeekSection: Identifiable {
        public let id: Date          // weekStart
        public let label: String
        public let progress: String
        public let workouts: [Workout]
    }

    @Published public private(set) var weeks: [WeekSection] = []

    private let env: AppEnvironment
    public init(env: AppEnvironment) {
        self.env = env
        // Initial data load happens via the owning view's .onAppear.
    }

    public func refresh() {
        guard let plan = (try? env.plans.activePlan()) else {
            weeks = []
            return
        }
        let cal = Calendar.current
        let ws = plan.workouts.sorted { $0.date < $1.date }
        let grouped = Dictionary(grouping: ws) { cal.dateInterval(of: .weekOfYear, for: $0.date)!.start }
        weeks = grouped.keys.sorted().enumerated().map { (idx, weekStart) in
            let items = grouped[weekStart]!.sorted { $0.date < $1.date }
            let done = items.filter { $0.status == .completed }.count
            let total = items.count
            let end = cal.date(byAdding: .day, value: 6, to: weekStart)!
            let f = DateFormatter(); f.dateFormat = "MMM d"
            let label = "Week \(idx + 1) · \(f.string(from: weekStart)) – \(f.string(from: end))"
            return WeekSection(id: weekStart, label: label,
                               progress: "\(done)/\(total) complete",
                               workouts: items)
        }
    }
}
