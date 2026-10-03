import XCTest
@testable import TokenX

final class ServerTests: XCTestCase {
    var transport: FakeTransport!
    var server: TokenServer!

    override func setUp() {
        transport = FakeTransport()
        transport.responses["api.anthropic.com"] = (200, Canned.anthropic)
        transport.responses["api.openai.com"] = (200, Canned.openai)
        server = TokenServer(store: InMemoryStore(), cipher: PlainCipher(), transport: transport)
    }

    func stream(_ session: TokenSession, _ text: String = "sing") -> (Result<ChatReply, TokenXError>?, [String]) {
        var result: Result<ChatReply, TokenXError>?
        var deltas: [String] = []
        session.stream(ChatRequest(system: "bush", messages: [.user(text)]), onText: { deltas.append($0) }, completion: { result = $0 })
        return (result, deltas)
    }

    func testNotReadyWithoutProviderOrKey() throws {
        XCTAssertFalse(server.isReady)
        let client = TokenClient(broker: server)
        var (result, _) = stream(client.session(consumer: "bush", profile: .character))
        XCTAssertEqual(try? result?.get(), nil)
        if case .failure(let e)? = result { XCTAssertEqual(e, .noProvider) } else { XCTFail() }
        try server.update { $0.activeProvider = .anthropic }
        XCTAssertFalse(server.isReady)
        (result, _) = stream(client.session(consumer: "bush", profile: .character))
        if case .failure(let e)? = result { XCTAssertEqual(e, .missingKey(.anthropic)) } else { XCTFail() }
        try server.activate(.local)
        XCTAssertFalse(server.isReady, "local needs a base URL")
        try server.update { $0.localBaseURL = "http://h/v1" }
        XCTAssertTrue(server.isReady)
    }

    func testStreamsRecordsUsageAndEncryptsKeys() throws {
        struct Rot13: SecretCipher {
            func encrypt(_ p: Data) throws -> Data { Data(p.map { $0 ^ 0x2A }) }
            func decrypt(_ c: Data) throws -> Data { Data(c.map { $0 ^ 0x2A }) }
        }
        let store = InMemoryStore()
        server = TokenServer(store: store, cipher: Rot13(), transport: transport)
        try server.activate(.anthropic, key: " sk-live ")
        XCTAssertEqual(try store.keyData(for: .anthropic), Data("sk-live".utf8.map { $0 ^ 0x2A }), "stored as ciphertext, trimmed")
        XCTAssertEqual(try server.key(for: .anthropic), "sk-live")
        XCTAssertTrue(server.isReady)
        XCTAssertEqual(server.model(for: .character)?.id, "claude-opus-5")
        let client = TokenClient(broker: server)
        let session = client.session(consumer: "bush", profile: .character, budget: 1000)
        let (result, deltas) = stream(session)
        let reply = try XCTUnwrap(try result?.get())
        XCTAssertEqual(reply.text, "Ask, and the bush shall sing.")
        XCTAssertEqual(deltas, ["Ask, ", "and the bush shall sing."])
        XCTAssertEqual(reply.usage, Usage(promptTokens: 25, replyTokens: 9))
        XCTAssertEqual(session.spent, 34)
        XCTAssertEqual(session.remaining, 966)
        XCTAssertEqual(transport.requests.last?.headers["x-api-key"], "sk-live")
        let usage = server.usageToday()
        XCTAssertEqual(usage.requests, 1)
        XCTAssertEqual(usage.totalTokens, 34)
        XCTAssertEqual(usage.costMicros, 25 * 5 + 9 * 25)
        let row = server.recentUsage().first!
        XCTAssertEqual(row.consumer, "bush")
        XCTAssertEqual(row.model, "claude-opus-5")
        XCTAssertNil(row.prompt, "prompts are not logged by default")
    }

    func testSessionBudgetAndDailyCap() throws {
        try server.activate(.anthropic, key: "k")
        let client = TokenClient(broker: server)
        let small = client.session(consumer: "bush", profile: .character, budget: 36)
        var (result, _) = stream(small)
        XCTAssertNotNil(try? result?.get())
        XCTAssertEqual(small.remaining, 2, "34 of 36 spent; the next prompt would not fit")
        XCTAssertFalse(small.isExhausted)
        (result, _) = stream(small)
        if case .failure(let e)? = result { XCTAssertEqual(e, .budgetExhausted) } else { XCTFail() }
        XCTAssertNil(server.remainingToday(), "no cap, nothing to count down")
        try server.update { $0.dailyTokenCap = 100 }
        XCTAssertEqual(server.remainingToday(), 66, "34 of 100 spent today")
        try server.update { $0.dailyTokenCap = 20 }
        XCTAssertEqual(server.remainingToday(), 0, "never below zero")
        try server.update { $0.dailyTokenCap = 36 }
        let other = client.session(consumer: "snoopy", profile: .fast)
        (result, _) = stream(other)
        if case .failure(let e)? = result { XCTAssertEqual(e, .dailyCapReached) } else { XCTFail("the day's 34 tokens plus this prompt exceed the cap") }
    }

    func testCreditCountsDownAndSurvivesClearingUsage() throws {
        try server.activate(.anthropic, key: "k")
        XCTAssertNil(server.credit(), "nothing entered yet")
        try server.setCredit(50_000_000, for: .anthropic)
        let session = TokenClient(broker: server).session(consumer: "bush", profile: .character)
        _ = stream(session)
        XCTAssertEqual(server.credit(), Credit(micros: 50_000_000, spentMicros: 350), "25 in at $5 and 9 out at $25 per million")
        XCTAssertEqual(server.credit()?.remainingMicros, 49_999_650)
        try server.store.deleteAll()
        _ = stream(session)
        XCTAssertEqual(server.credit()?.spentMicros, 700, "the count is the credit's own, not the usage log's")
        XCTAssertNil(server.credit(for: .openai), "per provider")
        try server.setCredit(100, for: .anthropic)
        _ = stream(session)
        XCTAssertEqual(server.credit()?.remainingMicros, 0, "never below zero")
        try server.setCredit(nil, for: .anthropic)
        XCTAssertNil(server.credit())
    }

    func testSwitchingProviderAndLoggingPrompts() throws {
        try server.activate(.anthropic, key: "a")
        try server.activate(.openai, key: "o")
        try server.update { $0.logPrompts = true }
        XCTAssertEqual(server.configuredProviders, [.anthropic, .openai])
        XCTAssertEqual(server.model(for: .fast)?.id, "gpt-5-nano")
        let (result, _) = stream(TokenClient(broker: server).session(consumer: "x", profile: .fast), "hello?")
        XCTAssertEqual(try result?.get().text, "Hello there")
        let row = server.recentUsage().first!
        XCTAssertEqual(row.provider, .openai)
        XCTAssertEqual(row.prompt, "hello?")
        XCTAssertEqual(row.reply, "Hello there")
    }

    func testHttpErrorsSurface() throws {
        try server.activate(.anthropic, key: "k")
        transport.responses["api.anthropic.com"] = (401, "{\"error\":{\"message\":\"invalid x-api-key\"}}")
        let (result, _) = stream(TokenClient(broker: server).session(consumer: "x", profile: .character))
        if case .failure(let e)? = result { XCTAssertEqual(e, .http(status: 401, body: "{\"error\":{\"message\":\"invalid x-api-key\"}}")) } else { XCTFail() }
        XCTAssertEqual(server.usageToday().requests, 0, "failed requests are not charged")
    }
}
