import XCTest
@testable import TokenX

final class CatalogTests: XCTestCase {
    func testEveryProviderHasEveryTierOrFallsBack() {
        for provider in ProviderKind.allCases {
            for profile in Profile.allCases {
                let model = Catalog.model(for: profile, provider: provider)
                XCTAssertEqual(model.provider, provider)
                if provider == .local { XCTAssertFalse(model.vision) }
            }
        }
        XCTAssertEqual(Catalog.model(for: .character, provider: .anthropic).id, "claude-opus-5")
        XCTAssertEqual(Catalog.model(for: .fast, provider: .anthropic).id, "claude-haiku-4-5")
        XCTAssertEqual(Catalog.model(for: .fast, provider: .openai).tier, .fast)
        XCTAssertEqual(Catalog.model(id: "gemini-2.5-flash")?.provider, .gemini)
        XCTAssertNil(Catalog.model(id: "nope"))
    }

    func testCostAndProfiles() {
        let opus = Catalog.model(id: "claude-opus-5")!
        XCTAssertEqual(opus.costMicros(promptTokens: 1_000_000, replyTokens: 0), 5_000_000)
        XCTAssertEqual(opus.costMicros(promptTokens: 1000, replyTokens: 100), 5000 + 2500)
        XCTAssertEqual(Profile.character.effort, "low")
        XCTAssertEqual(Profile.assistant.maxTokens, 4096)
        XCTAssertTrue(Profile.vision.needsVision)
        XCTAssertFalse(ProviderKind.local.needsKey)
    }

    func testChatRequestEstimate() {
        let r = ChatRequest(system: String(repeating: "a", count: 40), messages: [.user(String(repeating: "b", count: 32))])
        XCTAssertEqual(r.estimatedPromptTokens, 20)
    }
}
