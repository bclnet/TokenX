import XCTest
@testable import TokenX

final class ProviderTests: XCTestCase {
    let chat = ChatRequest(system: "You are a bush.", messages: [.user("hello"), .assistant("hi"), .user("sing")])

    func collect(_ provider: Provider, body: String) -> (text: String, done: (Usage, StopReason)?) {
        var parser = provider.makeParser()
        var text = ""
        var done: (Usage, StopReason)?
        var splitter = LineSplitter()
        var lines = splitter.append(Data(body.utf8))
        if let last = splitter.flush() { lines.append(last) }
        for line in lines { for e in parser.feed(line) { if case .text(let t) = e { text += t } else if case .done(let u, let s) = e { done = (u, s) } } }
        for e in parser.finish() { if case .text(let t) = e { text += t } else if case .done(let u, let s) = e { done = (u, s) } }
        return (text, done)
    }

    func testAnthropicRequestAndStream() throws {
        let provider = AnthropicProvider()
        let call = ProviderCall(model: Catalog.model(id: "claude-opus-5")!, key: "sk-test", profile: .character)
        let request = try provider.request(chat, call: call)
        XCTAssertEqual(request.url, AnthropicProvider.endpoint)
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        let body = request.bodyJSON!
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "You are a bush.")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["temperature"], "sampling parameters are not sent to the 5-generation models")
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["user", "assistant", "user"])
        let result = collect(provider, body: Canned.anthropic)
        XCTAssertEqual(result.text, "Ask, and the bush shall sing.")
        XCTAssertEqual(result.done?.0, Usage(promptTokens: 25, replyTokens: 9))
        XCTAssertEqual(result.done?.1, .end)
        // Haiku keeps temperature and gets no effort
        let haiku = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "claude-haiku-4-5")!, key: "k", profile: .character)).bodyJSON!
        XCTAssertEqual(haiku["temperature"] as? Double, 0.9)
        XCTAssertNil(haiku["output_config"])
        XCTAssertThrowsError(try provider.request(chat, call: ProviderCall(model: call.model, key: nil, profile: .fast)))
    }

    func testAnthropicMergesAdjacentRoles() {
        let merged = AnthropicProvider.messages([.assistant("a"), .user("b"), .user("c")])
        XCTAssertEqual(merged.map { $0["role"] as! String }, ["user", "assistant", "user"])
        XCTAssertEqual(merged[2]["content"] as? String, "b\nc")
    }

    func testOpenAIRequestAndStream() throws {
        let provider = OpenAIProvider()
        let request = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gpt-5-mini")!, key: "sk-o", profile: .fast))
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-o")
        let body = request.bodyJSON!
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1024)
        XCTAssertEqual((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.count, 4)
        let result = collect(provider, body: Canned.openai)
        XCTAssertEqual(result.text, "Hello there")
        XCTAssertEqual(result.done?.0, Usage(promptTokens: 12, replyTokens: 2))
    }

    func testLocalServerUsesBaseURLAndNoKey() throws {
        let provider = OpenAIProvider(kind: .local)
        var model = Catalog.local[0]
        model.id = "llama3"
        let request = try provider.request(chat, call: ProviderCall(model: model, key: nil, baseURL: URL(string: "http://192.168.1.20:11434/v1"), profile: .character))
        XCTAssertEqual(request.url.absoluteString, "http://192.168.1.20:11434/v1/chat/completions")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(request.bodyJSON?["model"] as? String, "llama3")
        XCTAssertEqual(request.bodyJSON?["temperature"] as? Double, 0.9)
        XCTAssertThrowsError(try provider.request(chat, call: ProviderCall(model: model, key: nil, baseURL: nil, profile: .character)))
    }

    func testGeminiRequestAndStream() throws {
        let provider = GeminiProvider()
        let request = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gemini-2.5-flash")!, key: "g", profile: .assistant))
        XCTAssertTrue(request.url.absoluteString.hasSuffix("gemini-2.5-flash:streamGenerateContent?alt=sse"))
        XCTAssertEqual(request.headers["x-goog-api-key"], "g")
        let body = request.bodyJSON!
        XCTAssertEqual((body["contents"] as! [[String: Any]]).map { $0["role"] as! String }, ["user", "model", "user"])
        XCTAssertNotNil(body["systemInstruction"])
        let result = collect(provider, body: Canned.gemini)
        XCTAssertEqual(result.text, "Woof.")
        XCTAssertEqual(result.done?.0, Usage(promptTokens: 7, replyTokens: 2))
        XCTAssertEqual(result.done?.1, .end)
    }
}
