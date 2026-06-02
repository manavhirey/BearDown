import SwiftUI

public struct PlanDetailView: View {
    @StateObject private var vm: PlanDetailViewModel
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Workout?
    @State private var showDeleteConfirm = false
    @State private var actionError: String?

    public init(plan: TrainingPlan) {
        _vm = StateObject(wrappedValue: PlanDetailViewModel(plan: plan))
    }

    public var body: some View {
        planScroll
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
            .sheet(item: $selected) { w in
                WorkoutDetailSheet(vm: WorkoutDetailViewModel(env: env, workout: w))
            }
            .alert("Delete \"\(vm.title)\"?",
                   isPresented: $showDeleteConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { performDelete() }
            } message: {
                Text(vm.isActive
                     ? "This is your active plan. Today will be empty until you activate or create another plan. All workouts and any scheduled notifications will be removed."
                     : "All workouts in this plan will be removed.")
            }
            .alert("Action failed",
                   isPresented: Binding(get: { actionError != nil },
                                        set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
            .onAppear { vm.refresh() }
    }

    private var planScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BDStyle.sectionSpacing) {
                hero
                ForEach(vm.weeks) { section in weekSection(section) }
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

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            BDEyebrow(eyebrow)
            Text(vm.title)
                .font(BDStyle.displayTitle)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !vm.goal.isEmpty {
                Text(vm.goal)
                    .font(BDStyle.bodySerif)
                    .foregroundStyle(BDStyle.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BDHairline().padding(.top, 4)
            if vm.isActive {
                HStack {
                    Spacer()
                    BDStatusPill(label: "Active",
                                 systemImage: "circle.fill",
                                 color: .green)
                }
            }
        }
    }

    private var eyebrow: String {
        let f = Self.eyebrowFormatter
        return "\(f.string(from: vm.startDate)) – \(f.string(from: vm.endDate))".uppercased()
    }

    private func weekSection(_ section: PlanDetailViewModel.WeekSection) -> some View {
        let done = section.workouts.filter { $0.status == .completed }.count
        let total = section.workouts.count
        let progress = String(format: "%02d / %02d", done, total)
        let weekIndex = (vm.weeks.firstIndex(where: { $0.id == section.id }) ?? 0) + 1
        let weekTitle = String(format: "Week %02d", weekIndex)

        return VStack(alignment: .leading, spacing: 14) {
            BDSectionHeader(title: weekTitle, trailing: AnyView(progressLabel(progress)))
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
            statusIcon(w.status).padding(.top, 2)
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

    private var actionBar: some View {
        VStack(spacing: 0) {
            BDHairline()
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("DELETE")
                        .font(BDStyle.monoSmall)
                        .tracking(BDStyle.trackingWide)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
                .accessibilityIdentifier("plan.delete")

                if !vm.isActive {
                    Button {
                        performActivate()
                    } label: {
                        Text("MAKE ACTIVE")
                            .font(BDStyle.monoSmall)
                            .tracking(BDStyle.trackingWide)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.primary)
                    .controlSize(.large)
                    .accessibilityIdentifier("plan.makeActive")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }

    private func performActivate() {
        do {
            try env.plans.activate(planId: vm.planId)
            vm.refresh()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func performDelete() {
        do {
            try env.plans.delete(planId: vm.planId)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private static let eyebrowFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · yyyy"; return f
    }()

    private static let weekRangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func dateRangeLabel(for weekStart: Date) -> String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let f = Self.weekRangeFormatter
        return "\(f.string(from: weekStart)) – \(f.string(from: end))"
    }

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
