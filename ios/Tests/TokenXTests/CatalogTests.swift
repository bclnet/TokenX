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
        XCTAssertEqual(Catalog.model(for: .character, provider: .anthropic).id, "claude-opus-5-5")
        XCTAssertEqual(Catalog.model(for: .fast, provider: .anthropic).id, "claude-haiku-4-5")
        XCTAssertEqual(Catalog.model(for: .fast, provider: .openai).tier, .fast)
        XCTAssertEqual(Catalog.model(id: "gemini-2.5-flash")?.provider, .gemini)
        XCTAssertNil(Catalog.model(id: "nope"))
    }

    func testCostAndProfiles() {
        let opus = Catalog.model(id: "claude-opus-5-5")!
        XCTAssertEqual(opus.costMicros(promptTokens: 1_000_000, replyTokens: 0), 4_000_000)
        XCTAssertEqual(opus.costMicros(promptTokens: 1000, replyTokens: 100), 4000 + 2000)
        XCTAssertEqual(Catalog.model(id: "claude-sonnet-5-5")?.tier, .balanced)
        XCTAssertEqual(Profile.character.effort, "low")
        XCTAssertEqual(Profile.assistant.maxTokens, 4096)
        XCTAssertTrue(Profile.vision.needsVision)
        XCTAssertFalse(ProviderKind.local.needsKey)
    }

    func testChatRequestEstimate() {
        let r = ChatRequest(system: String(repeating: "a", count: 40), messages: [.user(String(repeating: "b", count: 32))])
        XCTAssertEqual(r.estimatedPromptTokens, 20)
        let withImage = ChatRequest(messages: [.user(parts: [.text("look"), .image(data: "AAAA", mediaType: "image/png")])])
        XCTAssertEqual(withImage.messages[0].text, "look", "the text of the parts, for logging and estimates")
        XCTAssertEqual(withImage.messages[0].imageCount, 1)
        XCTAssertGreaterThanOrEqual(withImage.estimatedPromptTokens, 1600, "about 1,600 tokens per image")
    }
}
