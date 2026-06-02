import SwiftUI

public enum PlansRoute: Hashable {
    case detail(planId: UUID)
}

public struct PlansListView: View {
    @StateObject private var vm: PlansListViewModel
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var nav: AppNavigation
    @State private var path = NavigationPath()

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: PlansListViewModel(env: env))
    }

    public var body: some View {
        NavigationStack(path: $path) {
            Group {
                if vm.plans.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PlansRoute.self) { route in
                switch route {
                case .detail(let id):
                    if let plan = vm.plan(id: id) {
                        PlanDetailView(plan: plan)
                            .onDisappear { vm.refresh() }
                    } else {
                        Text("Plan not found")
                            .font(BDStyle.bodySerif)
                    }
                }
            }
            .onAppear { vm.refresh() }
            .onChange(of: nav.pendingPlanDetail) { _, newValue in
                if let id = newValue {
                    path.append(PlansRoute.detail(planId: id))
                    nav.pendingPlanDetail = nil
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BDStyle.sectionSpacing) {
                pageHeader
                ForEach(Array(vm.plans.enumerated()), id: \.element.id) { idx, p in
                    if idx > 0 { BDHairline() }
                    NavigationLink(value: PlansRoute.detail(planId: p.id)) {
                        PlanCard(plan: p)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("plan.card.\(p.title)")
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

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PLANS")
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingHero)
                .foregroundStyle(.secondary)
            Text("Training blocks")
                .font(BDStyle.displayTitle)
                .foregroundStyle(.primary)
            BDHairline().padding(.top, 8)
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            BDEyebrow("No plans yet")
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
                    Text("ASK COACH")
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
}

private struct PlanCard: View {
    let plan: PlansListViewModel.PlanSummary

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d · yyyy"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                BDEyebrow(rangeText)
                Spacer()
                if plan.isActive {
                    BDStatusPill(label: "Active",
                                 systemImage: "circle.fill",
                                 color: .green)
                }
            }
            Text(plan.title)
                .font(BDStyle.displayMedium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !plan.goal.isEmpty {
                Text(plan.goal)
                    .font(BDStyle.bodySerif)
                    .foregroundStyle(BDStyle.mutedText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BDHairline().padding(.top, 4)
            progressRow
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var rangeText: String {
        let f = Self.rangeFormatter
        return "\(f.string(from: plan.startDate)) → \(f.string(from: plan.endDate))".uppercased()
    }

    private var progressRow: some View {
        HStack(spacing: 12) {
            ProgressBar(fraction: plan.total == 0 ? 0 : Double(plan.completed) / Double(plan.total))
                .frame(height: 4)
            Text(String(format: "%02d / %02d", plan.completed, plan.total))
                .font(BDStyle.monoSmall)
                .tracking(BDStyle.trackingWide)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.primary)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}
