import Foundation

public enum ProposalCodec {

    public static let schemaVersion = "bd.proposal/v1"

    /// Encode `ProposalEnvelope` to a `bd.proposal/v1` JSON string using
    /// `.sortedKeys` only (no `.prettyPrinted` — see CLAUDE.md gotcha #6).
    public static func encode(_ env: ProposalEnvelope) throws -> String {
        var obj: [String: Any] = [
            "schema": schemaVersion,
            "mode": env.mode.rawValue,
            "status": env.status.rawValue,
            "plan_title": env.planTitle,
            "plan_goal": env.planGoal,
            "workouts": env.workouts.map(encodeWorkout),
        ]
        if let pid = env.planId { obj["plan_id"] = pid.uuidString }
        if let apid = env.appliedPlanId { obj["applied_plan_id"] = apid.uuidString }
        if let at = env.appliedAt { obj["applied_at"] = isoTimestamp(at) }
        if let am = env.appliedMode { obj["applied_mode"] = am.rawValue }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        // JSONSerialization escapes "/" as "\/" by default; un-escape so the on-wire
        // form matches the spec literally ("bd.proposal/v1", not "bd.proposal\/v1").
        let raw = String(data: data, encoding: .utf8) ?? "{}"
        return raw.replacingOccurrences(of: "\\/", with: "/")
    }

    /// Try to decode a string-encoded tool result as a `bd.proposal/v1` envelope.
    /// Returns `nil` for anything that isn't a proposal — plain-text immediate-write
    /// results, malformed JSON, unknown schema versions, etc.
    public static func decode(contentString: String) -> ProposalEnvelope? {
        guard let data = contentString.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["schema"] as? String) == schemaVersion,
              let modeRaw = obj["mode"] as? String,
              let mode = ProposalEnvelope.Mode(rawValue: modeRaw),
              let statusRaw = obj["status"] as? String,
              let status = ProposalEnvelope.Status(rawValue: statusRaw)
        else { return nil }

        let workoutsRaw = (obj["workouts"] as? [[String: Any]]) ?? []
        let workouts = workoutsRaw.compactMap(decodeWorkout)
        let planId = (obj["plan_id"] as? String).flatMap(UUID.init(uuidString:))
        let appliedPlanId = (obj["applied_plan_id"] as? String).flatMap(UUID.init(uuidString:))
        let appliedAt = (obj["applied_at"] as? String).flatMap(parseTimestamp)
        let appliedMode = (obj["applied_mode"] as? String)
            .flatMap(ProposalEnvelope.AppliedMode.init(rawValue:))

        return ProposalEnvelope(
            mode: mode,
            status: status,
            planTitle: (obj["plan_title"] as? String) ?? "",
            planGoal: (obj["plan_goal"] as? String) ?? "",
            planId: planId,
            appliedPlanId: appliedPlanId,
            appliedAt: appliedAt,
            appliedMode: appliedMode,
            workouts: workouts
        )
    }

    // MARK: – Workouts

    private static func encodeWorkout(_ w: ProposalWorkout) -> [String: Any] {
        [
            "date": isoDate(w.date),
            "title": w.title,
            "summary": w.summary,
            "blocks": w.blocks.map(encodeBlock),
        ]
    }

    private static func decodeWorkout(_ obj: [String: Any]) -> ProposalWorkout? {
        guard let dateStr = obj["date"] as? String,
              let date = parseDate(dateStr) else { return nil }
        let blocksRaw = (obj["blocks"] as? [[String: Any]]) ?? []
        return ProposalWorkout(
            date: date,
            title: (obj["title"] as? String) ?? "",
            summary: (obj["summary"] as? String) ?? "",
            blocks: blocksRaw.compactMap(decodeBlock)
        )
    }

    private static func encodeBlock(_ b: ProposalBlock) -> [String: Any] {
        var obj: [String: Any] = [
            "order": b.order,
            "kind": b.kind.rawValue,
            "title": b.title,
            "notes": b.notes,
        ]
        if !b.exercises.isEmpty {
            obj["exercises"] = b.exercises.map { e -> [String: Any] in
                var d: [String: Any] = [
                    "order": e.order, "name": e.name,
                    "sets": e.sets, "reps": e.reps,
                ]
                if let l = e.load { d["load"] = l }
                if let r = e.restSeconds { d["rest_seconds"] = r }
                return d
            }
        }
        if let c = b.cardio {
            var d: [String: Any] = ["modality": c.modality]
            if let m = c.durationMinutes { d["duration_minutes"] = m }
            if let m = c.distanceMeters { d["distance_meters"] = m }
            if let t = c.targetDescription { d["target"] = t }
            obj["cardio"] = d
        }
        return obj
    }

    private static func decodeBlock(_ obj: [String: Any]) -> ProposalBlock? {
        guard let kindRaw = obj["kind"] as? String,
              let kind = BlockKind(rawValue: kindRaw) else { return nil }
        let exercises = ((obj["exercises"] as? [[String: Any]]) ?? []).compactMap { e -> ProposalExercise? in
            guard let name = e["name"] as? String,
                  let sets = e["sets"] as? Int,
                  let reps = e["reps"] as? String else { return nil }
            return ProposalExercise(
                order: (e["order"] as? Int) ?? 0,
                name: name, sets: sets, reps: reps,
                load: e["load"] as? String,
                restSeconds: e["rest_seconds"] as? Int
            )
        }
        var cardio: ProposalCardio? = nil
        if let c = obj["cardio"] as? [String: Any],
           let modality = c["modality"] as? String {
            cardio = ProposalCardio(
                modality: modality,
                durationMinutes: c["duration_minutes"] as? Int,
                distanceMeters: c["distance_meters"] as? Double,
                targetDescription: c["target"] as? String
            )
        }
        return ProposalBlock(
            order: (obj["order"] as? Int) ?? 0,
            kind: kind,
            title: (obj["title"] as? String) ?? "",
            notes: (obj["notes"] as? String) ?? "",
            exercises: exercises,
            cardio: cardio
        )
    }

    // MARK: – Date helpers

    private static func isoDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: d)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)
    }

    private static func isoTimestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
