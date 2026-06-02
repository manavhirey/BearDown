import Combine
import Foundation

@MainActor
public final class TodayViewModel: ObservableObject {

    @Published public private(set) var focusedDate: Date
    @Published public private(set) var workouts: [Workout] = []

    private let env: AppEnvironment

    public init(env: AppEnvironment, anchor: Date = .now) {
        self.env = env
        self.focusedDate = Calendar.current.startOfDay(for: anchor)
        // Initial data load happens via the owning view's .onAppear.
    }

    public var isToday: Bool {
        Calendar.current.isDateInToday(focusedDate)
    }

    public func step(by days: Int) {
        focusedDate = Calendar.current.date(byAdding: .day, value: days, to: focusedDate)!
        refresh()
    }

    public func jumpToToday() {
        focusedDate = Calendar.current.startOfDay(for: .now)
        refresh()
    }

    public func jumpTo(_ date: Date) {
        focusedDate = Calendar.current.startOfDay(for: date)
        refresh()
    }

    public func refresh() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: focusedDate)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        workouts = (try? env.workouts.workoutsBetween(start: start, end: end)) ?? []
    }
}
