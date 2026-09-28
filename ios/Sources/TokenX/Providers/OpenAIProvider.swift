//
//  OpenAIProvider.swift
//  TokenX
//
//  OpenAI chat completions over HTTPS with server-sent events. The same code
//  serves `.local`: an OpenAI-compatible server (Ollama, LM Studio, vLLM) at a
//  base URL from the settings, with no key.
//

import Foundation

public struct OpenAIProvider: Provider {
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public let kind: ProviderKind
    public init(kind: ProviderKind = .openai) { self.kind = kind }

    public func request(_ chat: ChatRequest, call: ProviderCall) throws -> HttpRequest {
        var messages: [[String: Any]] = []
        if let system = chat.system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += chat.messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var body: [String: Any] = [
            "model": call.model.id,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages,
        ]
        if kind == .openai {
            body["max_completion_tokens"] = chat.maxTokens ?? call.maxTokens
        } else {
            body["max_tokens"] = chat.maxTokens ?? call.maxTokens
            if let t = chat.temperature ?? call.profile.temperature { body["temperature"] = t }
        }
        var headers = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        let url: URL
        if kind == .local {
            guard let base = call.baseURL else { throw TokenXError.transport("no local server URL") }
            url = base.appendingPathComponent("chat/completions")
        } else {
            guard let key = call.key, !key.isEmpty else { throw TokenXError.missingKey(.openai) }
            headers["Authorization"] = "Bearer \(key)"
            url = OpenAIProvider.endpoint
        }
        return HttpRequest(url: url, headers: headers, body: try JSON.data(body))
    }

    public func makeParser() -> ProviderStreamParser { Parser() }

    struct Parser: ProviderStreamParser {
        var sse = SSEParser()
        var usage = Usage()
        var stop: StopReason = .end
        var finished = false

        mutating func feed(_ line: String) -> [ChatEvent] {
            guard let event = sse.feed(line) else { return [] }
            if event.data == "[DONE]" {
                finished = true
                return [.done(usage: usage, stop: stop)]
            }
            guard let json = JSON.object(event.data) else { return [] }
            var out: [ChatEvent] = []
            if let u = json["usage"] as? [String: Any] {
                usage = Usage(promptTokens: u["prompt_tokens"] as? Int ?? usage.promptTokens, replyTokens: u["completion_tokens"] as? Int ?? usage.replyTokens)
            }
            for choice in json["choices"] as? [[String: Any]] ?? [] {
                if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty { out.append(.text(text)) }
                if let reason = choice["finish_reason"] as? String {
                    stop = reason == "length" ? .maxTokens : reason == "content_filter" ? .refusal : .end
                }
            }
            return out
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
}
