import SwiftUI

public struct WeekView: View {
    @StateObject private var vm: WeekViewModel
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var nav: AppNavigation
    @State private var selectedWorkout: Workout?

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: WeekViewModel(env: env))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                header
                if vm.workoutsByDate.isEmpty {
                    ContentUnavailableView {
                        Label("No workouts this week", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("Ask the Coach to build a plan.")
                    } actions: {
                        Button("Open Coach") { nav.selectedTab = 2 }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(vm.days, id: \.self) { day in
                                dayCard(day)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Week")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { vm.jumpTo(.now) }
                }
            }
            .sheet(item: $selectedWorkout) { w in
                WorkoutDetailSheet(vm: WorkoutDetailViewModel(env: env, workout: w))
            }
            .onChange(of: nav.weekFocusedDate) { _, newValue in
                if let d = newValue { vm.jumpTo(d); nav.weekFocusedDate = nil }
            }
            .onAppear { vm.refresh() }
        }
    }

    private var header: some View {
        HStack {
            Button(action: { vm.step(by: -1) }) { Image(systemName: "chevron.left") }
            Spacer()
            Text(rangeLabel()).font(.headline)
            Spacer()
            Button(action: { vm.step(by: 1) }) { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal)
    }

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func rangeLabel() -> String {
        let last = vm.days.last ?? vm.weekStart
        let f = Self.rangeFormatter
        return "\(f.string(from: vm.weekStart)) – \(f.string(from: last))"
    }

    private func dayCard(_ day: Date) -> some View {
        let w = vm.workoutsByDate[Calendar.current.startOfDay(for: day)]
        let isToday = Calendar.current.isDateInToday(day)
        return Button {
            if let w { selectedWorkout = w }
        } label: {
            HStack(spacing: 12) {
                VStack {
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(day, format: .dateTime.day())
                        .font(.title2.bold())
                }
                .frame(width: 56)
                .padding(.vertical, 8)
                .background(isToday ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading) {
                    Text(w?.title ?? "Rest").font(.headline)
                    if let w {
                        HStack(spacing: 6) {
                            ForEach(badges(for: w), id: \.self) { Text($0).font(.caption) }
                        }
                    }
                }
                Spacer()
                statusIcon(w)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(w == nil)
    }

    private func badges(for w: Workout) -> [String] {
        var b: [String] = []
        let kinds = Set(w.blocks.map(\.kind))
        if kinds.contains(.strength) { b.append("💪") }
        if kinds.contains(.cardio)   { b.append("🏃") }
        if kinds.contains(.mobility) { b.append("🧘") }
        return b
    }
    @ViewBuilder
    private func statusIcon(_ w: Workout?) -> some View {
        if let w {
            switch w.status {
            case .pending:   Image(systemName: "circle").foregroundStyle(.secondary)
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }
}
