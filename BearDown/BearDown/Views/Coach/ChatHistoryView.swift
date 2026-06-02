import SwiftUI

public struct ChatHistoryView: View {
    @StateObject private var vm: ChatHistoryViewModel
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ConversationSummary?

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: ChatHistoryViewModel(env: env))
    }

    public var body: some View {
        Group {
            if vm.conversations.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete this chat?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let c = pendingDelete { vm.delete(id: c.id) }
            }
        } message: {
            Text("All messages will be removed.")
        }
        .onAppear { vm.refresh() }
    }

    // MARK: – List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader
            List {
                ForEach(Array(vm.conversations.enumerated()), id: \.element.id) { idx, c in
                    row(c)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = c
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        .overlay(alignment: .bottom) {
                            if idx < vm.conversations.count - 1 {
                                BDHairline()
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .refreshable { vm.refresh() }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHATS")
                .font(BDStyle.monoTiny)
                .tracking(BDStyle.trackingHero)
                .foregroundStyle(.secondary)
            Text("History")
                .font(BDStyle.displayTitle)
                .foregroundStyle(.primary)
            BDHairline().padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func row(_ c: ConversationSummary) -> some View {
        Button {
            vm.switchTo(id: c.id)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if c.isCurrent {
                    Rectangle().fill(Color.primary).frame(width: 2)
                } else {
                    Color.clear.frame(width: 2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    Text(c.lastMessageAt, format: relativeFormat)
                        .font(BDStyle.monoTiny)
                        .tracking(BDStyle.trackingWide)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.row.\(c.id.uuidString)")
    }

    // MARK: – Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            BDEyebrow("No past chats")
            Text("Your conversation list\nwill appear here.")
                .font(BDStyle.displayMedium)
                .fixedSize(horizontal: false, vertical: true)
            BDHairline()
            Text("Tap a coach reply to start.")
                .font(BDStyle.bodySerif)
                .foregroundStyle(BDStyle.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var relativeFormat: Date.RelativeFormatStyle {
        .relative(presentation: .named, unitsStyle: .abbreviated)
    }
}
