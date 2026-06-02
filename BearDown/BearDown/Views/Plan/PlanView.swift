import SwiftUI

public struct PlanView: View {
    @StateObject private var vm: PlanViewModel
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var nav: AppNavigation
    @State private var selected: Workout?

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: PlanViewModel(env: env))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if vm.weeks.isEmpty {
                    if vm.hasPlan {
                        loadingState
                    } else {
                        emptyState
                    }
                } else {
                    planScroll
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { w in
                WorkoutDetailSheet(vm: WorkoutDetailViewModel(env: env, workout: w))
            }
            .onAppear { vm.refresh() }
        }
    }

    // MARK: – Plan scroll

    private var planScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BDStyle.sectionSpacing) {
                hero
                ForEach(vm.weeks) { section in
                    weekSection(section)
                }
                Color.clear.frame(height: 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .refreshable { vm.refresh() }
    }

    // MARK: – Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            BDEyebrow(heroEyebrow)
            Text("Training Block")
                .font(BDStyle.displayTitle)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            BDHairline().padding(.top, 4)
        }
    }

    private var heroEyebrow: String {
        guard let first = vm.weeks.first?.id,
              let lastStart = vm.weeks.last?.id,
              let lastEnd = Calendar.current.date(byAdding: .day, value: 6, to: lastStart) else {
            return "\(vm.weeks.count) WEEKS"
        }
        let f = Self.heroRangeFormatter
        return "\(vm.weeks.count) WEEKS · \(f.string(from: first)) – \(f.string(from: lastEnd))"
    }

    // MARK: – Week section

    private func weekSection(_ section: PlanViewModel.WeekSection) -> some View {
        let done = section.workouts.filter { $0.status == .completed }.count
        let total = section.workouts.count
        let progress = String(format: "%02d / %02d", done, total)
        let weekIndex = (vm.weeks.firstIndex(where: { $0.id == section.id }) ?? 0) + 1
        let weekTitle = String(format: "Week %02d", weekIndex)

        return VStack(alignment: .leading, spacing: 14) {
            BDSectionHeader(
                title: weekTitle,
                trailing: AnyView(progressLabel(progress))
            )
            BDLabel(dateRangeLabel(for: section.id))
            VStack(spacing: 0) {
                ForEach(Array(section.workouts.enumerated()), id: \.element.id) { idx, w in
                    Button { selected = w } label: { workoutRow(w) }
                        .buttonStyle(.plain)
                    if idx < section.workouts.count - 1 {
                        BDHairline().padding(.leading, 56)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func progressLabel(_ text: String) -> some View {
        Text(text)
            .font(BDStyle.monoSmall)
            .tracking(BDStyle.trackingWide)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    // MARK: – Workout row

    private func workoutRow(_ w: Workout) -> some View {
        let kinds: [BlockKind] = orderedKinds(for: w)
        return HStack(alignment: .top, spacing: 14) {
            dateGutter(w.date)
            VStack(alignment: .leading, spacing: 8) {
                Text(w.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if !kinds.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(kinds, id: \.self) { kind in
                            BDKindChip(emoji: emoji(for: kind), label: label(for: kind))
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            statusIcon(w.status)
                .padding(.top, 2)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func dateGutter(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.weekday(.abbreviated))
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingWide)
                .foregroundStyle(.secondary)
            Text(date, format: .dateTime.day())
                .font(.system(.title3, design: .serif).weight(.bold))
                .monospacedDigit()
        }
        .frame(width: 42, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(_ status: WorkoutStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.body.weight(.regular))
                .foregroundStyle(.secondary.opacity(0.6))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    // MARK: – Empty / loading states

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 18) {
            BDEyebrow("Syncing")
            Text("Loading your plan…")
                .font(BDStyle.displayMedium)
                .fixedSize(horizontal: false, vertical: true)
            BDHairline()
            Text("Pulling your training block down from iCloud. This usually takes a few seconds.")
                .font(BDStyle.bodySerif)
                .foregroundStyle(BDStyle.mutedText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            BDEyebrow("No plan yet")
            Text("Build your block.")
                .font(BDStyle.displayTitle)
                .fixedSize(horizontal: false, vertical: true)
            BDHairline()
            Text("Ask the Coach to draft a four-week training block tailored to your goals, schedule, and recovery.")
                .font(BDStyle.bodySerif)
                .foregroundStyle(BDStyle.mutedText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                nav.selectedTab = 2
            } label: {
                HStack(spacing: 8) {
                    Text("Ask Coach".uppercased())
                        .font(BDStyle.monoSmall)
                        .tracking(BDStyle.trackingWide)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .controlSize(.large)
            .padding(.top, 6)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: – Helpers

    private static let heroRangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private static let weekRangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func dateRangeLabel(for weekStart: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let f = Self.weekRangeFormatter
        return "\(f.string(from: weekStart)) – \(f.string(from: end))"
    }

    // Order kinds the way they appear in the workout's blocks (de-duped),
    // matching the WorkoutDetailSheet ordering so chips read consistently.
    private func orderedKinds(for w: Workout) -> [BlockKind] {
        var seen = Set<BlockKind>()
        var out: [BlockKind] = []
        for k in w.blocks.sorted(by: { $0.order < $1.order }).map(\.kind) where seen.insert(k).inserted {
            out.append(k)
        }
        return out
    }

    private func emoji(for kind: BlockKind) -> String {
        switch kind {
        case .strength: return "💪"
        case .cardio:   return "🏃"
        case .mobility: return "🧘"
        }
    }

    private func label(for kind: BlockKind) -> String {
        switch kind {
        case .strength: return "Strength"
        case .cardio:   return "Cardio"
        case .mobility: return "Mobility"
        }
    }
}
