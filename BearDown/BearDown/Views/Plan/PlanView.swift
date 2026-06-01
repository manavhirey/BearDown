import SwiftUI

public struct PlanView: View {
    public init() {}
    public var body: some View {
        NavigationStack {
            ContentUnavailableView("Plan",
                                   systemImage: "list.bullet.rectangle",
                                   description: Text("Coming soon."))
                .navigationTitle("Plan")
        }
    }
}
