import SwiftUI

public struct WeekView: View {
    public init() {}
    public var body: some View {
        NavigationStack {
            ContentUnavailableView("Week",
                                   systemImage: "calendar",
                                   description: Text("Coming soon."))
                .navigationTitle("Week")
        }
    }
}
