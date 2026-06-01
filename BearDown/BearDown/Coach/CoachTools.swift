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
                        ]
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
        let workoutInput = WorkoutInput(date: date, title: title, summary: summary, blocks: parsedBlocks)
        do {
            let w = try workouts.upsert(workoutInput)
            return ToolResult(content: "Scheduled \(title) for \(dateStr) (workout \(w.id.uuidString.prefix(8))).",
                              isError: false)
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
