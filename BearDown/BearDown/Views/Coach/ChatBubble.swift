import SwiftUI

public struct ChatBubble: View {
    public let role: ChatRole
    public let text: String
    public let toolChips: [ToolChip]
    public let onChipTap: (ToolChip) -> Void

    public struct ToolChip: Identifiable, Equatable {
        public let id: String
        public let label: String
        public let isError: Bool
        public let workoutDate: Date?

        public init(id: String, label: String, isError: Bool, workoutDate: Date?) {
            self.id = id; self.label = label; self.isError = isError; self.workoutDate = workoutDate
        }
    }

    public init(role: ChatRole,
                text: String,
                toolChips: [ToolChip] = [],
                onChipTap: @escaping (ToolChip) -> Void = { _ in }) {
        self.role = role
        self.text = text
        self.toolChips = toolChips
        self.onChipTap = onChipTap
    }

    public var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if !text.isEmpty {
                    Text(text)
                        .textSelection(.enabled)
                }
                ForEach(toolChips) { chip in
                    Button { onChipTap(chip) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: chip.isError ? "exclamationmark.triangle.fill" : "calendar")
                            Text(chip.label).font(.footnote)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(chip.isError ? .yellow.opacity(0.25) : .blue.opacity(0.15),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(role == .user ? .blue.opacity(0.15) : .gray.opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 14))
            if role == .assistant { Spacer(minLength: 40) }
        }
    }
}
