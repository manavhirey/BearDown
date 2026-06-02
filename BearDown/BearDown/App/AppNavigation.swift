import Combine
import SwiftUI

@MainActor
public final class AppNavigation: ObservableObject {

    /// 0 = Today, 1 = Plan, 2 = Coach, 3 = Settings
    @Published public var selectedTab: Int = 0

    /// When set non-nil, TodayView jumps to this date and clears it.
    @Published public var focusedDate: Date?

    public init() {}
}
