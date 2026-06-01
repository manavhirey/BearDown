import SwiftUI

public struct CoachView: View {
    @StateObject private var vm: CoachViewModel

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: CoachViewModel(env: env))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.messages) { m in
                                ChatBubble(role: m.role,
                                           text: m.text,
                                           toolChips: chips(for: m))
                                    .id(m.id)
                            }
                            if vm.state == .streaming && !vm.liveAssistantText.isEmpty {
                                ChatBubble(role: .assistant, text: vm.liveAssistantText + "▍")
                                    .id("live")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: vm.messages.count) { _, _ in
                        if let last = vm.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                if case let .error(msg) = vm.state {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(msg).foregroundStyle(.red).font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            if vm.lastUserText != nil {
                                Button("Retry") { Task { await vm.retry() } }
                                    .font(.footnote)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                    .background(.red.opacity(0.08))
                }

                Divider()
                HStack(alignment: .bottom) {
                    TextField("Message your coach…", text: $vm.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                    Button {
                        Task { await vm.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(vm.state == .streaming
                              || vm.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Coach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat") { vm.newChat() }
                }
            }
            .onAppear { vm.refresh() }
        }
    }

    private func chips(for m: ChatMessage) -> [ChatBubble.ToolChip] {
        guard let raw = m.toolCallsJSON,
              let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            let id = (dict["id"] as? String) ?? UUID().uuidString
            let name = (dict["name"] as? String) ?? "?"
            let input = (dict["input"] as? [String: Any]) ?? [:]
            switch name {
            case "upsert_workout":
                let date = input["date"] as? String ?? "?"
                let title = input["title"] as? String ?? "Workout"
                return .init(id: id, label: "Scheduled \(title) — \(date)", isError: false,
                             workoutDate: parseIso(date))
            case "delete_workout":
                let date = input["date"] as? String ?? "?"
                return .init(id: id, label: "Deleted workout on \(date)", isError: false,
                             workoutDate: parseIso(date))
            case "get_recent_history":
                return .init(id: id, label: "Reviewed recent history", isError: false, workoutDate: nil)
            default:
                return .init(id: id, label: "Called \(name)", isError: false, workoutDate: nil)
            }
        }
    }

    private func parseIso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }
}
