import SwiftUI

public struct CoachView: View {
    @StateObject private var vm: CoachViewModel
    @EnvironmentObject private var nav: AppNavigation

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
                                           toolChips: vm.chips(for: m),
                                           onChipTap: { chip in
                                               if let d = chip.workoutDate {
                                                   nav.weekFocusedDate = d
                                                   nav.selectedTab = 0
                                               }
                                           })
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

}
