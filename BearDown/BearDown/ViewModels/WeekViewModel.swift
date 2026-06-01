import Combine
import Foundation

@MainActor
public final class WeekViewModel: ObservableObject {
    public nonisolated let objectWillChange = PassthroughSubject<Void, Never>()

    @Published public private(set) var weekStart: Date
    @Published public private(set) var workoutsByDate: [Date: Workout] = [:]

    private let env: AppEnvironment

    public init(env: AppEnvironment, anchor: Date = .now) {
        self.env = env
        self.weekStart = Self.weekStart(for: anchor)
        refresh()
    }

    public var days: [Date] {
        let cal = Calendar.current
        return (0..<7).map { cal.date(byAdding: .day, value: $0, to: weekStart)! }
    }

    public func step(by weeks: Int) {
        weekStart = Calendar.current.date(byAdding: .day, value: weeks * 7, to: weekStart)!
        refresh()
    }

    public func jumpTo(_ date: Date) {
        weekStart = Self.weekStart(for: date)
        refresh()
    }

    public func refresh() {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart)!
        let ws = (try? env.workouts.workoutsBetween(start: weekStart, end: end)) ?? []
        workoutsByDate = Dictionary(uniqueKeysWithValues: ws.map { (Calendar.current.startOfDay(for: $0.date), $0) })
    }

    private static func weekStart(for date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)!.start
    }
}
