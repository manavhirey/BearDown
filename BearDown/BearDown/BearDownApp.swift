import SwiftUI
import SwiftData

@main
struct BearDownApp: App {
    @StateObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if ProcessInfo.processInfo.arguments.contains("--reset-keychain") {
            try? KeychainStore().delete(key: .anthropicAPIKey)
        }

        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.production()
        } catch {
            // CloudKit unavailable (simulator without iCloud, user signed out,
            // entitlement missing). Fall back to on-disk-without-sync so user
            // data still persists across launches — never to in-memory, which
            // would silently throw away the user's training plans.
            do {
                environment = try AppEnvironment(modelContainer: .beardownLocalOnly())
            } catch {
                fatalError("Failed to initialize AppEnvironment: \(error)")
            }
        }
        _env = StateObject(wrappedValue: environment)

        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-week") {
            Task { @MainActor in
                if (try? environment.plans.activePlan()) == nil {
                    _ = try? environment.plans.createPlan(title: "UI",
                                                          startDate: .now,
                                                          endDate: .now.addingTimeInterval(7 * 86400))
                }
                let strength = BlockInput(
                    order: 0, kind: .strength, title: "Push UI",
                    notes: "Rest 2 min between sets.",
                    exercises: [
                        .init(order: 0, name: "Bench Press", sets: 4, reps: "5", load: "70% 1RM", restSeconds: 120),
                        .init(order: 1, name: "Overhead Press", sets: 3, reps: "8", load: "60% 1RM", restSeconds: 90),
                        .init(order: 2, name: "Dumbbell Row", sets: 3, reps: "10", load: "moderate", restSeconds: 75),
                    ])
                let cardio = BlockInput(
                    order: 1, kind: .cardio, title: "Zone 2 Finisher",
                    notes: "Easy effort — should be able to hold a conversation.",
                    cardio: .init(modality: "Bike", durationMinutes: 20,
                                  targetDescription: "RPE 4–5, ~130 bpm"))
                _ = try? environment.workouts.upsert(.init(
                    date: .now, title: "Push UI",
                    summary: "Bench + OHP main lifts, accessory row, then 20 min easy bike to finish.",
                    blocks: [strength, cardio]))
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-two-plans") {
            Task { @MainActor in
                let today = Calendar.current.startOfDay(for: .now)
                if (try? environment.plans.activePlan()) == nil {
                    _ = try? environment.plans.createPlan(
                        title: "Current Block",
                        startDate: today.addingTimeInterval(-6 * 86400),
                        endDate: today.addingTimeInterval(6 * 86400)
                    )
                }
                for offset in [-1, 0, 1] {
                    _ = try? environment.workouts.upsert(.init(
                        date: today.addingTimeInterval(TimeInterval(offset) * 86400),
                        title: "Active W\(offset)",
                        summary: "Seed",
                        blocks: []
                    ))
                }
                _ = try? environment.workouts.upsert(.init(
                    date: today.addingTimeInterval(21 * 86400),
                    title: "Race long run",
                    summary: "12mi",
                    blocks: [],
                    planTitle: "Race Prep — June 24",
                    planGoal: "3.5mi race goal pacing block"
                ))
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-chat-history") {
            Task { @MainActor in
                let chats = environment.chats
                // Ensure conversation A doesn't accidentally extend a leftover
                // conversation from a prior test run.
                chats.archiveCurrentConversation()

                // Conversation A — older, ends earlier.
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

        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-pending-proposal") {
            Task { @MainActor in
                // Provide a baseline active plan so the Plans tab isn't empty.
                if (try? environment.plans.activePlan()) == nil {
                    _ = try? environment.plans.createPlan(
                        title: "Current Block",
                        startDate: .now, endDate: .now.addingTimeInterval(7 * 86400)
                    )
                }
                // Tests in the same xcodebuild invocation share the on-disk store.
                // Remove any "Seeded Proposal Plan" left over from a prior test in
                // this run so each test sees a deterministic baseline.
                if let stale = try? environment.plans.plan(title: "Seeded Proposal Plan") {
                    try? environment.plans.delete(planId: stale.id)
                }
                // Wipe any chat rows persisted from a prior test in the same
                // xcodebuild invocation, then mint a fresh conversationId so the
                // seeded assistant message is the only one in the current
                // conversation when CoachView refreshes.
                if let prior = try? environment.chats.conversations() {
                    for c in prior { try? environment.chats.deleteConversation(id: c.id) }
                }
                environment.chats.archiveCurrentConversation()
                // Build a pending add-mode envelope by hand.
                let envelopeJSON: String = {
                    let obj: [String: Any] = [
                        "schema": "bd.proposal/v1",
                        "mode": "add",
                        "status": "pending",
                        "plan_title": "Seeded Proposal Plan",
                        "plan_goal": "Goal text",
                        "workouts": [
                            ["date": "2026-07-01", "title": "W1", "summary": "Compound-led", "blocks": []],
                            ["date": "2026-07-02", "title": "W2", "summary": "Easy run", "blocks": []],
                        ],
                    ]
                    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
                    return String(data: data, encoding: .utf8)!
                }()
                let toolUseId = "toolu_seed"
                let calls: [[String: Any]] = [["type": "tool_use", "id": toolUseId,
                                               "name": "propose_plan", "input": [:]]]
                let results: [[String: Any]] = [["type": "tool_result", "tool_use_id": toolUseId,
                                                 "content": envelopeJSON, "is_error": false]]
                let callsJSON = String(data: try! JSONSerialization.data(withJSONObject: calls, options: [.sortedKeys]), encoding: .utf8)!
                let resultsJSON = String(data: try! JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), encoding: .utf8)!
                try? environment.chats.append(role: .assistant,
                    text: "Here's a proposed plan.",
                    toolCallsJSON: callsJSON, toolResultsJSON: resultsJSON)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env)
                .modelContainer(env.modelContainer)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await reconcileNotifications() } }
                }
        }
    }

    @MainActor
    private func reconcileNotifications() async {
        let on = UserDefaults.standard.bool(forKey: "notifications.enabled")
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let end = cal.date(byAdding: .day, value: 365, to: today)!
        guard let ws = try? env.workouts.workoutsBetween(start: today, end: end) else { return }
        try? await env.notificationScheduler.reconcile(workouts: ws, enabled: on)
    }
}
