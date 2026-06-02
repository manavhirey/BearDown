# Chat History — Design Spec

**Date:** 2026-06-02
**Status:** Approved for implementation planning
**Related:** [`2026-05-31-beardown-design.md`](./2026-05-31-beardown-design.md) (v1 single-conversation), [`2026-06-02-multi-plan-design.md`](./2026-06-02-multi-plan-design.md) (multi-plan, just shipped)

## Summary

Make the coach's past conversations browsable. The data layer already groups messages by `ChatMessage.conversationId` and the existing "NEW CHAT" toolbar button already mints a fresh `conversationId`. What's missing is a way for the user to list past conversations, jump back into one, and delete unwanted history. This spec adds a `ChatHistoryView` reachable via a new HISTORY toolbar button in `CoachView`; the existing `CoachView` continues to open into the most-recent (current) conversation as today.

## Goals

- A list of past conversations, accessible from the Coach tab via a `HISTORY` toolbar button.
- Tapping a row resumes that conversation as the current one — new messages append to its `conversationId`, and the agent's context includes the full thread on the next turn.
- Swipe-to-delete on each row, with destructive confirmation.
- No schema change. `ChatMessage` already supports this; the list is computed on the fly.
- CloudKit sync continues to work as it does today for `ChatMessage`.

## Non-goals

- No new `Conversation` SwiftData model. The list is derived from grouped `ChatMessage` rows.
- No LLM-generated conversation titles. Each conversation is labeled by its first non-empty user message; if none exists, it shows as `"New conversation"`.
- No per-plan chat scoping. The history list is global, independent of which plan is active.
- No read-only mode. Tapping a row resumes the conversation (continuable in place).
- No in-chat delete affordance. Deletion is via swipe-on-row in the history list.
- No search, pinning, starring, badging, multi-select, export, or share for v1.
- No empty-conversation pollution. Conversations with zero non-protocol messages are filtered out of the list.

## Architecture

The feature is additive to the existing chat surface. The Coach tab's NavigationStack gains a single typed destination (`CoachRoute.history`); the toolbar gains one button.

```
CoachView (existing — wrapped in NavigationStack with typed path)
  ├─ Toolbar
  │    ├─ [leading]  HISTORY   ← new; disabled while streaming
  │    └─ [trailing] NEW CHAT  ← unchanged
  ├─ Current conversation (existing rendering, unchanged)
  └─ .navigationDestination(for: CoachRoute.self)
       └─ ChatHistoryView
            ├─ ChatHistoryViewModel
            │   └─ env.chats.conversations() → [ConversationSummary]
            └─ Row swipe → env.chats.deleteConversation(id:)
                Row tap → env.chats.switchConversation(to: id) + dismiss
```

When `ChatHistoryView` dismisses, the existing `.onAppear { vm.refresh() }` on `CoachView` re-reads `currentConversationId()` through `CoachViewModel.refresh()` and the conversation switch propagates with no additional plumbing.

## Data layer

### `ChatMessage` (no change)

Existing model:

```swift
@Model
public final class ChatMessage {
    @Attribute(.unique) public var id: UUID
    public var roleRaw: String
    public var text: String
    public var toolCallsJSON: String?
    public var toolResultsJSON: String?
    public var conversationId: UUID
    public var createdAt: Date
    // …
}
```

`conversationId` already groups messages. No fields added, no migration, no CloudKit schema rev.

### `ConversationSummary` (new value type, declared in `ChatRepository.swift`)

```swift
public struct ConversationSummary: Identifiable, Equatable, Sendable {
    public let id: UUID                  // the conversationId
    public let title: String             // first non-empty user message, OR "New conversation"
    public let lastMessageAt: Date
    public let messageCount: Int         // excludes role=.user/text="" protocol rows
    public let isCurrent: Bool
}
```

`title` carries the **full** first-user-message string (not pre-truncated). `Text(.lineLimit(1))` does the visual truncation in the view. Keeps the model lossless and reusable.

## Repository layer

`ChatRepository` is the only thing that touches `ModelContext` for chat data (per CLAUDE.md). Three additive methods:

```swift
/// All conversations as summaries, sorted by lastMessageAt desc.
/// Empty conversations (messageCount == 0) are filtered out.
public func conversations() throws -> [ConversationSummary]

/// Switch the active conversation. No-op if `id` doesn't exist in the store.
public func switchConversation(to id: UUID)

/// Delete all messages with this conversationId. If `id` was the cached current,
/// mints a fresh conversationId (same end-state as archiveCurrentConversation()).
public func deleteConversation(id: UUID) throws
```

### `conversations()` — algorithm

1. Fetch all `ChatMessage` rows sorted by `createdAt` asc (`FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.createdAt)])`).
2. Group by `conversationId` in-memory. SwiftData `#Predicate` doesn't support `GROUP BY`; in-memory grouping is O(n) in messages, and message counts are sub-10k over the app's lifetime. Acceptable.
3. For each group:
   - `id = conversationId`
   - `title = firstNonEmptyUserMessage(messages).text` or `"New conversation"`
     - "Non-empty user message" = `role == .user && !text.isEmpty`. The empty-text user rows that `CoachService` writes (Anthropic tool-result protocol) are explicitly skipped.
   - `lastMessageAt = messages.last!.createdAt` (group is non-empty by construction, but defensively use `messages.last?.createdAt ?? Date()`)
   - `messageCount = messages.filter { !($0.role == .user && $0.text.isEmpty) }.count`
   - `isCurrent = (conversationId == currentConversationId())`
4. Filter out groups where `messageCount == 0`.
5. Sort the resulting array by `lastMessageAt` descending.

### `switchConversation(to:)` — algorithm

Set `cachedConversationId = id`. Don't validate existence; if `id` doesn't correspond to stored messages, the next `messages(in:)` returns `[]` and CoachView shows a blank composer. Recoverable by the user reopening the history list.

### `deleteConversation(id:)` — algorithm

1. Fetch `ChatMessage` rows where `conversationId == id`.
2. `context.delete(row)` for each.
3. `try context.save()`.
4. If `id == cachedConversationId`, mint a new `UUID` as the new `cachedConversationId` (same logic as `archiveCurrentConversation()`).

No notification side effects (chats don't touch workout-scheduled notifications). No cascade beyond the in-memory delete (`ChatMessage` has no relationships).

## View model

### `ChatHistoryViewModel` (new)

```swift
@MainActor
public final class ChatHistoryViewModel: ObservableObject {
    @Published public private(set) var conversations: [ConversationSummary] = []

    private let env: AppEnvironment
    public init(env: AppEnvironment) { self.env = env }

    public func refresh() {
        conversations = (try? env.chats.conversations()) ?? []
    }

    public func delete(id: UUID) {
        try? env.chats.deleteConversation(id: id)
        refresh()
    }

    public func switchTo(id: UUID) {
        env.chats.switchConversation(to: id)
        // No refresh — the calling view dismisses, and CoachView's .onAppear
        // re-reads currentConversationId() through CoachViewModel.refresh().
    }
}
```

Cheap `init` (no repo calls), `refresh()` called from `.onAppear` and `.refreshable`. Convention matches `PlansListViewModel`, `TodayViewModel`.

Error handling in `delete(id:)` swallows errors silently because the destructive-confirmation alert is the user's gate; a true SwiftData write failure is rare. If the row reappears on next refresh, that's the visible failure mode. If we want explicit error UX later, add a `lastError: String?` field surfaced via `.alert` — deferred for v1.

### `CoachViewModel` (no changes)

The existing `refresh()` already calls `env.chats.currentConversationId()` and fetches messages for it. When `ChatHistoryView` dismisses after `switchTo(id:)`, `CoachView.onAppear` fires its existing `vm.refresh()`, which re-reads the (now different) current id and re-loads. The existing `vm.newChat()` (= `env.chats.archiveCurrentConversation()` + `refresh`) keeps its semantics. If the user is viewing an old conversation and taps NEW CHAT, they land on a fresh blank conversation; the old conversation stays in the history list intact.

## View

### `CoachView` modifications

Wrap the existing content in a `NavigationStack(path: $path)` with a typed `CoachRoute`:

```swift
public enum CoachRoute: Hashable {
    case history
}

public struct CoachView: View {
    @StateObject private var vm: CoachViewModel
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var nav: AppNavigation
    @State private var path = NavigationPath()

    // existing init…

    public var body: some View {
        NavigationStack(path: $path) {
            existingContentWithMessagesScrollAndComposer
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { path.append(CoachRoute.history) } label: {
                            Text("HISTORY")
                                .font(BDStyle.monoTiny)
                                .tracking(BDStyle.trackingWide)
                                .foregroundStyle(.primary)
                        }
                        .disabled(vm.state == .streaming)
                        .accessibilityLabel("Chat history")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        // existing NEW CHAT button, unchanged
                    }
                }
                .navigationDestination(for: CoachRoute.self) { route in
                    switch route {
                    case .history:
                        ChatHistoryView(env: env)
                    }
                }
                // existing modifiers (background, navigationTitle, animation, onAppear)
        }
    }
}
```

**Disabled vs hidden** during streaming: disabled. Keeps toolbar layout stable; `.disabled(true)` greys the label visibly so the user knows what's going on.

### `ChatHistoryView` (new, at `Views/Coach/ChatHistoryView.swift`)

```swift
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
        .refreshable { vm.refresh() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pageHeader
                ForEach(Array(vm.conversations.enumerated()), id: \.element.id) { idx, c in
                    if idx > 0 { BDHairline() }
                    row(c)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = c
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                Color.clear.frame(height: 8)
            }
        }
        .scrollIndicators(.hidden)
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
```

Editorial vertical list. Each row left-aligns a 2pt accent strip on the leading edge if the conversation is the current one — otherwise an invisible-but-spaced 2pt clear rectangle keeps the title baseline aligned across rows. Title is `Text` with `.lineLimit(1)`; `BDStyle.monoTiny` + `trackingWide` is consistent with the rest of the editorial-athletic style. Standard iOS `.swipeActions(edge: .trailing, allowsFullSwipe: false)` exposes Delete; a full swipe doesn't accidentally delete. The destructive alert lives at the view level keyed by `pendingDelete: ConversationSummary?`.

`accessibilityIdentifier("chat.row.\(uuid)")` on each row Button is the UI-test reach.

## Navigation

A single push (`CoachRoute.history`) from `CoachView` into `ChatHistoryView`. Tap a row → `switchTo(id:)` + `dismiss()` → pop, `CoachView.onAppear` → `vm.refresh()` → conversation has switched. Delete via swipe → confirm → row gone, list stays mounted.

`NavigationPath` is `@State` on `CoachView`. Resetting on tab-switch isn't necessary — the NavigationStack handles that natively.

## Behavior / edge cases

**Streaming and navigation**

`HISTORY` is `.disabled(vm.state == .streaming)`. The button's label is greyed; tapping does nothing. Disabled (not hidden) avoids toolbar layout shift. The same convention as the existing disabled send-button during stream.

**Deleting the current conversation**

User swipes a row → confirms in alert → `vm.delete(id:)` calls `env.chats.deleteConversation(id:)`. The repo deletes the messages, saves, and (since the id matched the cached current) mints a fresh `UUID` for `cachedConversationId`. The user stays on the list. The deleted row is gone. The freshly minted conversation has zero messages — filtered out of `conversations()` — so it doesn't appear in the list at all. When the user pops back to `CoachView` (via the nav-bar back button), `vm.refresh()` reads the new current id, fetches zero messages, and renders the blank "talk to your coach" composer. Same end-state as `NEW CHAT`.

**Tapping the current row in the list**

`switchTo(id:)` is effectively a no-op when `id == cachedConversationId`. The view still dismisses. The user is back on `CoachView` viewing the same conversation. No flash.

**Title and timestamp computation**

- `ConversationSummary.title` is the full first-non-empty-user-message string. Visual truncation happens in `Text(.lineLimit(1))`.
- Relative timestamp uses `Date.RelativeFormatStyle(.relative(presentation: .named, unitsStyle: .abbreviated))`. Renders as `"12 min ago"` / `"Yesterday"` / `"Jun 1"` depending on age. iOS handles locale and bucketing. We don't define our own thresholds.

**CloudKit synchronization**

- `ChatMessage` already syncs.
- Pull-to-refresh on the history list (`.refreshable`) triggers `vm.refresh()`, which re-fetches from the local store (CloudKit's mirror).
- **Cross-device deletion race:** if device A deletes a conversation while device B is viewing it as the current chat, device B's `cachedConversationId` still points to the now-empty conversation. `messages(in:)` returns `[]`; device B sees a blank chat. The user recovers by tapping HISTORY and picking another conversation. We don't add a "this chat was removed elsewhere" notice in v1 — failure mode is recoverable and rare.
- **Concurrent writes** to the same conversationId from two devices: existing behavior. Last-writer-wins per row; `createdAt` ordering produces a readable transcript. Unchanged.

**Empty list state**

Renders the editorial empty state shown in the View section. In practice the list is empty only on a fresh install where no message has ever been sent.

**Tap a row mid-stream — impossible**

`HISTORY` is disabled during streaming, so this case cannot occur from the UI.

**Out of scope (deferred)**

- Search.
- Pinning / starring / archiving.
- Badging / unread indicators.
- LLM-generated titles.
- In-chat delete affordance.
- Conversation export or share.
- Multi-select for bulk-delete.
- "Removed on another device" notice.

## Migration

None. The new field set is computed from existing `ChatMessage` rows. Existing conversations on any user's device appear in the list immediately on first launch of the updated app.

CloudKit schema is unchanged.

## Testing

### Unit tests (XCTest, in-memory `ModelContainer.beardownInMemory()`)

**`ChatRepositoryTests` — extend existing:**

- `test_conversations_returnsEmptyWhenNoMessages`
- `test_conversations_groupsByConversationId_sortedByLastMessageDesc`
- `test_conversations_filtersOutEmptyConversations` — one with only protocol rows, one with only an empty user message
- `test_conversations_titleIsFirstNonEmptyUserMessage`
- `test_conversations_titleFallsBackToNewConversationWhenNoUserText` — assistant-only group
- `test_conversations_messageCountExcludesProtocolRows`
- `test_conversations_isCurrentFlagsTheCurrentConversation`
- `test_switchConversation_changesCurrentConversationId`
- `test_switchConversation_unknownId_isNoOp`
- `test_deleteConversation_removesAllItsMessages`
- `test_deleteConversation_otherConversationsUntouched`
- `test_deleteConversation_currentMintsAFreshOne`
- `test_deleteConversation_unknownId_isNoOp`

**`ChatHistoryViewModelTests` — new file:**

- `test_refresh_populatesConversationsFromRepo`
- `test_delete_callsRepoAndRefreshes` — verify the row disappears from `vm.conversations` after `delete`
- `test_switchTo_changesRepoCurrentId_withoutRefreshingThisVM` — confirm the VM doesn't redundantly refresh; CoachView is responsible

**`CoachViewModelTests` — extend existing (integration check):**

- `test_refresh_afterSwitchConversation_loadsTheSwitchedConversation` — seed two conversations, call `env.chats.switchConversation(to: B)`, call `coachVM.refresh()`, assert `messages` matches B's content

### UI test (XCUITest, `ChatHistoryUITests`)

Single end-to-end happy path:

1. `--ui-test-seed-chat-history` launch arg pre-seeds two completed conversations + one current empty one.
2. Onboard, tap Coach tab.
3. Tap `HISTORY` → assert both rows are present (the current empty conversation is filtered out, so exactly 2 rows).
4. Tap row B → return to `CoachView`, assert its content matches B.
5. Tap `HISTORY` again → swipe row A's trailing edge → tap Delete → confirm in alert.
6. Assert row A is gone (only B remains).

UI tests are flaky on this project (Mach -308). Allow one retry. The `chat.row.<UUID>` accessibility identifier on each Button is the test's reach.

### Manual test addendum

Append to `docs/manual-tests.md`:

1. Send a few messages, tap NEW CHAT, send a few more. Tap HISTORY → both conversations appear, the second on top.
2. Tap the first → returns to its content. Tap HISTORY → first row is unchanged (lastMessageAt didn't change just from switching).
3. Swipe-delete a chat → destructive alert → confirm → row gone, list intact.
4. Delete the current chat → row gone, the freshly-minted current is filtered out → list shows the remaining conversations.
5. CloudKit cross-device: send messages on device B, pull-to-refresh device A's HISTORY list → new conversation appears.
6. Streaming: send a message that triggers a long reply; verify the HISTORY toolbar button is greyed out and untappable while streaming. After stream completes, it re-enables.

## Files affected

**New:**

- `BearDown/BearDown/ViewModels/ChatHistoryViewModel.swift`
- `BearDown/BearDown/Views/Coach/ChatHistoryView.swift`
- `BearDown/BearDownTests/ChatHistoryViewModelTests.swift`
- `BearDown/BearDownUITests/ChatHistoryUITests.swift`

**Modified:**

- `BearDown/BearDown/Persistence/ChatRepository.swift` — add `ConversationSummary` value type, `conversations()`, `switchConversation(to:)`, `deleteConversation(id:)`
- `BearDown/BearDownTests/ChatRepositoryTests.swift` — extend with the 13 new tests
- `BearDown/BearDown/Views/Coach/CoachView.swift` — wrap content in `NavigationStack(path:)` with typed `CoachRoute.history`; add HISTORY leading-toolbar button (disabled while streaming); add `.navigationDestination(for: CoachRoute.self)` pushing `ChatHistoryView(env: env)`
- `BearDown/BearDownTests/CoachViewModelTests.swift` — extend with the conversation-switch integration test
- `BearDown/BearDown/BearDownApp.swift` — add `--ui-test-seed-chat-history` launch-arg branch (alongside the existing `--ui-test-seed-week` / `--ui-test-seed-two-plans` branches)
- `docs/manual-tests.md` — append Chat History section
- `CLAUDE.md` — update "Where to look first" table with a row for chat-history navigation; architecture pointer noting conversations are virtual groupings of `ChatMessage` (no `Conversation` model in v1)

**Deleted:** None.

## Implementation commit shape

The work decomposes naturally into seven commits:

1. `feat(chat): add ConversationSummary + ChatRepository.conversations()`
2. `feat(chat): add ChatRepository.switchConversation(to:) and deleteConversation(id:)`
3. `feat(chat): add ChatHistoryViewModel`
4. `feat(chat): add ChatHistoryView with row + swipe-delete`
5. `feat(coach): add HISTORY toolbar button + navigation to history view`
6. `test(ui): chat history switch + delete flow`
7. `docs: chat-history additions to CLAUDE.md + manual tests`

Each commit ships with its tests where applicable.
