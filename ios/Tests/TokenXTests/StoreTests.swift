import XCTest
@testable import TokenX

final class StoreTests: XCTestCase {
    func stores() throws -> [(String, TokenStore)] {
        let path = NSTemporaryDirectory() + "tokenx-\(UUID().uuidString).sqlite"
        return [("memory", InMemoryStore()), ("sqlite", try SQLiteStore(path: path))]
    }

    func testKeysSettingsAndUsage() throws {
        for (name, store) in try stores() {
            XCTAssertNil(try store.keyData(for: .anthropic), name)
            try store.setKeyData(Data("secret".utf8), for: .anthropic)
            try store.setKeyData(Data("other".utf8), for: .openai)
            XCTAssertEqual(try store.keyData(for: .anthropic), Data("secret".utf8), name)
            XCTAssertEqual(try store.providersWithKeys(), [.anthropic, .openai], name)
            try store.setKeyData(Data("rotated".utf8), for: .anthropic)
            XCTAssertEqual(try store.keyData(for: .anthropic), Data("rotated".utf8), name)
            try store.setKeyData(nil, for: .openai)
            XCTAssertEqual(try store.providersWithKeys(), [.anthropic], name)

            XCTAssertEqual(try store.settings(), Settings(), name)
            let s = Settings(activeProvider: .local, localBaseURL: "http://h:1/v1", localModel: "llama3", dailyTokenCap: 5000, logPrompts: true)
            try store.save(s)
            XCTAssertEqual(try store.settings(), s, name)
            try store.save(Settings(activeProvider: .anthropic))
            XCTAssertEqual(try store.settings().dailyTokenCap, nil, name)

            let old = Date(timeIntervalSinceNow: -86400 * 2)
            try store.record(UsageRecord(at: old, consumer: "bush", profile: .character, provider: .anthropic, model: "m", promptTokens: 100, replyTokens: 10, costMicros: 750, stop: .end))
            let r = try store.record(UsageRecord(consumer: "bush", profile: .character, provider: .anthropic, model: "m", promptTokens: 50, replyTokens: 5, costMicros: 375, stop: .end, prompt: "p", reply: "r"))
            try store.record(UsageRecord(consumer: "snoopy", profile: .fast, provider: .openai, model: "n", promptTokens: 1, replyTokens: 1, costMicros: 1, stop: .maxTokens))
            XCTAssertNotNil(r.id, name)
            let all = try store.totals(since: Date(timeIntervalSinceNow: -86400 * 3), consumer: nil)
            XCTAssertEqual(all, UsageTotals(requests: 3, promptTokens: 151, replyTokens: 16, costMicros: 1126), name)
            let today = try store.totals(since: Date(timeIntervalSinceNow: -3600), consumer: "bush")
            XCTAssertEqual(today, UsageTotals(requests: 1, promptTokens: 50, replyTokens: 5, costMicros: 375), name)
            let recent = try store.recent(limit: 2, consumer: nil)
            XCTAssertEqual(recent.map(\.consumer), ["snoopy", "bush"], name)
            XCTAssertEqual(recent[1].reply, "r", name)
            XCTAssertEqual(recent[0].stop, .maxTokens, name)
            try store.deleteAll()
            XCTAssertEqual(try store.recent(limit: 5, consumer: nil).count, 0, name)
        }
    }
}
