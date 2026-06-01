import Foundation

public protocol AnthropicClientProtocol: Sendable {
    /// Lightweight call used by onboarding to validate that an API key works.
    func validate(apiKey: String) async throws

    /// Stream a Messages request. Each call yields events as they arrive.
    func stream(apiKey: String, request: AnthropicRequest) -> AsyncThrowingStream<AnthropicEvent, Error>
}

public struct AnthropicClient: AnthropicClientProtocol, @unchecked Sendable {
    public static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func validate(apiKey: String) async throws {
        let req = AnthropicRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 1,
            system: nil,
            messages: [.init(role: "user", content: [.text("ping")])],
            tools: []
        )
        var urlReq = URLRequest(url: Self.messagesURL)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlReq.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        var nonStreaming = req
        nonStreaming.stream = false
        urlReq.httpBody = try JSONEncoder().encode(nonStreaming)
        let (data, resp) = try await session.data(for: urlReq)
        guard let http = resp as? HTTPURLResponse else {
            throw CoachError.networkFailure("Not an HTTP response")
        }
        guard 200..<300 ~= http.statusCode else {
            throw CoachError.invalidResponse(status: http.statusCode,
                                             body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    public func stream(apiKey: String, request: AnthropicRequest) -> AsyncThrowingStream<AnthropicEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var urlReq = URLRequest(url: Self.messagesURL)
                    urlReq.httpMethod = "POST"
                    urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    urlReq.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
                    urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlReq.httpBody = try JSONEncoder().encode(request)

                    let (bytes, resp) = try await session.bytes(for: urlReq)
                    guard let http = resp as? HTTPURLResponse else {
                        throw CoachError.networkFailure("Not an HTTP response")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var bodyAcc = ""
                        for try await line in bytes.lines { bodyAcc += line }
                        throw CoachError.invalidResponse(status: http.statusCode, body: bodyAcc)
                    }

                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let evt = parser.feed(line: line) {
                            continuation.yield(evt)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
