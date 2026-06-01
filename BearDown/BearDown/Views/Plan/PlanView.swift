import SwiftUI

public struct PlanView: View {
    @StateObject private var vm: PlanViewModel
    @EnvironmentObject private var env: AppEnvironment
    @State private var selected: Workout?

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: PlanViewModel(env: env))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if vm.weeks.isEmpty {
                    ContentUnavailableView("No plan yet",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text("Ask the Coach to build one."))
                } else {
                    List {
                        ForEach(vm.weeks) { section in
                            Section {
                                ForEach(section.workouts) { w in
                                    Button { selected = w } label: { row(w) }.buttonStyle(.plain)
                                }
                            } header: {
                                HStack {
                                    Text(section.label).font(.subheadline.bold())
                                    Spacer()
                                    Text(section.progress)
                                        .font(.caption)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.gray.opacity(0.15), in: Capsule())
                                }
                            }
                        }
                    }
                    .refreshable { vm.refresh() }
                }
            }
            .navigationTitle("Plan")
            .sheet(item: $selected) { w in
                WorkoutDetailSheet(vm: WorkoutDetailViewModel(env: env, workout: w))
            }
            .onAppear { vm.refresh() }
        }
    }

    private func row(_ w: Workout) -> some View {
        HStack {
            Text(dayLabel(w.date)).frame(width: 64, alignment: .leading).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(w.title).bold()
                HStack(spacing: 6) {
                    ForEach(badges(w), id: \.self) { Text($0).font(.caption) }
                }
            }
            Spacer()
            switch w.status {
            case .pending:   Image(systemName: "circle").foregroundStyle(.secondary)
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f.string(from: d)
    }
    private func badges(_ w: Workout) -> [String] {
        var b: [String] = []
        let kinds = Set(w.blocks.map(\.kind))
        if kinds.contains(.strength) { b.append("💪") }
        if kinds.contains(.cardio)   { b.append("🏃") }
        if kinds.contains(.mobility) { b.append("🧘") }
        return b
    }
}
