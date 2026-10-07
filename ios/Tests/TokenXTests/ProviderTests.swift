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
        let call = ProviderCall(model: Catalog.model(id: "claude-opus-5-5")!, key: "sk-test", profile: .character)
        let request = try provider.request(chat, call: call)
        XCTAssertEqual(request.url, AnthropicProvider.endpoint)
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let body = request.bodyJSON!
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 400)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "You are a bush.")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["temperature"], "sampling parameters are not sent to the 5-generation models")
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as! String }, ["user", "assistant", "user"])
        let result = collect(provider, body: Canned.anthropic)
        XCTAssertEqual(result.text, "Ask, and the bush shall sing.")
        XCTAssertEqual(result.done?.0, Usage(promptTokens: 25, replyTokens: 9))
        XCTAssertEqual(result.done?.1, .end)
        // Haiku keeps temperature and gets no effort or fallbacks
        let haikuRequest = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "claude-haiku-4-5")!, key: "k", profile: .character))
        let haiku = haikuRequest.bodyJSON!
        XCTAssertEqual(haiku["temperature"] as? Double, 0.9)
        XCTAssertNil(haiku["output_config"])
        XCTAssertNil(haiku["fallbacks"])
        XCTAssertNil(haikuRequest.headers["anthropic-beta"])
        // Sonnet 5.5 gets fallbacks too
        let sonnet = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "claude-sonnet-5-5")!, key: "k", profile: .assistant))
        XCTAssertEqual(sonnet.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        XCTAssertEqual(sonnet.bodyJSON?["fallbacks"] as? String, "default")
        XCTAssertThrowsError(try provider.request(chat, call: ProviderCall(model: call.model, key: nil, profile: .fast)))
    }

    func testAnthropicImagePartsAndJSONSchema() throws {
        let provider = AnthropicProvider()
        let schema: [String: Any] = ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false]
        let request = try provider.request(
            ChatRequest(messages: [.user(parts: [.text("Photo 1"), .image(data: "AAAA", mediaType: "image/jpeg"), .text("Compare.")])], maxTokens: 8000, jsonSchema: schema),
            call: ProviderCall(model: Catalog.model(id: "claude-opus-5-5")!, key: "k", profile: .vision))
        let body = request.bodyJSON!
        XCTAssertEqual(body["max_tokens"] as? Int, 8000)
        let content = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as! String }, ["text", "image", "text"])
        let source = content[1]["source"] as! [String: Any]
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "AAAA")
        let outputConfig = body["output_config"] as! [String: Any]
        XCTAssertEqual(outputConfig["effort"] as? String, "high")
        let format = outputConfig["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["schema"] as? [String: Any])?["required"] as? [String], ["ok"])
        // adjacent user turns with parts merge into one block list
        let merged = AnthropicProvider.messages([.user("first"), .user(parts: [.image(data: "BBBB", mediaType: "image/png")])])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual((merged[0]["content"] as! [[String: Any]]).map { $0["type"] as! String }, ["text", "image"])
    }

    func testAnthropicReportsRefusalStop() {
        let result = collect(AnthropicProvider(), body: Canned.anthropicRefusal)
        XCTAssertEqual(result.done?.1, .refusal)
        XCTAssertEqual(result.text, "")
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

    func testOpenAIImagePartsAndJSONSchema() throws {
        let provider = OpenAIProvider()
        let request = try provider.request(
            ChatRequest(messages: [.user(parts: [.text("What is this?"), .image(data: "AAAA", mediaType: "image/png")])], jsonSchema: ["type": "object"]),
            call: ProviderCall(model: Catalog.model(id: "gpt-5")!, key: "k", profile: .vision))
        let body = request.bodyJSON!
        let content = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        XCTAssertEqual(content.map { $0["type"] as! String }, ["text", "image_url"])
        XCTAssertEqual((content[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,AAAA")
        let format = body["response_format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["name"] as? String, "reply")
        XCTAssertEqual(((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])?["type"] as? String, "object")
        // text-only messages stay plain strings
        let plain = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gpt-5")!, key: "k", profile: .fast)).bodyJSON!
        XCTAssertEqual((plain["messages"] as! [[String: Any]])[1]["content"] as? String, "hello")
        XCTAssertNil(plain["response_format"])
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

    func testGeminiImagePartsAndJSONSchema() throws {
        let provider = GeminiProvider()
        let request = try provider.request(
            ChatRequest(messages: [.user(parts: [.text("What is this?"), .image(data: "AAAA", mediaType: "image/webp")])], jsonSchema: ["type": "object"]),
            call: ProviderCall(model: Catalog.model(id: "gemini-2.5-pro")!, key: "g", profile: .vision))
        let body = request.bodyJSON!
        let parts = (body["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]]
        XCTAssertEqual(parts[0]["text"] as? String, "What is this?")
        let inline = parts[1]["inlineData"] as! [String: Any]
        XCTAssertEqual(inline["mimeType"] as? String, "image/webp")
        XCTAssertEqual(inline["data"] as? String, "AAAA")
        XCTAssertEqual((body["generationConfig"] as? [String: Any])?["responseMimeType"] as? String, "application/json")
        let plain = try provider.request(chat, call: ProviderCall(model: Catalog.model(id: "gemini-2.5-pro")!, key: "g", profile: .fast)).bodyJSON!
        XCTAssertNil((plain["generationConfig"] as? [String: Any])?["responseMimeType"])
    }
}
