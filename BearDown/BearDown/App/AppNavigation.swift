import Combine
import SwiftUI

@MainActor
public final class AppNavigation: ObservableObject {
    public nonisolated let objectWillChange = PassthroughSubject<Void, Never>()

    /// 0 = Week, 1 = Plan, 2 = Coach, 3 = Settings
    @Published public var selectedTab: Int = 0

    /// When set non-nil, WeekView jumps to the week containing this date and clears it.
    @Published public var weekFocusedDate: Date?

    public init() {}
}
