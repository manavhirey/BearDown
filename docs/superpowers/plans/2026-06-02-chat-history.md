# Chat History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the coach's past conversations browsable from the Coach tab — list conversations grouped from existing `ChatMessage.conversationId`, jump back into any of them, and delete unwanted history with destructive confirmation.

**Architecture:** Bottom-up, additive only. `ChatRepository` grows three methods (`conversations()`, `switchConversation(to:)`, `deleteConversation(id:)`) returning a new `ConversationSummary` value type declared in the same file (precedent: `HistoryEntry`). A new `ChatHistoryViewModel` is the thin VM layer. A new `ChatHistoryView` renders the list with swipe-to-delete. `CoachView` is wrapped in a `NavigationStack(path:)` with a typed `CoachRoute.history` destination and gains a HISTORY toolbar button on `topBarLeading`. No SwiftData schema change, no CloudKit schema rev, no migration.

**Tech Stack:** Swift 5, SwiftUI, SwiftData (CloudKit), XCTest, XCUITest. iOS 17+.

**Source-of-truth spec:** `docs/superpowers/specs/2026-06-02-chat-history-design.md` (commit `5642176`). When in doubt, defer to the spec.

**Working tree at plan-write time:** branch `feat/initial-implementation` at commit `5642176` (one commit ahead of the multi-plan-design doc commit `1e26cce`). The working tree has uncommitted edits unrelated to this feature (Today/Week refactor in progress); do not touch them while implementing this plan.

**Conventions across all tasks:**
- All paths in commands are from the repo root `/Users/MAC/Documents/Code/BearDown`.
- Build/test from the repo root using absolute paths — **do not `cd BearDown`**. The CLAUDE.md project notes explain why.
- Simulator destination: `'platform=iOS Simulator,name=iPhone 17 Pro'` (not iPhone 15 Pro).
- After every task, run the full unit-test suite: `xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:BearDownTests -quiet`. The plan steps below show the per-task local check; the full suite confirms no regression.
- Trust `xcodebuild` exit codes, not SourceKit live diagnostics (often stale).
- Xcode 16 file-system synchronized groups: dropping a `.swift` file into `BearDown/BearDown/...` (app target) or `BearDown/BearDownTests/...` (unit-test target) or `BearDown/BearDownUITests/...` (UI-test target) auto-adds it to the corresponding target. No `.pbxproj` editing.
- View models construct cheap (no repo calls in `init`); `refresh()` happens in the owning view's `.onAppear`. Never call `refresh()` from a VM's `init` (CLAUDE.md gotcha #10).
- Don't override `objectWillChange` — CLAUDE.md gotcha #1.
- Use `ModelContainer.beardownInMemory()` for tests — already sets `cloudKitDatabase: .none`.
- Repositories are the only layer that touches `ModelContext`. Don't `@Query` from views.
- Commit-message style: lower-case scoped Conventional Commits (e.g. `feat(chat): …`, `test(ui): …`, `docs: …`). End every commit body with the trailer `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Don't push to remote during plan execution.

---

## Task 1: `ConversationSummary` value type + `ChatRepository.conversations()`

Add the `ConversationSummary` struct (alongside `ChatRepository`, in the same file — same pattern as `HistoryEntry` precedent the project follows for repo-adjacent value types) and the `conversations()` fetch method. Grouping is done in-memory because SwiftData `#Predicate` doesn't support `GROUP BY`.

**Files:**
- Modify: `BearDown/BearDown/Persistence/ChatRepository.swift`
- Modify: `BearDown/BearDownTests/ChatRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append the following tests to `BearDown/BearDownTests/ChatRepositoryTests.swift` (inside the existing `final class ChatRepositoryTests: XCTestCase` body, after the existing `test_messagesInConversation_areOrderedByCreatedAt` method):

```swift
// MARK: - conversations()

func test_conversations_returnsEmptyWhenNoMessages() throws {
    let summaries = try repo.conversations()
    XCTAssertEqual(summaries, [])
}

func test_conversations_groupsByConversationId_sortedByLastMessageDesc() throws {
    // Conversation A: oldest
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .assistant, text: "A2", toolCallsJSON: nil, toolResultsJSON: nil)
    // Archive -> new id minted on next currentConversationId()
    repo.archiveCurrentConversation()
    let b = repo.currentConversationId()
    try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)

    let summaries = try repo.conversations()
    XCTAssertEqual(summaries.count, 2)
    XCTAssertEqual(summaries[0].id, b, "most-recent conversation should be first")
    XCTAssertEqual(summaries[1].id, a)
}

func test_conversations_filtersOutEmptyConversations() throws {
    // Conversation X: only a protocol row (role=.user, text="")
    let x = repo.currentConversationId()
    try repo.append(role: .user, text: "", toolCallsJSON: nil, toolResultsJSON: nil)
    repo.archiveCurrentConversation()
    // Conversation Y: a real user message
    _ = repo.currentConversationId()
    try repo.append(role: .user, text: "hello", toolCallsJSON: nil, toolResultsJSON: nil)

    let summaries = try repo.conversations()
    XCTAssertEqual(summaries.count, 1)
    XCTAssertNotEqual(summaries[0].id, x, "empty conversation should be filtered out")
}

func test_conversations_titleIsFirstNonEmptyUserMessage() throws {
    _ = repo.currentConversationId()
    try repo.append(role: .user, text: "", toolCallsJSON: nil, toolResultsJSON: nil)         // skipped
    try repo.append(role: .user, text: "first real", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .assistant, text: "reply", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .user, text: "second real", toolCallsJSON: nil, toolResultsJSON: nil)

    let summaries = try repo.conversations()
    XCTAssertEqual(summaries.count, 1)
    XCTAssertEqual(summaries[0].title, "first real")
}

func test_conversations_titleFallsBackToNewConversationWhenNoUserText() throws {
    _ = repo.currentConversationId()
    try repo.append(role: .assistant, text: "hi there", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .assistant, text: "still here", toolCallsJSON: nil, toolResultsJSON: nil)

    let summaries = try repo.conversations()
    XCTAssertEqual(summaries.count, 1)
    XCTAssertEqual(summaries[0].title, "New conversation")
}

func test_conversations_messageCountExcludesProtocolRows() throws {
    _ = repo.currentConversationId()
    try repo.append(role: .user, text: "q1", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .assistant, text: "a1", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .user, text: "", toolCallsJSON: nil, toolResultsJSON: nil) // protocol row
    try repo.append(role: .assistant, text: "a2", toolCallsJSON: nil, toolResultsJSON: nil)

    let summaries = try repo.conversations()
    XCTAssertEqual(summaries.count, 1)
    XCTAssertEqual(summaries[0].messageCount, 3, "excludes the empty-text user (protocol) row")
}

func test_conversations_isCurrentFlagsTheCurrentConversation() throws {
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
    repo.archiveCurrentConversation()
    let b = repo.currentConversationId()
    try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)

    let summaries = try repo.conversations()
    let summaryA = summaries.first(where: { $0.id == a })!
    let summaryB = summaries.first(where: { $0.id == b })!
    XCTAssertTrue(summaryB.isCurrent)
    XCTAssertFalse(summaryA.isCurrent)
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ChatRepositoryTests -quiet
```

Expected: compile error — `Value of type 'ChatRepository' has no member 'conversations'` and `Cannot find 'ConversationSummary' in scope`.

- [ ] **Step 3: Add `ConversationSummary` and `conversations()`**

Replace the contents of `BearDown/BearDown/Persistence/ChatRepository.swift` with:

```swift
import Foundation
import SwiftData

/// Aggregated view of a single conversation derived from `ChatMessage` rows.
/// Declared alongside `ChatRepository` because it's strictly a repo-shaped value type
/// (same precedent as `HistoryEntry` in this codebase).
public struct ConversationSummary: Identifiable, Equatable, Sendable {
    public let id: UUID                  // the conversationId
    public let title: String             // first non-empty user message, OR "New conversation"
    public let lastMessageAt: Date
    public let messageCount: Int         // excludes role=.user/text="" protocol rows
    public let isCurrent: Bool

    public init(id: UUID,
                title: String,
                lastMessageAt: Date,
                messageCount: Int,
                isCurrent: Bool) {
        self.id = id
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.isCurrent = isCurrent
    }
}

@MainActor
public final class ChatRepository {
    private let context: ModelContext
    private var cachedConversationId: UUID?

    public init(context: ModelContext) {
        self.context = context
    }

    public func currentConversationId() -> UUID {
        if let id = cachedConversationId { return id }
        // Pick the conversation id of the most recent message, else mint a new one.
        var d = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        d.fetchLimit = 1
        if let latest = try? context.fetch(d).first {
            cachedConversationId = latest.conversationId
        } else {
            cachedConversationId = UUID()
        }
        return cachedConversationId!
    }

    public func archiveCurrentConversation() {
        cachedConversationId = UUID()
    }

    public func append(role: ChatRole, text: String,
                       toolCallsJSON: String?, toolResultsJSON: String?) throws {
        let cid = currentConversationId()
        let m = ChatMessage(role: role, text: text, conversationId: cid)
        m.toolCallsJSON = toolCallsJSON
        m.toolResultsJSON = toolResultsJSON
        context.insert(m)
        try context.save()
    }

    public func messages(in conversationId: UUID) throws -> [ChatMessage] {
        try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.conversationId == conversationId },
            sortBy: [SortDescriptor(\.createdAt)]
        ))
    }

    /// All conversations as summaries, sorted by `lastMessageAt` descending.
    /// Empty conversations (`messageCount == 0` after filtering protocol rows) are excluded.
    public func conversations() throws -> [ConversationSummary] {
        // SwiftData #Predicate doesn't support GROUP BY; we fetch sorted and group in-memory.
        // n is bounded (<10k over app lifetime) so the O(n) pass is fine.
        let all = try context.fetch(FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))
        let currentId = currentConversationId()

        var orderedIds: [UUID] = []
        var groups: [UUID: [ChatMessage]] = [:]
        for m in all {
            if groups[m.conversationId] == nil {
                groups[m.conversationId] = []
                orderedIds.append(m.conversationId)
            }
            groups[m.conversationId]!.append(m)
        }

        var summaries: [ConversationSummary] = []
        for cid in orderedIds {
            let msgs = groups[cid]!
            let visible = msgs.filter { !($0.role == .user && $0.text.isEmpty) }
            let count = visible.count
            if count == 0 { continue } // empty / protocol-only conversation
            let title = msgs.first(where: { $0.role == .user && !$0.text.isEmpty })?.text
                ?? "New conversation"
            let lastAt = msgs.last?.createdAt ?? Date()
            summaries.append(ConversationSummary(
                id: cid,
                title: title,
                lastMessageAt: lastAt,
                messageCount: count,
                isCurrent: cid == currentId
            ))
        }
        return summaries.sorted { $0.lastMessageAt > $1.lastMessageAt }
    }
}
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ChatRepositoryTests -quiet
```

Expected: all `ChatRepositoryTests` pass (existing 4 + 7 new = 11).

Then run the full unit-test suite to confirm no regression:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/MAC/Documents/Code/BearDown add \
  BearDown/BearDown/Persistence/ChatRepository.swift \
  BearDown/BearDownTests/ChatRepositoryTests.swift
git -C /Users/MAC/Documents/Code/BearDown commit -m "$(cat <<'EOF'
feat(chat): add ConversationSummary + ChatRepository.conversations()

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `ChatRepository.switchConversation(to:)` + `deleteConversation(id:)`

Add the two mutation methods. `switchConversation(to:)` is sync, non-throwing, and intentionally does not validate the id (CoachView's blank state is the visible "no messages found" recovery). `deleteConversation(id:)` removes all rows with that id and mints a fresh `cachedConversationId` if the deleted id was the current one.

**Files:**
- Modify: `BearDown/BearDown/Persistence/ChatRepository.swift`
- Modify: `BearDown/BearDownTests/ChatRepositoryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `BearDown/BearDownTests/ChatRepositoryTests.swift` (after the tests added in Task 1):

```swift
// MARK: - switchConversation(to:)

func test_switchConversation_changesCurrentConversationId() throws {
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
    repo.archiveCurrentConversation()
    let b = repo.currentConversationId()
    try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)
    XCTAssertEqual(repo.currentConversationId(), b)

    repo.switchConversation(to: a)
    XCTAssertEqual(repo.currentConversationId(), a)
}

func test_switchConversation_unknownId_isNoOp() throws {
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
    let bogus = UUID()
    repo.switchConversation(to: bogus)
    // Per spec: the call just sets cachedConversationId. messages(in:) returns []
    // for the unknown id; user recovers via the history list.
    XCTAssertEqual(repo.currentConversationId(), bogus)
    XCTAssertEqual(try repo.messages(in: bogus), [])
    // Pre-existing messages for `a` still resolvable explicitly:
    XCTAssertEqual(try repo.messages(in: a).count, 1)
}

// MARK: - deleteConversation(id:)

func test_deleteConversation_removesAllItsMessages() throws {
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .assistant, text: "A2", toolCallsJSON: nil, toolResultsJSON: nil)

    try repo.deleteConversation(id: a)
    XCTAssertEqual(try repo.messages(in: a), [])
}

func test_deleteConversation_otherConversationsUntouched() throws {
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
    repo.archiveCurrentConversation()
    let b = repo.currentConversationId()
    try repo.append(role: .user, text: "B1", toolCallsJSON: nil, toolResultsJSON: nil)
    try repo.append(role: .assistant, text: "B2", toolCallsJSON: nil, toolResultsJSON: nil)

    try repo.deleteConversation(id: a)
    XCTAssertEqual(try repo.messages(in: a), [])
    XCTAssertEqual(try repo.messages(in: b).count, 2)
}

func test_deleteConversation_currentMintsAFreshOne() throws {
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)
    XCTAssertEqual(repo.currentConversationId(), a)

    try repo.deleteConversation(id: a)

    let fresh = repo.currentConversationId()
    XCTAssertNotEqual(fresh, a, "deleting the current conversation should mint a new id")
    XCTAssertEqual(try repo.messages(in: fresh), [],
                   "freshly minted current conversation has no messages")
}

func test_deleteConversation_unknownId_isNoOp() throws {
    let a = repo.currentConversationId()
    try repo.append(role: .user, text: "A1", toolCallsJSON: nil, toolResultsJSON: nil)

    let bogus = UUID()
    XCTAssertNoThrow(try repo.deleteConversation(id: bogus))
    XCTAssertEqual(try repo.messages(in: a).count, 1, "untouched")
    XCTAssertEqual(repo.currentConversationId(), a, "current id unchanged")
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ChatRepositoryTests -quiet
```

Expected: compile error — `Value of type 'ChatRepository' has no member 'switchConversation'` and `… 'deleteConversation'`.

- [ ] **Step 3: Implement the two methods**

Append the following two methods inside the `ChatRepository` class in `BearDown/BearDown/Persistence/ChatRepository.swift`, directly after `conversations()`:

```swift
    /// Switch the active conversation. No-op semantics if `id` doesn't correspond to
    /// any stored messages — `messages(in:)` will return `[]` and CoachView will render
    /// the blank composer; the user recovers via the history list.
    public func switchConversation(to id: UUID) {
        cachedConversationId = id
    }

    /// Delete all messages with this `conversationId`. If `id` was the cached current,
    /// mints a fresh `UUID` for the new current (same end-state as
    /// `archiveCurrentConversation()`).
    public func deleteConversation(id: UUID) throws {
        let rows = try context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.conversationId == id }
        ))
        for row in rows {
            context.delete(row)
        }
        try context.save()
        if cachedConversationId == id {
            cachedConversationId = UUID()
        }
    }
```

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ChatRepositoryTests -quiet
```

Expected: all `ChatRepositoryTests` pass (now 17 total — 4 original + 13 new).

Then run the full unit-test suite:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/MAC/Documents/Code/BearDown add \
  BearDown/BearDown/Persistence/ChatRepository.swift \
  BearDown/BearDownTests/ChatRepositoryTests.swift
git -C /Users/MAC/Documents/Code/BearDown commit -m "$(cat <<'EOF'
feat(chat): add ChatRepository.switchConversation(to:) and deleteConversation(id:)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `ChatHistoryViewModel`

Thin VM around `ChatRepository`'s three new methods. Cheap `init` (no repo calls), `refresh()` called from the owning view's `.onAppear`/`.refreshable`. `delete(id:)` calls the repo and refreshes; `switchTo(id:)` is fire-and-forget (no self-refresh — the caller dismisses and `CoachView.onAppear` re-reads through `CoachViewModel.refresh()`).

Also adds an integration test in `CoachViewModelTests` confirming the conversation-switch round-trip.

**Files:**
- Create: `BearDown/BearDown/ViewModels/ChatHistoryViewModel.swift`
- Create: `BearDown/BearDownTests/ChatHistoryViewModelTests.swift`
- Modify: `BearDown/BearDownTests/CoachViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create a new file `BearDown/BearDownTests/ChatHistoryViewModelTests.swift`:

```swift
import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class ChatHistoryViewModelTests: XCTestCase {
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.chathistoryvm.\(UUID().uuidString)"),
            anthropic: ScriptedAnthropicClient()
        )
    }

    func test_refresh_populatesConversationsFromRepo() throws {
        // Two conversations, both with a real user message.
        let a = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "first", toolCallsJSON: nil, toolResultsJSON: nil)
        env.chats.archiveCurrentConversation()
        let b = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "second", toolCallsJSON: nil, toolResultsJSON: nil)

        let vm = ChatHistoryViewModel(env: env)
        XCTAssertTrue(vm.conversations.isEmpty, "cheap init does not load")
        vm.refresh()
        XCTAssertEqual(vm.conversations.count, 2)
        XCTAssertEqual(vm.conversations[0].id, b, "most-recent first")
        XCTAssertEqual(vm.conversations[1].id, a)
    }

    func test_delete_callsRepoAndRefreshes() throws {
        let a = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "doomed", toolCallsJSON: nil, toolResultsJSON: nil)
        env.chats.archiveCurrentConversation()
        _ = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "kept", toolCallsJSON: nil, toolResultsJSON: nil)

        let vm = ChatHistoryViewModel(env: env)
        vm.refresh()
        XCTAssertEqual(vm.conversations.count, 2)

        vm.delete(id: a)
        XCTAssertEqual(vm.conversations.count, 1)
        XCTAssertFalse(vm.conversations.contains(where: { $0.id == a }))
    }

    func test_switchTo_changesRepoCurrentId_withoutRefreshingThisVM() throws {
        let a = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "A", toolCallsJSON: nil, toolResultsJSON: nil)
        env.chats.archiveCurrentConversation()
        let b = env.chats.currentConversationId()
        try env.chats.append(role: .user, text: "B", toolCallsJSON: nil, toolResultsJSON: nil)

        let vm = ChatHistoryViewModel(env: env)
        vm.refresh()
        // Sanity: B is the current conversation before the switch.
        XCTAssertTrue(vm.conversations.first(where: { $0.id == b })!.isCurrent)
        XCTAssertFalse(vm.conversations.first(where: { $0.id == a })!.isCurrent)

        vm.switchTo(id: a)

        // Repo state has changed:
        XCTAssertEqual(env.chats.currentConversationId(), a)
        // But vm.conversations is intentionally stale — the caller dismisses, CoachView
        // re-reads via its own onAppear → CoachViewModel.refresh().
        XCTAssertTrue(vm.conversations.first(where: { $0.id == b })!.isCurrent,
                      "vm should NOT have auto-refreshed isCurrent flags")
    }
}
```

And append the following integration test to `BearDown/BearDownTests/CoachViewModelTests.swift` (inside the existing `final class CoachViewModelTests: XCTestCase` body, after `test_computeChips_dedupsMultipleWorkoutsToOneSwitchChipPerPlan`):

```swift
func test_refresh_afterSwitchConversation_loadsTheSwitchedConversation() throws {
    // Seed two conversations directly through env.chats.
    let a = env.chats.currentConversationId()
    try env.chats.append(role: .user, text: "from A", toolCallsJSON: nil, toolResultsJSON: nil)
    try env.chats.append(role: .assistant, text: "reply A", toolCallsJSON: nil, toolResultsJSON: nil)
    env.chats.archiveCurrentConversation()
    let b = env.chats.currentConversationId()
    try env.chats.append(role: .user, text: "from B", toolCallsJSON: nil, toolResultsJSON: nil)
    try env.chats.append(role: .assistant, text: "reply B", toolCallsJSON: nil, toolResultsJSON: nil)

    let vm = CoachViewModel(env: env)
    vm.refresh()
    XCTAssertEqual(vm.messages.map(\.text), ["from B", "reply B"])

    // Simulate the user picking conversation A in the history view.
    env.chats.switchConversation(to: a)
    vm.refresh()
    XCTAssertEqual(vm.messages.map(\.text), ["from A", "reply A"])
    XCTAssertNotEqual(a, b)
}
```

- [ ] **Step 2: Run the tests, expect failure**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ChatHistoryViewModelTests -quiet
```

Expected: compile error — `Cannot find 'ChatHistoryViewModel' in scope`.

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests/test_refresh_afterSwitchConversation_loadsTheSwitchedConversation -quiet
```

Expected: compile or runtime failure (the integration test compiles, but `switchConversation` only exists after Task 2 — assumed present here since Task 2 already shipped. If Task 2 is missing, this test fails to compile with `no member 'switchConversation'`).

- [ ] **Step 3: Add `ChatHistoryViewModel`**

Create `BearDown/BearDown/ViewModels/ChatHistoryViewModel.swift`:

```swift
import Combine
import Foundation

@MainActor
public final class ChatHistoryViewModel: ObservableObject {
    @Published public private(set) var conversations: [ConversationSummary] = []

    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
        // Cheap init — no repo calls. The owning view's .onAppear triggers refresh().
    }

    public func refresh() {
        conversations = (try? env.chats.conversations()) ?? []
    }

    public func delete(id: UUID) {
        // Silent-swallow per spec: destructive alert is the user gate; a real SwiftData
        // write failure is rare and the row would reappear on next refresh as the
        // visible failure mode. If we later want explicit error UX, add a
        // `lastError: String?` field and surface via `.alert`.
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

- [ ] **Step 4: Run the tests, expect pass**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/ChatHistoryViewModelTests -quiet
```

Expected: all 3 `ChatHistoryViewModelTests` pass.

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests/CoachViewModelTests -quiet
```

Expected: all `CoachViewModelTests` pass (existing + the new integration test).

Then run the full unit-test suite:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/MAC/Documents/Code/BearDown add \
  BearDown/BearDown/ViewModels/ChatHistoryViewModel.swift \
  BearDown/BearDownTests/ChatHistoryViewModelTests.swift \
  BearDown/BearDownTests/CoachViewModelTests.swift
git -C /Users/MAC/Documents/Code/BearDown commit -m "$(cat <<'EOF'
feat(chat): add ChatHistoryViewModel

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `ChatHistoryView` — row, swipe-delete, empty state

Editorial vertical list. Each row is a Button with a 2pt leading accent for the current conversation; tapping calls `vm.switchTo(id:)` then `dismiss()`. Trailing swipe (`allowsFullSwipe: false`) reveals Delete which triggers an alert keyed by `pendingDelete: ConversationSummary?`. Empty state uses the same editorial vocabulary as `CoachView`.

This task is **build + smoke verification** (no unit test — pure SwiftUI; logic is covered by `ChatHistoryViewModelTests`).

**Files:**
- Create: `BearDown/BearDown/Views/Coach/ChatHistoryView.swift`

- [ ] **Step 1: Add the view**

Create `BearDown/BearDown/Views/Coach/ChatHistoryView.swift`:

```swift
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
        .refreshable { vm.refresh() }
    }

    // MARK: – List

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
```

- [ ] **Step 2: Build, expect success**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run the full unit-test suite (regression check)**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all tests pass. (The view isn't wired into `CoachView` yet — that's Task 5. Build succeeds because the view is reachable as a public type; nothing references it from the running app yet.)

- [ ] **Step 4: Smoke-verify the view compiles in a preview**

Optional: open `BearDown/BearDown.xcodeproj` in Xcode and confirm `ChatHistoryView.swift` resolves with no live errors. If SourceKit shows stale errors, trust the `xcodebuild` exit code from Step 2 (CLAUDE.md gotcha re: stale SourceKit diagnostics).

- [ ] **Step 5: Commit**

```bash
git -C /Users/MAC/Documents/Code/BearDown add \
  BearDown/BearDown/Views/Coach/ChatHistoryView.swift
git -C /Users/MAC/Documents/Code/BearDown commit -m "$(cat <<'EOF'
feat(chat): add ChatHistoryView with row + swipe-delete

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: HISTORY toolbar button + navigation to history view in `CoachView`

Wrap the existing `CoachView` body content in a `NavigationStack(path:)` driven by a typed `CoachRoute` enum, add the leading-toolbar HISTORY button (disabled while streaming), and register the `.navigationDestination(for: CoachRoute.self)` for `.history`. The existing trailing NEW CHAT button stays untouched.

This task is **build + smoke verification** (the wiring is integration-level; behavioral coverage lands in Task 6's UI test).

**Files:**
- Modify: `BearDown/BearDown/Views/Coach/CoachView.swift`

- [ ] **Step 1: Modify `CoachView`**

Replace the contents of `BearDown/BearDown/Views/Coach/CoachView.swift` with:

```swift
import SwiftUI

public enum CoachRoute: Hashable {
    case history
}

public struct CoachView: View {
    @StateObject private var vm: CoachViewModel
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var nav: AppNavigation
    @State private var path = NavigationPath()

    public init(env: AppEnvironment) {
        _vm = StateObject(wrappedValue: CoachViewModel(env: env))
    }

    public var body: some View {
        NavigationStack(path: $path) {
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        path.append(CoachRoute.history)
                    } label: {
                        Text("HISTORY")
                            .font(BDStyle.monoTiny)
                            .tracking(BDStyle.trackingWide)
                            .foregroundStyle(.primary)
                    }
                    .disabled(vm.state == .streaming)
                    .accessibilityLabel("Chat history")
                }
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
            .navigationDestination(for: CoachRoute.self) { route in
                switch route {
                case .history:
                    ChatHistoryView(env: env)
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
                                       if let planId = chip.planId {
                                           try? env.plans.activate(planId: planId)
                                           nav.selectedTab = 1
                                           nav.pendingPlanDetail = planId
                                       } else if let d = chip.workoutDate {
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
```

The behavioral diffs versus the prior file are:
1. New `public enum CoachRoute: Hashable { case history }` at file top.
2. New `@State private var path = NavigationPath()` field.
3. `NavigationStack { … }` → `NavigationStack(path: $path) { … }`.
4. New `ToolbarItem(placement: .topBarLeading)` for HISTORY, with `.disabled(vm.state == .streaming)`.
5. New `.navigationDestination(for: CoachRoute.self) { route in switch route { case .history: ChatHistoryView(env: env) } }` modifier.

Everything else (page header, messages scroll, error banner, composer, NEW CHAT trailing button) is byte-for-byte identical to the prior file.

- [ ] **Step 2: Build, expect success**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run the full unit-test suite (regression check)**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all tests pass.

- [ ] **Step 4: Smoke-verify in the simulator**

```bash
xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null || true
xcodebuild -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/beardown-dd build -quiet
xcrun simctl install booted /tmp/beardown-dd/Build/Products/Debug-iphonesimulator/BearDown.app
xcrun simctl launch booted Hirey.BearDown
```

Manually:
- Onboard (paste any string; the validator is real here — to bypass real network, you can pass `--ui-test-stub-validator` via `xcrun simctl launch ... --console-pty Hirey.BearDown --ui-test-stub-validator`, or just go through Settings).
- Tap Coach tab.
- Confirm a HISTORY button is visible on the top-left of the nav bar.
- Tap HISTORY → confirm the `ChatHistoryView` pushes (with "CHATS / History" page header) and shows either the empty state or the current conversation list.
- Tap the system back button → returns to Coach.
- Type a message and hit SEND → while streaming, confirm HISTORY is greyed/disabled and untappable; after the stream ends, it re-enables.

- [ ] **Step 5: Commit**

```bash
git -C /Users/MAC/Documents/Code/BearDown add \
  BearDown/BearDown/Views/Coach/CoachView.swift
git -C /Users/MAC/Documents/Code/BearDown commit -m "$(cat <<'EOF'
feat(coach): add HISTORY toolbar button + navigation to history view

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: UI test — chat history switch + delete flow

End-to-end XCUITest covering: open HISTORY → see seeded conversations → tap a row to switch → return to Coach with its content → swipe-delete a row with destructive confirmation. Adds a new `--ui-test-seed-chat-history` launch-argument branch to `BearDownApp.swift` that pre-seeds two complete conversations + one current empty conversation (so the filter-out behavior is exercised).

Note: spec records UI tests are flaky on this project (Mach error -308). The test uses generous `waitForExistence` timeouts; allow one manual retry if it fails the first time.

**Files:**
- Modify: `BearDown/BearDown/BearDownApp.swift`
- Create: `BearDown/BearDownUITests/ChatHistoryUITests.swift`

- [ ] **Step 1: Add the launch-arg seed branch and the UI test (write-then-verify is build+smoke for UI tests)**

Append a new `if` branch to the `init()` method of `BearDownApp` in `BearDown/BearDown/BearDownApp.swift`, directly after the `--ui-test-seed-two-plans` block (and before the closing `}` of `init`):

```swift
        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-chat-history") {
            Task { @MainActor in
                // Conversation A — older, ends earlier.
                let chats = environment.chats
                _ = chats.currentConversationId()
                try? chats.append(role: .user, text: "Plan my taper week",
                                  toolCallsJSON: nil, toolResultsJSON: nil)
                try? chats.append(role: .assistant, text: "Taper plan ready.",
                                  toolCallsJSON: nil, toolResultsJSON: nil)
                chats.archiveCurrentConversation()

                // Conversation B — newer.
                _ = chats.currentConversationId()
                try? chats.append(role: .user, text: "How heavy on Tuesday?",
                                  toolCallsJSON: nil, toolResultsJSON: nil)
                try? chats.append(role: .assistant, text: "Top sets at 80%.",
                                  toolCallsJSON: nil, toolResultsJSON: nil)
                chats.archiveCurrentConversation()

                // Current conversation: empty -> filtered out of the history list.
                _ = chats.currentConversationId()
            }
        }
```

Then create `BearDown/BearDownUITests/ChatHistoryUITests.swift`:

```swift
import XCTest

final class ChatHistoryUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func test_historyFlow_listSwitchDelete() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-stub-validator",
            "--reset-keychain",
            "--ui-test-seed-chat-history",
        ]
        app.launch()

        // Onboard.
        let key = app.secureTextFields.firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        key.tap(); key.typeText("sk-ant-uitest")
        app.buttons["Continue"].tap()

        // Coach tab.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["Coach"].tap()
        XCTAssertTrue(app.staticTexts["Today's session"].waitForExistence(timeout: 5))

        // Open HISTORY.
        let historyButton = app.buttons["Chat history"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 5))
        historyButton.tap()

        // The page header confirms we landed on the history view.
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))

        // Two rows exist (the current empty conversation is filtered out).
        // We don't know the row UUIDs up front, so match the row by its title text.
        let rowB = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "How heavy on Tuesday?")).firstMatch
        let rowA = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Plan my taper week")).firstMatch
        XCTAssertTrue(rowB.waitForExistence(timeout: 5))
        XCTAssertTrue(rowA.exists)

        // Tap row B -> back to Coach showing B's content.
        rowB.tap()
        XCTAssertTrue(app.staticTexts["Top sets at 80%."].waitForExistence(timeout: 5))

        // Re-open HISTORY, swipe row A, delete.
        historyButton.tap()
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
        let rowAAgain = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Plan my taper week")).firstMatch
        XCTAssertTrue(rowAAgain.waitForExistence(timeout: 5))
        rowAAgain.swipeLeft()

        // Tap the swipe-revealed Delete button.
        let deleteCell = app.buttons["Delete"]
        XCTAssertTrue(deleteCell.waitForExistence(timeout: 5))
        deleteCell.tap()

        // Destructive confirmation alert.
        let confirm = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Row A is gone; row B remains.
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@",
                                                         "Plan my taper week")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@",
                                                        "How heavy on Tuesday?")).firstMatch.exists)
    }
}
```

- [ ] **Step 2: Build, expect success**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run unit tests (regression check) and the new UI test**

Unit tests first:

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all tests pass.

Then the UI test (allow one retry per CLAUDE.md note re: Mach -308 flakiness):

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownUITests/ChatHistoryUITests -quiet
```

Expected: the test passes. If it fails with `Mach error -308 - server died`, re-run once. If it still fails, open Xcode and run `ChatHistoryUITests` via ⌘U; if it passes there, accept the flake and move on (the CLAUDE.md "UI test runner is flaky" note covers this).

- [ ] **Step 4: Smoke-verify the seed launch arg manually**

```bash
xcrun simctl boot 'iPhone 17 Pro' 2>/dev/null || true
xcodebuild -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/beardown-dd build -quiet
xcrun simctl install booted /tmp/beardown-dd/Build/Products/Debug-iphonesimulator/BearDown.app
xcrun simctl launch booted Hirey.BearDown --ui-test-stub-validator --reset-keychain --ui-test-seed-chat-history
```

Manually: onboard with any key, tap Coach, tap HISTORY — confirm exactly two rows ("Plan my taper week" and "How heavy on Tuesday?"); the empty current conversation does not appear.

- [ ] **Step 5: Commit**

```bash
git -C /Users/MAC/Documents/Code/BearDown add \
  BearDown/BearDown/BearDownApp.swift \
  BearDown/BearDownUITests/ChatHistoryUITests.swift
git -C /Users/MAC/Documents/Code/BearDown commit -m "$(cat <<'EOF'
test(ui): chat history switch + delete flow

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Docs — `CLAUDE.md` + `docs/manual-tests.md`

Two doc updates. (1) Add a manual-test section to `docs/manual-tests.md` mirroring the spec's testing-addendum section. (2) Update `CLAUDE.md`'s "Where to look first" table with a chat-history row, and add an architecture pointer near the existing repository description noting that conversations are virtual groupings (no `Conversation` model in v1).

This task is **doc only**: no build/test step beyond confirming the project still builds (which it must, since we touch only `.md` files).

**Files:**
- Modify: `docs/manual-tests.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Append the manual-test section**

Append the following to `docs/manual-tests.md` (after the existing "Multi-Plan" section):

```markdown

## Chat History

1. **List populates on Coach tab.** Send a few messages, tap NEW CHAT, send a few more. Tap HISTORY in the top-left of the Coach toolbar — both conversations appear, the most-recent on top. The current (empty) conversation is filtered out and does not appear.

2. **Tap a row to resume.** Tap the first row. The view dismisses back to Coach showing that conversation's messages. Tap HISTORY again — the first row's timestamp is unchanged (switching a conversation does not modify `lastMessageAt`).

3. **Swipe-delete a non-current chat.** Swipe a row's trailing edge to reveal Delete; tap it. A destructive alert ("Delete this chat? All messages will be removed.") appears. Confirm DELETE. The row is gone from the list; other conversations are untouched.

4. **Delete the current chat.** Resume an existing conversation, return to HISTORY, swipe-delete the row that has the 2pt leading accent (the current chat). After confirming, the row is gone; the freshly-minted current conversation is filtered out and does not appear in the list. Pop back to Coach: the composer is blank (same end-state as NEW CHAT).

5. **CloudKit cross-device sync.** On device B, send messages on a new conversation. On device A, open HISTORY and pull-to-refresh. The new conversation appears within ~10s.

6. **HISTORY is disabled during streaming.** Send a message that triggers a long agent reply. While the stream is in progress, confirm HISTORY's label is greyed and untappable. After the stream completes, HISTORY re-enables.
```

- [ ] **Step 2: Update `CLAUDE.md`**

In `CLAUDE.md`, find the "Where to look first" table (under the `## Where to look first` heading). Append a new row at the end of the table, just before the closing line of the table:

```markdown
| Add or change chat-history navigation | `BearDown/BearDown/Views/Coach/CoachView.swift` (HISTORY toolbar + `CoachRoute`) + `BearDown/BearDown/Views/Coach/ChatHistoryView.swift` + `BearDown/BearDown/Persistence/ChatRepository.swift` (`conversations()`, `switchConversation(to:)`, `deleteConversation(id:)`) |
```

Then, in the `## Architecture pointers` section, add a new bullet to the existing bullet list (anywhere is fine; the spec doesn't require a specific order). Insert this bullet right after the existing `Repositories are the only layer touching ModelContext.` bullet:

```markdown
- **Conversations are virtual groupings of `ChatMessage`.** There is no `Conversation` SwiftData model. `ChatRepository.conversations()` fetches all `ChatMessage` rows sorted by `createdAt` and groups in-memory by `conversationId` (SwiftData `#Predicate` does not support `GROUP BY`). Empty conversations (only Anthropic protocol rows: `role == .user && text.isEmpty`) are filtered out. The list is reactive — no schema change, no migration; new conversations appear on first launch of the updated app.
```

- [ ] **Step 3: Build (sanity check that nothing else changed)**

```bash
xcodebuild build -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full unit-test suite (final regression check)**

```bash
xcodebuild test -project BearDown/BearDown.xcodeproj -scheme BearDown \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:BearDownTests -quiet
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/MAC/Documents/Code/BearDown add \
  docs/manual-tests.md \
  CLAUDE.md
git -C /Users/MAC/Documents/Code/BearDown commit -m "$(cat <<'EOF'
docs: chat-history additions to CLAUDE.md + manual tests

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done criteria

After Task 7, the working tree should contain:

- **New files:** `BearDown/BearDown/ViewModels/ChatHistoryViewModel.swift`, `BearDown/BearDown/Views/Coach/ChatHistoryView.swift`, `BearDown/BearDownTests/ChatHistoryViewModelTests.swift`, `BearDown/BearDownUITests/ChatHistoryUITests.swift`.
- **Modified files:** `BearDown/BearDown/Persistence/ChatRepository.swift`, `BearDown/BearDownTests/ChatRepositoryTests.swift`, `BearDown/BearDown/Views/Coach/CoachView.swift`, `BearDown/BearDownTests/CoachViewModelTests.swift`, `BearDown/BearDown/BearDownApp.swift`, `docs/manual-tests.md`, `CLAUDE.md`.
- **No deletions.**
- **Seven commits**, one per task, each with the `Co-Authored-By` trailer.
- Full unit-test suite green; `ChatHistoryUITests` green (allowing one retry).
- Manual smoke per `docs/manual-tests.md` "Chat History" section completes without surprises on the simulator.

Do not push to remote at the end of this plan — branch promotion is a separate user-driven step.
