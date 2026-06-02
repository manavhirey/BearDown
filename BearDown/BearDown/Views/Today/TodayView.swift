import SwiftUI

public struct TodayView: View {
    @StateObject private var vm: TodayViewModel
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var nav: AppNavigation
    @State private var selectedWorkout: Workout?

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: TodayViewModel(env: env))
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BDStyle.sectionSpacing) {
                    dayHeader
                    content
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemBackground))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { g in
                        if g.translation.width < -40 { vm.step(by: 1) }
                        else if g.translation.width > 40 { vm.step(by: -1) }
                    }
            )
            .navigationTitle(vm.isToday ? "Today" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !vm.isToday {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { vm.jumpToToday() } label: {
                            Text("TODAY")
                                .font(BDStyle.monoSmall)
                                .tracking(BDStyle.trackingWide)
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Jump to today")
                    }
                }
            }
            .sheet(item: $selectedWorkout) { w in
                WorkoutDetailSheet(vm: WorkoutDetailViewModel(env: env, workout: w))
            }
            .onChange(of: nav.focusedDate) { _, newValue in
                if let d = newValue { vm.jumpTo(d); nav.focusedDate = nil }
            }
            .onAppear { vm.refresh() }
        }
    }

    // MARK: – Day header

    private var dayHeader: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                chevronButton(systemImage: "chevron.left", label: "Previous day") {
                    vm.step(by: -1)
                }
                Spacer()
                VStack(spacing: 8) {
                    Text(vm.focusedDate, format: .dateTime.weekday(.wide))
                        .font(BDStyle.displayTitle)
                        .textCase(.uppercase)
                        .tracking(1.5)
                        .multilineTextAlignment(.center)
                    BDEyebrow(dateStrip)
                }
                Spacer()
                chevronButton(systemImage: "chevron.right", label: "Next day") {
                    vm.step(by: 1)
                }
            }
            BDHairline()
        }
    }

    private func chevronButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.heavy))
                .foregroundStyle(.primary.opacity(0.7))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private var dateStrip: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d · yyyy"
        return f.string(from: vm.focusedDate)
    }

    // MARK: – Content

    @ViewBuilder
    private var content: some View {
        if let w = vm.workouts.first {
            workoutCard(w)
        } else {
            restDay
        }
    }

    // MARK: – Workout card

    private func workoutCard(_ w: Workout) -> some View {
        let sortedBlocks: [WorkoutBlock] = w.blocks.sorted { $0.order < $1.order }
        return Button { selectedWorkout = w } label: {
            VStack(alignment: .leading, spacing: BDStyle.groupSpacing) {
                workoutHero(w)
                if !w.summary.isEmpty {
                    Text(w.summary)
                        .font(BDStyle.bodySerif)
                        .lineSpacing(5)
                        .foregroundStyle(BDStyle.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !sortedBlocks.isEmpty {
                    blockList(sortedBlocks)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens workout details")
    }

    private func workoutHero(_ w: Workout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(w.title)
                    .font(BDStyle.displayMedium)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(.primary.opacity(0.35))
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                BDStatusPill(
                    label: statusLabel(w),
                    systemImage: statusIcon(w),
                    color: statusColor(w)
                )
                ForEach(kindChips(for: w), id: \.self) { kind in
                    BDKindChip(emoji: symbol(for: kind), label: kindTitle(kind))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func blockList(_ blocks: [WorkoutBlock]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            BDHairline()
            ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, b in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(String(format: "%02d", idx + 1))
                        .font(BDStyle.monoSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .leading)
                    Text(symbol(for: b.kind))
                        .font(.body)
                    Text((b.title.isEmpty ? kindTitle(b.kind) : b.title).uppercased())
                        .font(BDStyle.monoSmall)
                        .tracking(BDStyle.trackingTight)
                        .foregroundStyle(.primary.opacity(0.85))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: – Rest day

    private var restDay: some View {
        VStack(alignment: .leading, spacing: 14) {
            BDEyebrow("Rest Day")
            Text("Recover.")
                .font(BDStyle.displayTitle)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing scheduled. Sleep, walk, eat well. The next session lands tomorrow.")
                .font(BDStyle.bodySerif)
                .lineSpacing(5)
                .foregroundStyle(BDStyle.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: – Helpers

    private func symbol(for kind: BlockKind) -> String {
        switch kind {
        case .strength: return "💪"
        case .cardio:   return "🏃"
        case .mobility: return "🧘"
        }
    }

    private func kindTitle(_ kind: BlockKind) -> String {
        switch kind {
        case .strength: return "Strength"
        case .cardio:   return "Cardio"
        case .mobility: return "Mobility"
        }
    }

    private func kindChips(for w: Workout) -> [BlockKind] {
        var seen = Set<BlockKind>()
        var out: [BlockKind] = []
        for k in w.blocks.map(\.kind) where seen.insert(k).inserted {
            out.append(k)
        }
        return out
    }

    private func statusLabel(_ w: Workout) -> String {
        switch w.status {
        case .pending:   return "Pending"
        case .completed: return "Completed"
        case .failed:    return "Failed"
        }
    }

    private func statusIcon(_ w: Workout) -> String {
        switch w.status {
        case .pending:   return "circle"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    private func statusColor(_ w: Workout) -> Color {
        switch w.status {
        case .pending:   return .secondary
        case .completed: return .green
        case .failed:    return .red
        }
    }
}
