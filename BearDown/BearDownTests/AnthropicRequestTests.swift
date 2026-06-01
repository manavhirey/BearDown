import XCTest
@testable import BearDown

final class AnthropicRequestTests: XCTestCase {
    func test_encodesUserMessageAndTools() throws {
        let req = AnthropicRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 8192,
            system: "you are a coach",
            messages: [
                .init(role: "user", content: [.text("hello")])
            ],
            tools: [
                .init(name: "upsert_workout",
                      description: "schedule a workout",
                      inputSchema: ["type": "object", "properties": [:], "required": []])
            ]
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(json["max_tokens"] as? Int, 8192)
        XCTAssertEqual(json["system"] as? String, "you are a coach")
        XCTAssertEqual((json["tools"] as? [[String: Any]])?.count, 1)
        let firstMessage = try XCTUnwrap((json["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(firstMessage["role"] as? String, "user")
    }

    func test_toolResultMessage_encodesProperly() throws {
        let req = AnthropicRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 1,
            system: "",
            messages: [
                .init(role: "user", content: [.toolResult(toolUseId: "toolu_1", content: "ok", isError: false)])
            ],
            tools: []
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let msg = try XCTUnwrap((json["messages"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap(msg["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "tool_result")
        XCTAssertEqual(content[0]["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(content[0]["is_error"] as? Bool, false)
    }
}
