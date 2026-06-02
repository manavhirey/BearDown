import SwiftUI

public struct ChatBubble: View {
    public let role: ChatRole
    public let text: String
    public let toolChips: [CoachChip]
    public let onChipTap: (ChatBubble.ToolChip) -> Void

    public struct ToolChip: Identifiable, Equatable {
        public let id: String
        public let label: String
        public let isError: Bool
        public let workoutDate: Date?
        public let planId: UUID?

        public init(id: String, label: String, isError: Bool,
                    workoutDate: Date?, planId: UUID? = nil) {
            self.id = id
            self.label = label
            self.isError = isError
            self.workoutDate = workoutDate
            self.planId = planId
        }
    }

    public init(role: ChatRole,
                text: String,
                toolChips: [CoachChip] = [],
                onChipTap: @escaping (ChatBubble.ToolChip) -> Void = { _ in }) {
        self.role = role
        self.text = text
        self.toolChips = toolChips
        self.onChipTap = onChipTap
    }

    public var body: some View {
        switch role {
        case .user:    userBubble
        case .assistant: assistantBlock
        }
    }

    // MARK: – User

    private var userBubble: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 6) {
                BDLabel("You")
                if !text.isEmpty {
                    Text(text)
                        .font(.system(.subheadline, design: .default))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }

    // MARK: – Assistant

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                BDLabel("Coach")
                Rectangle()
                    .fill(BDStyle.hairline)
                    .frame(height: 1)
            }
            if !text.isEmpty {
                Text(text)
                    .font(BDStyle.bodySerif)
                    .foregroundStyle(BDStyle.mutedText)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !toolChips.isEmpty {
                chipStrip
            }
        }
        .padding(.trailing, 24)
    }

    private var chipStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(toolChips) { chip in
                switch chip {
                case .planSwitch(let c):
                    Button { onChipTap(c) } label: { switchPlanChip(c) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.label)
                case .workout(let c):
                    Button { onChipTap(c) } label: { workoutChip(c) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.label)
                case .proposal:
                    // Placeholder — real renderer arrives in Task 15.
                    EmptyView()
                }
            }
        }
        .padding(.top, 2)
    }

    private func workoutChip(_ chip: ToolChip) -> some View {
        let tint: Color = chip.isError ? .red : .primary
        return HStack(spacing: 6) {
            Image(systemName: chip.isError ? "exclamationmark.triangle.fill" : "calendar")
                .font(.caption2.weight(.bold))
            Text(chip.label.uppercased())
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingTight)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(tint.opacity(chip.isError ? 1.0 : 0.75))
        .background(
            (chip.isError ? Color.red.opacity(0.10) : BDStyle.chipBackground),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(
                chip.isError ? Color.red.opacity(0.3) : Color.primary.opacity(0.12),
                lineWidth: 1
            )
        )
    }

    private func switchPlanChip(_ chip: ToolChip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right.circle.fill")
                .font(.callout.weight(.bold))
            Text(chip.label.uppercased())
                .font(BDStyle.monoSmall)
                .tracking(BDStyle.trackingWide)
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .foregroundStyle(Color(.systemBackground))
        .background(Color.primary, in: Capsule())
    }
}

/// Wraps chips so they reflow across lines instead of overflowing horizontally.
/// SwiftUI doesn't ship a flow layout pre-iOS 16; iOS 17 has `Layout` but a
/// simple VStack of HStacks is more predictable for short label sets.
private struct FlexibleChipRow<Chip: Identifiable, Content: View>: View {
    let chips: [Chip]
    let content: (Chip) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chips) { chip in
                content(chip)
            }
        }
    }
}
