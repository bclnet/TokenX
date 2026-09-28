//
//  AnthropicProvider.swift
//  TokenX
//
//  Anthropic Messages API over HTTPS with server-sent events.
//

import Foundation

public struct AnthropicProvider: Provider {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let version = "2023-06-01"

    public var kind: ProviderKind { .anthropic }
    public init() {}

    public func request(_ chat: ChatRequest, call: ProviderCall) throws -> HttpRequest {
        guard let key = call.key, !key.isEmpty else { throw TokenXError.missingKey(.anthropic) }
        var body: [String: Any] = [
            "model": call.model.id,
            "max_tokens": chat.maxTokens ?? call.maxTokens,
            "stream": true,
            "messages": AnthropicProvider.messages(chat.messages),
        ]
        if let system = chat.system, !system.isEmpty { body["system"] = system }
        if let t = chat.temperature ?? call.profile.temperature, !call.model.id.hasPrefix("claude-opus-5"), !call.model.id.hasPrefix("claude-sonnet-5") {
            // Sampling parameters are rejected on the 5-generation models; thinking effort takes their place there.
            body["temperature"] = t
        }
        if let effort = call.profile.effort, call.model.id.hasPrefix("claude-opus-5") || call.model.id.hasPrefix("claude-sonnet-5") {
            body["output_config"] = ["effort": effort]
        }
        return HttpRequest(url: AnthropicProvider.endpoint, headers: [
            "Content-Type": "application/json",
            "x-api-key": key,
            "anthropic-version": AnthropicProvider.version,
            "Accept": "text/event-stream",
        ], body: try JSON.data(body))
    }

    /// Anthropic requires alternating roles starting with `user`; adjacent same-role turns are merged.
    static func messages(_ messages: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            let role = m.role.rawValue
            if let last = out.last, last["role"] as? String == role, let text = last["content"] as? String {
                out[out.count - 1]["content"] = text + "\n" + m.text
            } else {
                out.append(["role": role, "content": m.text])
            }
        }
        if out.first?["role"] as? String != "user" { out.insert(["role": "user", "content": "(start)"], at: 0) }
        return out
    }

    public func makeParser() -> ProviderStreamParser { Parser() }

    struct Parser: ProviderStreamParser {
        var sse = SSEParser()
        var usage = Usage()
        var stop: StopReason = .end
        var finished = false

        mutating func feed(_ line: String) -> [ChatEvent] {
            guard let event = sse.feed(line), let json = JSON.object(event.data) else { return [] }
            switch json["type"] as? String {
            case "message_start":
                if let u = (json["message"] as? [String: Any])?["usage"] as? [String: Any] { usage.promptTokens = u["input_tokens"] as? Int ?? 0 }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String, !text.isEmpty { return [.text(text)] }
            case "message_delta":
                if let u = json["usage"] as? [String: Any], let out = u["output_tokens"] as? Int { usage.replyTokens = out }
                if let reason = (json["delta"] as? [String: Any])?["stop_reason"] as? String { stop = AnthropicProvider.stop(reason) }
            case "message_stop":
                finished = true
                return [.done(usage: usage, stop: stop)]
            case "error":
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? "error"
                finished = true
                return [.text(""), .done(usage: usage, stop: .other), .text(message)]
            default: break
            }
            return []
        }

        mutating func finish() -> [ChatEvent] {
            // A body that ends without a blank line still holds its last event.
            var out = feed("")
            guard !finished else { return out }
            finished = true
            out.append(.done(usage: usage, stop: stop))
            return out
        }
    }

    static func stop(_ reason: String) -> StopReason {
        switch reason {
        case "end_turn", "stop_sequence": return .end
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        default: return .other
        }
    }
}
