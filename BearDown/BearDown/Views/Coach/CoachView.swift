import SwiftUI

public struct CoachView: View {
    public init() {}
    public var body: some View {
        NavigationStack {
            ContentUnavailableView("Coach",
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Coming soon."))
                .navigationTitle("Coach")
        }
    }
}
