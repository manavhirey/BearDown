import Foundation

public struct ToolResult: Equatable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool) {
        self.content = content
        self.isError = isError
    }
}

@MainActor
public final class CoachTools {
    private let plans: PlanRepository
    private let workouts: WorkoutRepository

    public init(plans: PlanRepository, workouts: WorkoutRepository) {
        self.plans = plans
        self.workouts = workouts
    }

    public var definitions: [AnthropicRequest.Tool] {
        [
            .init(name: "upsert_workout",
                  description: "Create or replace the workout on a specific date in the active training plan. Idempotent on date.",
                  inputSchema: [
                    "type": "object",
                    "required": ["date", "title", "summary", "blocks"],
                    "properties": [
                        "date": ["type": "string", "description": "YYYY-MM-DD"],
                        "title": ["type": "string"],
                        "summary": ["type": "string", "description": "One-line description for the calendar card."],
                        "blocks": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "required": ["order", "kind", "title", "notes"],
                                "properties": [
                                    "order": ["type": "integer"],
                                    "kind": ["type": "string", "enum": ["strength", "cardio", "mobility"]],
                                    "title": ["type": "string"],
                                    "notes": ["type": "string"],
                                    "exercises": [
                                        "type": "array",
                                        "items": [
                                            "type": "object",
                                            "required": ["order", "name", "sets", "reps"],
                                            "properties": [
                                                "order": ["type": "integer"],
                                                "name": ["type": "string"],
                                                "sets": ["type": "integer"],
                                                "reps": ["type": "string", "description": "e.g. \"5\", \"8-10\", \"AMRAP\""],
                                                "load": ["type": "string", "description": "e.g. \"60kg\", \"bodyweight\", \"RPE 7\""],
                                                "rest_seconds": ["type": "integer"]
                                            ]
                                        ]
                                    ],
                                    "cardio": [
                                        "type": "object",
                                        "required": ["modality"],
                                        "properties": [
                                            "modality": ["type": "string"],
                                            "duration_minutes": ["type": "integer"],
                                            "distance_meters": ["type": "number"],
                                            "target": ["type": "string"]
                                        ]
                                    ]
                                ]
                            ]
                        ],
                        "plan_title": [
                            "type": "string",
                            "description": "Optional. Attach this workout to a named training plan. If the plan doesn't exist, it's created in an inactive state — the user will activate it via the Switch to plan chip. Reuse the same plan_title across every workout you write for one block."
                        ],
                        "plan_goal": [
                            "type": "string",
                            "description": "Optional. One-line goal for the plan (e.g. 'Race prep — 3.5mi June 24'). Only applied when creating the plan; ignored on subsequent writes to the same plan_title."
                        ],
                    ]
                  ]),
            .init(name: "delete_workout",
                  description: "Remove the workout on a specific date in the active training plan.",
                  inputSchema: [
                    "type": "object",
                    "required": ["date"],
                    "properties": ["date": ["type": "string", "description": "YYYY-MM-DD"]]
                  ]),
            .init(name: "get_recent_history",
                  description: "Return the user's recent workouts and completion status as JSON. Default 14 days, max 30.",
                  inputSchema: [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "minimum": 1, "maximum": 30]
                    ]
                  ]),
            .init(name: "propose_plan",
                  description: "Propose a brand-new training plan for the user to approve. Use this whenever you're sketching out a multi-workout block (race prep, new mesocycle, returning from a break). The proposal is NOT written to the user's calendar until they tap a button. Do not use this for single-workout adjustments inside an existing active block — use upsert_workout for that.",
                  inputSchema: [
                    "type": "object",
                    "required": ["plan_title", "plan_goal", "workouts"],
                    "properties": [
                        "plan_title": ["type": "string", "description": "Name of the proposed plan. Treat as the block's identity."],
                        "plan_goal": ["type": "string", "description": "One-line goal. Shown on the plan card."],
                        "workouts": [
                            "type": "array",
                            "minItems": 1,
                            "items": [
                                "type": "object",
                                "required": ["date", "title", "summary", "blocks"],
                                "properties": [
                                    "date": ["type": "string", "description": "YYYY-MM-DD"],
                                    "title": ["type": "string"],
                                    "summary": ["type": "string"],
                                    "blocks": [
                                        "type": "array",
                                        "items": [
                                            "type": "object",
                                            "required": ["order", "kind", "title", "notes"],
                                            "properties": [
                                                "order": ["type": "integer"],
                                                "kind": ["type": "string", "enum": ["strength", "cardio", "mobility"]],
                                                "title": ["type": "string"],
                                                "notes": ["type": "string"],
                                                "exercises": [
                                                    "type": "array",
                                                    "items": [
                                                        "type": "object",
                                                        "required": ["order", "name", "sets", "reps"],
                                                        "properties": [
                                                            "order": ["type": "integer"],
                                                            "name": ["type": "string"],
                                                            "sets": ["type": "integer"],
                                                            "reps": ["type": "string"],
                                                            "load": ["type": "string"],
                                                            "rest_seconds": ["type": "integer"]
                                                        ]
                                                    ]
                                                ],
                                                "cardio": [
                                                    "type": "object",
                                                    "required": ["modality"],
                                                    "properties": [
                                                        "modality": ["type": "string"],
                                                        "duration_minutes": ["type": "integer"],
                                                        "distance_meters": ["type": "number"],
                                                        "target": ["type": "string"]
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                  ]),
        ]
    }

    public func dispatch(name: String, input: [String: Any]) throws -> ToolResult {
        switch name {
        case "upsert_workout":
            return try handleUpsert(input)
        case "delete_workout":
            return try handleDelete(input)
        case "get_recent_history":
            return try handleHistory(input)
        case "propose_plan":
            return try handlePropose(input)
        default:
            return ToolResult(content: "Unknown tool: \(name)", isError: true)
        }
    }

    private func handleUpsert(_ input: [String: Any]) throws -> ToolResult {
        guard let dateStr = input["date"] as? String,
              let date = parseIsoDate(dateStr) else {
            return ToolResult(content: "Invalid or missing `date` (expected YYYY-MM-DD).", isError: true)
        }
        let title = (input["title"] as? String) ?? ""
        let summary = (input["summary"] as? String) ?? ""
        guard !title.isEmpty else {
            return ToolResult(content: "`title` is required.", isError: true)
        }
        let rawBlocks = (input["blocks"] as? [[String: Any]]) ?? []
        var parsedBlocks: [BlockInput] = []
        for (i, b) in rawBlocks.enumerated() {
            guard let kindRaw = b["kind"] as? String,
                  let kind = BlockKind(rawValue: kindRaw) else {
                return ToolResult(content: "Block \(i): invalid `kind` (expected strength|cardio|mobility).",
                                  isError: true)
            }
            let order = (b["order"] as? Int) ?? i
            let blockTitle = (b["title"] as? String) ?? ""
            let notes = (b["notes"] as? String) ?? ""

            var exercises: [ExerciseInput] = []
            if let raw = b["exercises"] as? [[String: Any]] {
                for (j, e) in raw.enumerated() {
                    guard let name = e["name"] as? String, !name.isEmpty,
                          let sets = e["sets"] as? Int,
                          let reps = e["reps"] as? String else {
                        return ToolResult(content: "Block \(i) exercise \(j): missing name/sets/reps.",
                                          isError: true)
                    }
                    exercises.append(.init(order: (e["order"] as? Int) ?? j,
                                           name: name, sets: sets, reps: reps,
                                           load: e["load"] as? String,
                                           restSeconds: e["rest_seconds"] as? Int))
                }
            }

            var cardio: CardioInput? = nil
            if let c = b["cardio"] as? [String: Any] {
                guard let modality = c["modality"] as? String, !modality.isEmpty else {
                    return ToolResult(content: "Block \(i) cardio: missing `modality`.", isError: true)
                }
                cardio = .init(modality: modality,
                               durationMinutes: c["duration_minutes"] as? Int,
                               distanceMeters: c["distance_meters"] as? Double,
                               targetDescription: c["target"] as? String)
            }
            parsedBlocks.append(.init(order: order, kind: kind, title: blockTitle, notes: notes,
                                      exercises: exercises, cardio: cardio))
        }
        let planTitle = (input["plan_title"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }
        let planGoal = (input["plan_goal"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0
        }

        let workoutInput = WorkoutInput(
            date: date, title: title, summary: summary, blocks: parsedBlocks,
            planTitle: planTitle, planGoal: planGoal
        )
        do {
            let w = try workouts.upsert(workoutInput)
            if let planTitle, let plan = w.plan {
                return ToolResult(
                    content: "Scheduled \"\(title)\" for \(dateStr) in plan \"\(planTitle)\" (plan_id=\(plan.id.uuidString)).",
                    isError: false
                )
            }
            return ToolResult(
                content: "Scheduled \(title) for \(dateStr) (workout \(w.id.uuidString.prefix(8))).",
                isError: false
            )
        } catch RepositoryError.noActivePlan {
            return ToolResult(content: "No active training plan. Ask the user to confirm the block goal/length first.",
                              isError: true)
        } catch {
            return ToolResult(content: "Persistence error: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleDelete(_ input: [String: Any]) throws -> ToolResult {
        guard let dateStr = input["date"] as? String,
              let date = parseIsoDate(dateStr) else {
            return ToolResult(content: "Invalid or missing `date`.", isError: true)
        }
        try workouts.delete(date: date)
        return ToolResult(content: "Deleted any workout on \(dateStr).", isError: false)
    }

    private func handleHistory(_ input: [String: Any]) throws -> ToolResult {
        let requested = (input["days"] as? Int) ?? 14
        let days = min(max(requested, 1), 30)
        let history = try workouts.recentHistory(days: days)
        let arr: [[String: Any]] = history.map { h in
            var obj: [String: Any] = [
                "date": isoString(h.date),
                "title": h.title,
                "status": h.status.rawValue,
                "blocks_summary": h.blocksSummary,
            ]
            if let n = h.note { obj["note"] = n }
            return obj
        }
        let data = try JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])
        return ToolResult(content: String(data: data, encoding: .utf8) ?? "[]", isError: false)
    }

    private func handlePropose(_ input: [String: Any]) throws -> ToolResult {
        let planTitle = ((input["plan_title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !planTitle.isEmpty else {
            return ToolResult(content: "`plan_title` is required.", isError: true)
        }
        let planGoal = (input["plan_goal"] as? String) ?? ""
        let rawWorkouts = (input["workouts"] as? [[String: Any]]) ?? []
        guard !rawWorkouts.isEmpty else {
            return ToolResult(content: "Proposal must include at least one workout.", isError: true)
        }
        let normalized: [[String: Any]]
        do { normalized = try ProposalCodec.normalizeWorkouts(rawWorkouts) }
        catch let e as ProposalCodec.NormalizeError {
            return ToolResult(content: e.message, isError: true)
        }
        let envelope: [String: Any] = [
            "schema": ProposalCodec.schemaVersion,
            "mode": "add",
            "status": "pending",
            "plan_title": planTitle,
            "plan_goal": planGoal,
            "workouts": normalized,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return ToolResult(content: String(data: data, encoding: .utf8) ?? "{}", isError: false)
    }

    private func parseIsoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    private func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: d)
    }
}
