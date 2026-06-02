import XCTest
@testable import BearDown

final class ProposalCodecTests: XCTestCase {
    func test_encode_pendingAddEnvelope_isStableSortedKeysJSON() throws {
        let env = ProposalEnvelope(
            mode: .add, status: .pending,
            planTitle: "Race Prep", planGoal: "Goal text",
            planId: nil, appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [
                .init(date: dateFromIso("2026-06-03"),
                      title: "Push", summary: "Compound-led",
                      blocks: [
                        .init(order: 0, kind: .strength,
                              title: "Push", notes: "",
                              exercises: [.init(order: 0, name: "Bench",
                                                sets: 5, reps: "5", load: "60kg")])
                      ])
            ]
        )
        let json = try ProposalCodec.encode(env)
        // Discriminator + mode + status must be present.
        XCTAssertTrue(json.contains("\"schema\":\"bd.proposal/v1\""), json)
        XCTAssertTrue(json.contains("\"mode\":\"add\""), json)
        XCTAssertTrue(json.contains("\"status\":\"pending\""), json)
        XCTAssertTrue(json.contains("\"plan_title\":\"Race Prep\""), json)
        XCTAssertFalse(json.contains(": "), "sortedKeys output must not contain spaces after colons; got: \(json)")
    }

    func test_decode_roundtripsAValidEnvelope() throws {
        let env = ProposalEnvelope(
            mode: .update, status: .pending,
            planTitle: "Block X", planGoal: "",
            planId: UUID(uuidString: "4DC1F70E-7B16-4F8E-A41C-71BC2A3DF812"),
            appliedPlanId: nil, appliedAt: nil, appliedMode: nil,
            workouts: [.init(date: dateFromIso("2026-06-10"),
                             title: "Run", summary: "Easy",
                             blocks: [.init(order: 0, kind: .cardio,
                                            title: "Run", notes: "",
                                            cardio: .init(modality: "Run",
                                                          durationMinutes: 30))])]
        )
        let json = try ProposalCodec.encode(env)
        let decoded = ProposalCodec.decode(contentString: json)
        XCTAssertEqual(decoded, env)
    }

    func test_decode_appliedEnvelope_carriesAppliedFields() throws {
        let pid = UUID()
        let env = ProposalEnvelope(
            mode: .add, status: .applied,
            planTitle: "Block", planGoal: "",
            planId: nil, appliedPlanId: pid,
            appliedAt: Date(timeIntervalSince1970: 1_780_000_000),
            appliedMode: .switchPlan,
            workouts: [.init(date: .now, title: "x", summary: "", blocks: [])]
        )
        let json = try ProposalCodec.encode(env)
        XCTAssertTrue(json.contains("\"applied_mode\":\"switch\""), json)
        XCTAssertTrue(json.contains("\"applied_plan_id\":\"\(pid.uuidString)\""), json)
        let decoded = ProposalCodec.decode(contentString: json)
        XCTAssertEqual(decoded?.status, .applied)
        XCTAssertEqual(decoded?.appliedPlanId, pid)
        XCTAssertEqual(decoded?.appliedMode, .switchPlan)
    }

    func test_decode_rejectsMissingSchemaDiscriminator() {
        let raw = #"{"mode":"add","status":"pending","plan_title":"x","workouts":[]}"#
        XCTAssertNil(ProposalCodec.decode(contentString: raw))
    }

    func test_decode_rejectsUnknownSchemaVersion() {
        let raw = #"{"schema":"bd.proposal/v2","mode":"add","status":"pending","plan_title":"x","workouts":[]}"#
        XCTAssertNil(ProposalCodec.decode(contentString: raw))
    }

    func test_decode_rejectsPlainTextResultStrings() {
        // Immediate-write `upsert_workout` result strings must not be decoded as proposals.
        let raw = #"Scheduled "Easy run" for 2026-06-08 in plan "Race Prep" (plan_id=4DC1F70E-7B16-4F8E-A41C-71BC2A3DF812)."#
        XCTAssertNil(ProposalCodec.decode(contentString: raw))
    }

    private func dateFromIso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: s)!
    }
}
