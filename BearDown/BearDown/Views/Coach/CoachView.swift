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
                messagesScroll
                if case let .error(msg) = vm.state {
                    errorBanner(msg)
                        .transition(.opacity)
                }
                composer
            }
            .background(Color(.systemBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        vm.newChat()
                    } label: {
                        Text("NEW CHAT")
                            .font(BDStyle.monoTiny)
                            .tracking(BDStyle.trackingWide)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .animation(.easeInOut(duration: 0.18), value: vm.state)
            .onAppear { vm.refresh() }
        }
    }

    // MARK: – In-page title

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COACH")
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingHero)
                .foregroundStyle(.secondary)
            Text("Today's session")
                .font(BDStyle.displayMedium)
                .foregroundStyle(.primary)
            BDHairline().padding(.top, 8)
        }
        .padding(.bottom, 4)
    }

    // MARK: – Messages

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    pageHeader
                    ForEach(vm.messages) { m in
                        ChatBubble(role: m.role,
                                   text: m.text,
                                   toolChips: vm.chips(for: m),
                                   onChipTap: { chip in
                                       if let d = chip.workoutDate {
                                           nav.focusedDate = d
                                           nav.selectedTab = 0
                                       }
                                   })
                            .id(m.id)
                    }
                    if vm.state == .streaming && !vm.liveAssistantText.isEmpty {
                        ChatBubble(role: .assistant, text: vm.liveAssistantText + "▍")
                            .id("live")
                    }
                    Color.clear.frame(height: 4)
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: – Error

    private func errorBanner(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BDHairline()
            HStack(alignment: .top, spacing: 12) {
                BDStatusPill(label: "Send failed",
                             systemImage: "exclamationmark.triangle.fill",
                             color: .red)
                Spacer(minLength: 0)
                if vm.lastUserText != nil {
                    Button {
                        Task { await vm.retry() }
                    } label: {
                        Text("RETRY")
                            .font(BDStyle.monoTiny)
                            .tracking(BDStyle.trackingWide)
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Retry sending message")
                }
            }
            Text(msg)
                .font(BDStyle.bodySerif)
                .foregroundStyle(.red.opacity(0.9))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.05))
    }

    // MARK: – Composer

    private var composer: some View {
        VStack(spacing: 0) {
            BDHairline()
            HStack(alignment: .bottom, spacing: 12) {
                TextField("", text: $vm.draft, axis: .vertical)
                    .font(BDStyle.bodySerif)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.primary.opacity(0.10), lineWidth: 1)
                    )
                    .overlay(alignment: .leading) {
                        if vm.draft.isEmpty {
                            Text("WRITE TO YOUR COACH")
                                .font(BDStyle.monoTiny)
                                .tracking(BDStyle.trackingWide)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 16)
                                .allowsHitTesting(false)
                        }
                    }

                Button {
                    Task { await vm.send() }
                } label: {
                    Text("SEND")
                        .font(BDStyle.monoSmall)
                        .tracking(BDStyle.trackingWide)
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
                .controlSize(.large)
                .disabled(vm.state == .streaming
                          || vm.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }
}
