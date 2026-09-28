//
//  Chat.swift
//  TokenX
//
//  The request and the streamed reply, in TokenX's own terms. Providers
//  translate these to their wire formats; consumers never see a provider.
//

import Foundation

public struct ChatMessage: Equatable, Codable {
    public enum Role: String, Codable { case user, assistant }
    public var role: Role
    public var text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, text: text) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, text: text) }
}

public struct ChatRequest: Equatable {
    public var system: String?
    public var messages: [ChatMessage]
    /// Overrides the profile's defaults when set.
    public var maxTokens: Int?
    public var temperature: Double?

    public init(system: String? = nil, messages: [ChatMessage], maxTokens: Int? = nil, temperature: Double? = nil) {
        self.system = system; self.messages = messages; self.maxTokens = maxTokens; self.temperature = temperature
    }

    /// Roughly four characters per token; used before a request to check budgets.
    public var estimatedPromptTokens: Int {
        let chars = (system?.utf8.count ?? 0) + messages.reduce(0) { $0 + $1.text.utf8.count + 8 }
        return (chars + 3) / 4
    }
}

public struct Usage: Equatable, Codable {
    public var promptTokens: Int
    public var replyTokens: Int
    public init(promptTokens: Int = 0, replyTokens: Int = 0) { self.promptTokens = promptTokens; self.replyTokens = replyTokens }
    public var total: Int { promptTokens + replyTokens }
}

public enum StopReason: String, Codable {
    case end, maxTokens, refusal, other
}

/// What a provider emits while a reply streams.
public enum ChatEvent: Equatable {
    case text(String)
    case done(usage: Usage, stop: StopReason)
}

public struct ChatReply: Equatable {
    public var text: String
    public var usage: Usage
    public var stop: StopReason
    public init(text: String, usage: Usage, stop: StopReason) { self.text = text; self.usage = usage; self.stop = stop }
}

public enum TokenXError: Error, Equatable, CustomStringConvertible {
    case noProvider
    case missingKey(ProviderKind)
    case budgetExhausted
    case dailyCapReached
    case http(status: Int, body: String)
    case transport(String)
    case malformed(String)
    case cancelled

    public var description: String {
        switch self {
        case .noProvider: return "no AI provider is configured"
        case .missingKey(let p): return "no API key for \(p.displayName)"
        case .budgetExhausted: return "the session's token budget is spent"
        case .dailyCapReached: return "the daily token cap is reached"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .transport(let m): return "transport: \(m)"
        case .malformed(let m): return "malformed reply: \(m)"
        case .cancelled: return "cancelled"
        }
    }
}
