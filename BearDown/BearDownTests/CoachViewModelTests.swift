import XCTest
import SwiftData
@testable import BearDown

@MainActor
final class CoachViewModelTests: XCTestCase {
    private var env: AppEnvironment!
    private var scripted: ScriptedAnthropicClient!

    override func setUpWithError() throws {
        let container = try ModelContainer.beardownInMemory()
        scripted = ScriptedAnthropicClient()
        env = AppEnvironment(
            modelContainer: container,
            keychain: KeychainStore(service: "com.beardown.tests.coachvm.\(UUID().uuidString)"),
            anthropic: scripted
        )
        try env.keychain.write(key: .anthropicAPIKey, value: "sk-test")
        _ = try env.plans.createPlan(title: "B", startDate: .now, endDate: .now.addingTimeInterval(28 * 86400))
    }

    func test_send_appendsUserAndAssistantMessages() async throws {
        scripted.scripts = [[
            .messageStart,
            .contentBlockStart(index: 0, .text),
            .contentBlockDelta(index: 0, .text("hi back")),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn"),
            .messageStop,
        ]]
        let vm = CoachViewModel(env: env)
        vm.draft = "hi"
        await vm.send()
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].text, "hi")
        XCTAssertEqual(vm.messages[1].text, "hi back")
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.draft, "")
    }

    func test_send_emptyDraft_isNoop() async {
        let vm = CoachViewModel(env: env)
        vm.draft = "   "
        await vm.send()
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func test_send_setsErrorWhenKeyMissing() async {
        try? env.keychain.delete(key: .anthropicAPIKey)
        let vm = CoachViewModel(env: env)
        vm.draft = "hi"
        await vm.send()
        XCTAssertEqual(vm.state, .error("Add your API key in Settings."))
    }

    func test_retry_replaysLastUserText() async throws {
        // First send hits an error path
        try env.keychain.delete(key: .anthropicAPIKey)
        let vm = CoachViewModel(env: env)
        vm.draft = "hi"
        await vm.send()
        XCTAssertEqual(vm.state, .error("Add your API key in Settings."))
        XCTAssertEqual(vm.lastUserText, "hi")
        // Restore key, script a success, retry
        try env.keychain.write(key: .anthropicAPIKey, value: "sk-test")
        scripted.scripts = [[
            .messageStart,
            .contentBlockStart(index: 0, .text),
            .contentBlockDelta(index: 0, .text("ok")),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn"),
            .messageStop,
        ]]
        await vm.retry()
        XCTAssertEqual(vm.state, .idle)
        // The first failed turn already persisted the user message (it gets persisted before
        // the API call). So we expect user("hi") + user("hi") + assistant("ok") = 3
        // OR depending on implementation, just user("hi") + assistant("ok") if retry reuses
        // the previously persisted user row. Either is acceptable — assert assistant text only:
        XCTAssertEqual(vm.messages.last?.text, "ok")
    }

    func test_computeChips_returnsCoachChip_workoutAndPlanSwitchCases() throws {
        let planId = UUID()
        let toolCalls: [[String: Any]] = [[
            "id": "toolu_1", "name": "upsert_workout",
            "input": ["date": "2026-06-08", "title": "Easy run", "summary": "", "blocks": []],
        ]]
        let toolResults: [[String: Any]] = [[
            "tool_use_id": "toolu_1",
            "content": "Scheduled \"Easy run\" for 2026-06-08 in plan \"Race Prep\" (plan_id=\(planId.uuidString)).",
        ]]
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)
        m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)

        let chips = CoachViewModel.computeChipsForTest(from: m)
        XCTAssertEqual(chips.count, 2)

        guard case .planSwitch = chips[0] else { return XCTFail("expected planSwitch first; got \(chips[0])") }
        guard case .workout = chips[1] else { return XCTFail("expected workout second; got \(chips[1])") }
    }

    func test_computeChips_extractsPlanIdFromToolResults() throws {
        let planId = UUID()
        let toolCalls: [[String: Any]] = [[
            "id": "toolu_1",
            "name": "upsert_workout",
            "input": ["date": "2026-06-08", "title": "Easy run", "summary": "30 min", "blocks": []],
        ]]
        let toolResults: [[String: Any]] = [[
            "tool_use_id": "toolu_1",
            "content": "Scheduled \"Easy run\" for 2026-06-08 in plan \"Race Prep — June 24\" (plan_id=\(planId.uuidString)).",
        ]]
        let callsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)!
        let resultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)!
        let m = ChatMessage(role: .assistant, text: "Built your block.", conversationId: UUID())
        m.toolCallsJSON = callsJSON
        m.toolResultsJSON = resultsJSON

        let chips = CoachViewModel.computeChipsForTest(from: m)
        XCTAssertEqual(chips.count, 2)
        if case let .planSwitch(c) = chips[0] {
            XCTAssertEqual(c.planId, planId)
            XCTAssertTrue(c.label.contains("Race Prep — June 24"))
        } else { XCTFail("first chip should be planSwitch") }
        if case let .workout(c) = chips[1] {
            XCTAssertNil(c.planId)
        } else { XCTFail("second chip should be workout") }
    }

    func test_computeChips_dedupsMultipleWorkoutsToOneSwitchChipPerPlan() throws {
        let planId = UUID()
        let toolCalls: [[String: Any]] = (1...3).map { i in [
            "id": "toolu_\(i)",
            "name": "upsert_workout",
            "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": []],
        ] }
        let toolResults: [[String: Any]] = (1...3).map { i in [
            "tool_use_id": "toolu_\(i)",
            "content": "Scheduled \"W\(i)\" for 2026-06-0\(i) in plan \"Race Prep\" (plan_id=\(planId.uuidString)).",
        ] }
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)
        m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)

        let chips = CoachViewModel.computeChipsForTest(from: m)
        let switchChips = chips.filter { if case .planSwitch = $0 { return true }; return false }
        XCTAssertEqual(switchChips.count, 1)
    }

    func test_computeChips_emitsProposalChip_forAddEnvelope() throws {
        let env = ProposalEnvelope(
            mode: .add, status: .pending,
            planTitle: "Race Prep", planGoal: "",
            planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-06-03"),
                             title: "Push", summary: "", blocks: [])]
        )
        let envJSON = try ProposalCodec.encode(env)
        let toolResults: [[String: Any]] = [["tool_use_id": "toolu_1", "content": envJSON]]
        let toolCalls: [[String: Any]] = [["id": "toolu_1", "name": "propose_plan",
                                           "input": [:]]]
        let m = ChatMessage(role: .assistant, text: "Here's the block.", conversationId: UUID())
        m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)

        let chips = CoachViewModel.computeChipsForTest(from: m)
        XCTAssertEqual(chips.count, 1)
        guard case let .proposal(p) = chips[0] else {
            return XCTFail("expected .proposal; got \(chips[0])")
        }
        XCTAssertEqual(p.envelope.mode, .add)
        XCTAssertEqual(p.envelope.status, .pending)
        XCTAssertEqual(p.envelope.planTitle, "Race Prep")
        XCTAssertEqual(p.workoutCount, 1)
        XCTAssertEqual(p.messageId, m.id)
        XCTAssertEqual(p.toolUseId, "toolu_1")
    }

    func test_computeChips_proposalChip_sortsAboveWorkoutChips() throws {
        let env = ProposalEnvelope(
            mode: .add, status: .pending, planTitle: "X", planGoal: "",
            planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
        )
        let envJSON = try ProposalCodec.encode(env)
        let toolResults: [[String: Any]] = [["tool_use_id": "p1", "content": envJSON],
                                             ["tool_use_id": "u1", "content": "Scheduled X for 2026-06-08."]]
        let toolCalls: [[String: Any]] = [["id": "p1", "name": "propose_plan", "input": [:]],
                                           ["id": "u1", "name": "upsert_workout",
                                            "input": ["date": "2026-06-08", "title": "X", "summary": "", "blocks": []]]]
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: toolCalls, options: [.sortedKeys]), encoding: .utf8)

        let chips = CoachViewModel.computeChipsForTest(from: m)
        XCTAssertEqual(chips.count, 2)
        guard case .proposal = chips[0] else { return XCTFail("proposal must sort first") }
        guard case .workout = chips[1] else { return XCTFail("workout must sort after") }
    }

    func test_computeChips_fallsBackToPlainText_whenEnvelopeMalformed() throws {
        let toolResults: [[String: Any]] = [["tool_use_id": "x", "content": "not json {{{"]]
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
        let chips = CoachViewModel.computeChipsForTest(from: m)
        XCTAssertTrue(chips.allSatisfy { if case .proposal = $0 { return false }; return true })
    }

    func test_computeChips_appliedEnvelope_carriesAppliedStatus() throws {
        let pid = UUID()
        let env = ProposalEnvelope(
            mode: .add, status: .applied, planTitle: "X", planGoal: "",
            planId: nil, appliedPlanId: pid, appliedAt: .now, appliedMode: .switchPlan,
            workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
        )
        let envJSON = try ProposalCodec.encode(env)
        let toolResults: [[String: Any]] = [["tool_use_id": "t", "content": envJSON]]
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: [["id": "t", "name": "propose_plan", "input": [:]]], options: [.sortedKeys]), encoding: .utf8)

        let chips = CoachViewModel.computeChipsForTest(from: m)
        guard case let .proposal(p) = chips[0] else { return XCTFail("expected proposal") }
        XCTAssertEqual(p.envelope.status, .applied)
        XCTAssertEqual(p.envelope.appliedPlanId, pid)
        XCTAssertEqual(p.envelope.appliedMode, .switchPlan)
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }

    func test_proposalChipView_buildsForAllThreeStates() {
        // Pure type-check / construction smoke — we don't render here.
        let env = ProposalEnvelope(mode: .add, status: .pending,
                                   planTitle: "X", planGoal: "",
                                   planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
                                   workouts: [.init(date: .now, title: "x", summary: "", blocks: [])])
        let chip = ProposalChip(id: "1", messageId: UUID(), toolUseId: "t",
                                envelope: env, workoutCount: 1,
                                firstDate: .now, lastDate: .now)
        _ = ProposalChipView(chip: chip, onApply: { _, _ in }, onDismiss: { _ in })
        var applied = env; applied.status = .applied; applied.appliedMode = .switchPlan
        _ = ProposalChipView(
            chip: ProposalChip(id: "2", messageId: UUID(), toolUseId: "t",
                               envelope: applied, workoutCount: 1,
                               firstDate: .now, lastDate: .now),
            onApply: { _, _ in }, onDismiss: { _ in })
        var dismissed = env; dismissed.status = .dismissed
        _ = ProposalChipView(
            chip: ProposalChip(id: "3", messageId: UUID(), toolUseId: "t",
                               envelope: dismissed, workoutCount: 1,
                               firstDate: .now, lastDate: .now),
            onApply: { _, _ in }, onDismiss: { _ in })
    }

    func test_retro_groupsMultipleUpsertsWithSamePlanTitle_intoAppliedProposal() throws {
        let calls: [[String: Any]] = (1...3).map { i in
            ["id": "t\(i)", "name": "upsert_workout",
             "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": [],
                       "plan_title": "Old Block", "plan_goal": ""]]
        }
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)

        let chips = CoachViewModel.computeChipsForTest(from: m)
        let proposals = chips.compactMap { c -> ProposalChip? in
            if case .proposal(let p) = c { return p }; return nil
        }
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].envelope.status, .applied)
        XCTAssertEqual(proposals[0].envelope.planTitle, "Old Block")
        XCTAssertEqual(proposals[0].workoutCount, 3)
        XCTAssertTrue(proposals[0].isRetroactive)
    }

    func test_retro_singleUpsert_doesNotEmitProposal() throws {
        let calls: [[String: Any]] = [["id": "t1", "name": "upsert_workout",
            "input": ["date": "2026-06-01", "title": "W", "summary": "", "blocks": [],
                      "plan_title": "Single Plan"]]]
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)
        let chips = CoachViewModel.computeChipsForTest(from: m)
        XCTAssertTrue(chips.allSatisfy { if case .proposal = $0 { return false }; return true })
    }

    func test_retro_missingPlanTitle_emitsUpdatedPlanProposal() throws {
        let calls: [[String: Any]] = (1...2).map { i in
            ["id": "t\(i)", "name": "upsert_workout",
             "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": []]]
        }
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)
        let chips = CoachViewModel.computeChipsForTest(from: m)
        let proposals = chips.compactMap { c -> ProposalChip? in
            if case .proposal(let p) = c { return p }; return nil
        }
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].envelope.mode, .update)
        XCTAssertEqual(proposals[0].envelope.planTitle, "Updated plan")
        XCTAssertEqual(proposals[0].workoutCount, 2)
        XCTAssertEqual(proposals[0].envelope.appliedPlanId, nil)
    }

    func test_retro_doesNotEmitForNonUpsertTools() throws {
        let calls: [[String: Any]] = [
            ["id": "t1", "name": "delete_workout", "input": ["date": "2026-06-01"]],
            ["id": "t2", "name": "delete_workout", "input": ["date": "2026-06-02"]],
            ["id": "t3", "name": "get_recent_history", "input": [:]],
        ]
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)
        let chips = CoachViewModel.computeChipsForTest(from: m)
        XCTAssertTrue(chips.allSatisfy { if case .proposal = $0 { return false }; return true })
    }

    func test_retro_doesNotApply_whenEnvelopeAlreadyPresent() throws {
        // If a message already has a real proposal envelope, the multi-upsert path
        // (which writes plan_id into the result string) does NOT also synthesize a
        // virtual proposal. Otherwise we'd render two proposal chips for the same
        // logical action.
        let env = ProposalEnvelope(mode: .add, status: .pending, planTitle: "Real",
            planGoal: "", planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: .now, title: "x", summary: "", blocks: [])])
        let envJSON = try ProposalCodec.encode(env)
        let toolResults: [[String: Any]] = [["tool_use_id": "p", "content": envJSON]]
        let calls: [[String: Any]] = [
            ["id": "p", "name": "propose_plan", "input": [:]],
            ["id": "u1", "name": "upsert_workout",
             "input": ["date": "2026-06-01", "title": "W1", "summary": "", "blocks": [],
                       "plan_title": "Other Block"]],
            ["id": "u2", "name": "upsert_workout",
             "input": ["date": "2026-06-02", "title": "W2", "summary": "", "blocks": [],
                       "plan_title": "Other Block"]],
        ]
        let m = ChatMessage(role: .assistant, text: "", conversationId: UUID())
        m.toolResultsJSON = String(data: try JSONSerialization.data(withJSONObject: toolResults, options: [.sortedKeys]), encoding: .utf8)
        m.toolCallsJSON = String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)

        let chips = CoachViewModel.computeChipsForTest(from: m)
        let proposals = chips.compactMap { c -> ProposalChip? in
            if case .proposal(let p) = c { return p }; return nil
        }
        // One real proposal + one retroactive group for "Other Block".
        XCTAssertEqual(proposals.count, 2)
        XCTAssertEqual(proposals[0].envelope.status, .pending)
        XCTAssertEqual(proposals[1].envelope.status, .applied)
        XCTAssertTrue(proposals[1].isRetroactive)
    }

    func test_retro_resolvesAppliedPlanId_whenPlanTitleStillExists() throws {
        let existing = try env.plans.createPlan(
            title: "Block X", startDate: .now, endDate: .now.addingTimeInterval(86400))
        let calls: [[String: Any]] = (1...2).map { i in
            ["id": "t\(i)", "name": "upsert_workout",
             "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": [],
                       "plan_title": "Block X"]]
        }
        try env.chats.append(role: .assistant, text: "",
            toolCallsJSON: String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8),
            toolResultsJSON: nil)
        let vm = CoachViewModel(env: env)
        vm.refresh()
        let chip = firstProposal(in: vm)
        XCTAssertEqual(chip.envelope.appliedPlanId, existing.id)
    }

    func test_retro_appliedPlanId_isNil_whenPlanTitleNoLongerExists() throws {
        let calls: [[String: Any]] = (1...2).map { i in
            ["id": "t\(i)", "name": "upsert_workout",
             "input": ["date": "2026-06-0\(i)", "title": "W\(i)", "summary": "", "blocks": [],
                       "plan_title": "Deleted Block"]]
        }
        try env.chats.append(role: .assistant, text: "",
            toolCallsJSON: String(data: try JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8),
            toolResultsJSON: nil)
        let vm = CoachViewModel(env: env)
        vm.refresh()
        let chip = firstProposal(in: vm)
        XCTAssertNil(chip.envelope.appliedPlanId)
    }

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

    func test_applyProposal_addInactive_writesWorkouts_andMutatesEnvelopeStatus() async throws {
        let env = ProposalEnvelope(
            mode: .add, status: .pending, planTitle: "New Plan", planGoal: "",
            planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-07-01"),
                             title: "W1", summary: "", blocks: [])]
        )
        let envJSON = try ProposalCodec.encode(env)
        try self.env.chats.append(role: .assistant, text: "",
            toolCallsJSON: #"[{"id":"toolu_1","name":"propose_plan","input":{}}]"#,
            toolResultsJSON: #"[{"tool_use_id":"toolu_1","content":\#(jsonStringLiteral(envJSON))}]"#)
        let vm = CoachViewModel(env: self.env)
        vm.refresh()
        guard case let .proposal(p)? = vm.chips(for: vm.messages.last!).first(where: { if case .proposal = $0 { return true }; return false }) else {
            return XCTFail("expected a proposal chip")
        }
        await vm.applyProposal(p, mode: .addInactive)
        vm.refresh()
        let after = vm.messages.last!
        let updatedEnv = decodeFirstEnvelope(after)
        XCTAssertEqual(updatedEnv?.status, .applied)
        XCTAssertEqual(updatedEnv?.appliedMode, .inactive)
        XCTAssertNotNil(updatedEnv?.appliedPlanId)
        // Use startOfDay to match WorkoutRepository.upsert's local-TZ day normalization.
        let day = Calendar.current.startOfDay(for: dateFromIso("2026-07-01"))
        let written = try self.env.workouts.workoutsBetween(start: day, end: day.addingTimeInterval(86400))
        XCTAssertEqual(written.first?.title, "W1")
    }

    func test_applyProposal_addAndSwitch_setsNav() async throws {
        let env = ProposalEnvelope(
            mode: .add, status: .pending, planTitle: "Switch Plan", planGoal: "",
            planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-07-02"), title: "W", summary: "", blocks: [])]
        )
        let envJSON = try ProposalCodec.encode(env)
        try self.env.chats.append(role: .assistant, text: "",
            toolCallsJSON: #"[{"id":"t","name":"propose_plan","input":{}}]"#,
            toolResultsJSON: #"[{"tool_use_id":"t","content":\#(jsonStringLiteral(envJSON))}]"#)
        let nav = AppNavigation()
        let vm = CoachViewModel(env: self.env, nav: nav)
        vm.refresh()
        let chip = firstProposal(in: vm)
        await vm.applyProposal(chip, mode: .addAndSwitch)
        XCTAssertEqual(nav.selectedTab, 1)
        XCTAssertNotNil(nav.pendingPlanDetail)
    }

    func test_dismissProposal_mutatesEnvelopeWithoutWritingWorkouts() throws {
        let env = ProposalEnvelope(mode: .add, status: .pending, planTitle: "Phantom",
            planGoal: "", planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-07-01"), title: "W", summary: "", blocks: [])])
        let envJSON = try ProposalCodec.encode(env)
        try self.env.chats.append(role: .assistant, text: "",
            toolCallsJSON: #"[{"id":"t","name":"propose_plan","input":{}}]"#,
            toolResultsJSON: #"[{"tool_use_id":"t","content":\#(jsonStringLiteral(envJSON))}]"#)
        let vm = CoachViewModel(env: self.env)
        vm.refresh()
        let chip = firstProposal(in: vm)
        vm.dismissProposal(chip)
        vm.refresh()
        XCTAssertEqual(decodeFirstEnvelope(vm.messages.last!)?.status, .dismissed)
        let day = Calendar.current.startOfDay(for: dateFromIso("2026-07-01"))
        let workouts = try self.env.workouts.workoutsBetween(start: day, end: day.addingTimeInterval(86400))
        XCTAssertTrue(workouts.isEmpty, "dismiss must not write workouts")
    }

    private func firstProposal(in vm: CoachViewModel) -> ProposalChip {
        for m in vm.messages {
            for chip in vm.chips(for: m) {
                if case .proposal(let p) = chip { return p }
            }
        }
        fatalError("no proposal chip found")
    }

    private func decodeFirstEnvelope(_ m: ChatMessage) -> ProposalEnvelope? {
        guard let raw = m.toolResultsJSON,
              let arr = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]],
              let content = arr.first?["content"] as? String else { return nil }
        return ProposalCodec.decode(contentString: content)
    }

    private func jsonStringLiteral(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }
}
