import SwiftUI

public enum ProposalApplyMode: Equatable {
    case addInactive, addAndSwitch, update
}

public struct ProposalChipView: View {
    public let chip: ProposalChip
    public let onApply: (ProposalChip, ProposalApplyMode) -> Void
    public let onDismiss: (ProposalChip) -> Void
    public let onAppliedTap: (ProposalChip) -> Void

    public init(chip: ProposalChip,
                onApply: @escaping (ProposalChip, ProposalApplyMode) -> Void,
                onDismiss: @escaping (ProposalChip) -> Void,
                onAppliedTap: @escaping (ProposalChip) -> Void = { _ in }) {
        self.chip = chip
        self.onApply = onApply
        self.onDismiss = onDismiss
        self.onAppliedTap = onAppliedTap
    }

    public var body: some View {
        switch chip.envelope.status {
        case .pending:    pendingBody
        case .applied:    appliedBody
        case .dismissed:  dismissedBody
        }
    }

    // MARK: – Pending

    private var pendingBody: some View {
        container(strokeOpacity: 0.18, dashed: false) {
            header(symbol: chip.envelope.mode == .add ? "plus.circle.fill" : "arrow.triangle.2.circlepath",
                   title: chip.envelope.mode == .add
                       ? "PROPOSED PLAN: \(chip.envelope.planTitle)"
                       : "PROPOSED UPDATE TO: \(chip.envelope.planTitle)",
                   tint: .primary)
            subLabel(text: pendingSubLabel)
            ViewThatFits {
                singleRowButtons
                stackedButtons
            }
        }
    }

    private var pendingSubLabel: String {
        let countWord = chip.envelope.mode == .add ? "WORKOUTS" : "WORKOUTS REPLACE"
        let range = dateRangeText
        return "\(chip.workoutCount) \(countWord)\(range.isEmpty ? "" : " · \(range)")"
    }

    private var dateRangeText: String {
        guard let first = chip.firstDate, let last = chip.lastDate else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let a = f.string(from: first).uppercased()
        let b = f.string(from: last).uppercased()
        return first == last ? a : "\(a) → \(b)"
    }

    @ViewBuilder
    private var singleRowButtons: some View {
        if chip.envelope.mode == .add {
            HStack(spacing: 8) {
                addInactiveButton
                addAndSwitchButton
                dismissButton
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                updatePlanButton
                dismissButton
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var stackedButtons: some View {
        if chip.envelope.mode == .add {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    addInactiveButton
                    addAndSwitchButton
                }
                dismissButton
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                updatePlanButton
                dismissButton
            }
        }
    }

    private var addInactiveButton: some View {
        Button("ADD AS INACTIVE") { onApply(chip, .addInactive) }
            .buttonStyle(.bordered)
            .tint(.primary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.addInactive")
    }

    private var addAndSwitchButton: some View {
        Button("ADD & SWITCH") { onApply(chip, .addAndSwitch) }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.addAndSwitch")
    }

    private var updatePlanButton: some View {
        Button("UPDATE PLAN") { onApply(chip, .update) }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.update")
    }

    private var dismissButton: some View {
        Button("DISMISS") { onDismiss(chip) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(BDStyle.monoTiny)
            .accessibilityIdentifier("proposal.dismiss")
    }

    // MARK: – Applied

    private var appliedBody: some View {
        let modeLabel: String
        switch chip.envelope.appliedMode {
        case .inactive: modeLabel = "ADDED AS INACTIVE"
        case .switchPlan: modeLabel = "ADDED & SWITCHED"
        case .update: modeLabel = "UPDATED"
        case .none: modeLabel = "APPLIED"
        }
        let sub = chip.workoutCount > 0
            ? "\(chip.workoutCount) WORKOUTS\(dateRangeText.isEmpty ? "" : " · \(dateRangeText)") · \(modeLabel)"
            : modeLabel
        let inner = container(strokeOpacity: 0.4, dashed: true, background: BDStyle.chipBackground.opacity(0.6)) {
            header(symbol: "checkmark.seal.fill",
                   title: "APPLIED: \(chip.envelope.planTitle)",
                   tint: .secondary)
            subLabel(text: sub)
        }
        if chip.envelope.appliedPlanId != nil {
            return AnyView(Button { onAppliedTap(chip) } label: { inner }.buttonStyle(.plain))
        }
        return AnyView(inner)
    }

    // MARK: – Dismissed

    private var dismissedBody: some View {
        container(strokeOpacity: 0.3, dashed: true, background: .clear) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "nosign")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("DISMISSED: \(chip.envelope.planTitle)".uppercased())
                    .font(BDStyle.monoSmall)
                    .tracking(BDStyle.trackingWide)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(subLabelText)
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingTight)
                .strikethrough()
                .foregroundStyle(.secondary)
        }
    }

    private var subLabelText: String {
        let range = dateRangeText
        return "\(chip.workoutCount) WORKOUTS\(range.isEmpty ? "" : " · \(range)")"
    }

    // MARK: – Shared scaffolding

    @ViewBuilder
    private func header(symbol: String, title: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(BDStyle.monoSmall)
                .tracking(BDStyle.trackingWide)
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func subLabel(text: String) -> some View {
        Text(text.uppercased())
            .font(BDStyle.monoTiny)
            .tracking(BDStyle.trackingTight)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func container<Content: View>(strokeOpacity: Double,
                                          dashed: Bool,
                                          background: Color = BDStyle.chipBackground,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(strokeOpacity),
                              style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
        )
    }
}
