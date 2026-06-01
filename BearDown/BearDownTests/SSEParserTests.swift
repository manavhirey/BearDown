import XCTest
@testable import BearDown

final class SSEParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parse(_ text: String) -> [AnthropicEvent] {
        var parser = SSEParser()
        var events: [AnthropicEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let evt = parser.feed(line: String(line)) { events.append(evt) }
        }
        return events
    }

    func test_textOnlyStream_producesExpectedEventSequence() throws {
        let events = parse(try fixture("stream-text-only"))
        XCTAssertEqual(events.count, 7)
        guard case .messageStart = events[0] else { return XCTFail() }
        if case let .contentBlockDelta(_, delta) = events[2],
           case let .text(text) = delta {
            XCTAssertEqual(text, "Hello ")
        } else { XCTFail("Expected text delta") }
        if case let .messageDelta(stopReason) = events[5] {
            XCTAssertEqual(stopReason, "end_turn")
        } else { XCTFail("Expected message_delta with stop_reason") }
    }

    func test_toolUseStream_carriesPartialJsonDeltas() throws {
        let events = parse(try fixture("stream-with-tool-use"))
        let jsonDeltas: [String] = events.compactMap {
            if case let .contentBlockDelta(_, delta) = $0,
               case let .inputJson(partial) = delta { return partial }
            return nil
        }
        let concatenated = jsonDeltas.joined()
        XCTAssertEqual(concatenated, #"{"date":"2026-06-01","title":"Push","summary":"","blocks":[]}"#)
    }

    func test_toolUseStream_emitsToolUseStart() throws {
        let events = parse(try fixture("stream-with-tool-use"))
        let starts = events.compactMap { (e) -> (Int, String, String)? in
            if case let .contentBlockStart(idx, .toolUse(id, name)) = e { return (idx, id, name) }
            return nil
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].0, 1)
        XCTAssertEqual(starts[0].1, "toolu_1")
        XCTAssertEqual(starts[0].2, "upsert_workout")
    }
}
