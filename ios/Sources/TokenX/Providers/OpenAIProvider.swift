//
//  OpenAIProvider.swift
//  TokenX
//
//  OpenAI chat completions over HTTPS with server-sent events. The same code
//  serves the OpenAI-compatible vendors (DeepSeek, Kimi, Qwen) at their own
//  endpoints, and `.local`: an OpenAI-compatible server (Ollama, LM Studio,
//  vLLM) at a base URL from the settings, with no key.
//

import Foundation

public struct OpenAIProvider: Provider {
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    public static let deepseekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    public static let kimiEndpoint = URL(string: "https://api.moonshot.ai/v1/chat/completions")!
    public static let qwenEndpoint = URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")!

    public let kind: ProviderKind
    public init(kind: ProviderKind = .openai) { self.kind = kind }

    /// The hosted endpoint for a kind; `nil` for `.local`, whose base URL comes from the settings.
    public static func endpoint(for kind: ProviderKind) -> URL? {
        switch kind {
        case .openai: return endpoint
        case .deepseek: return deepseekEndpoint
        case .kimi: return kimiEndpoint
        case .qwen: return qwenEndpoint
        default: return nil
        }
    }

    public func request(_ chat: ChatRequest, call: ProviderCall) throws -> HttpRequest {
        var system = chat.system ?? ""
        let maxTokens = chat.maxTokens ?? call.maxTokens
        var body: [String: Any] = [
            "model": call.model.id,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        // OpenAI and Kimi have retired `max_tokens`; the others still document it.
        body[kind == .openai || kind == .kimi ? "max_completion_tokens" : "max_tokens"] = maxTokens
        // OpenAI's current models reject sampling parameters; Kimi fixes the temperature per model.
        if kind != .openai, kind != .kimi, let t = chat.temperature ?? call.profile.temperature { body["temperature"] = t }
        // The vendors whose models think by default take the profile's effort as a switch: low turns thinking off.
        if let effort = call.profile.effort {
            switch kind {
            case .deepseek:
                body["thinking"] = effort == "low" ? ["type": "disabled"] : ["type": "enabled", "reasoning_effort": effort]
            case .kimi:
                if call.model.id.hasPrefix("kimi-k3") { body["reasoning_effort"] = effort } else { body["thinking"] = ["type": effort == "low" ? "disabled" : "enabled"] }
            case .qwen:
                body["enable_thinking"] = effort != "low"
            default: break
            }
        }
        if let schema = chat.jsonSchema {
            if OpenAIProvider.supportsJSONSchema(kind) {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "schema": schema]]
            } else {
                // JSON mode only: the schema goes in the prompt, which must mention JSON for these APIs to accept the mode.
                body["response_format"] = ["type": "json_object"]
                let text = String(decoding: try JSON.data(schema), as: UTF8.self)
                system += (system.isEmpty ? "" : "\n\n") + "Reply with a single JSON object that matches this JSON schema: " + text
            }
        }
        var messages: [[String: Any]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += chat.messages.map { ["role": $0.role.rawValue, "content": OpenAIProvider.content($0)] }
        body["messages"] = messages
        var headers = ["Content-Type": "application/json", "Accept": "text/event-stream"]
        let url: URL
        if kind == .local {
            guard let base = call.baseURL else { throw TokenXError.transport("no local server URL") }
            url = base.appendingPathComponent("chat/completions")
        } else {
            guard let key = call.key, !key.isEmpty else { throw TokenXError.missingKey(kind) }
            guard let hosted = OpenAIProvider.endpoint(for: kind) else { throw TokenXError.transport("no endpoint for \(kind.rawValue)") }
            headers["Authorization"] = "Bearer \(key)"
            url = hosted
        }
        return HttpRequest(url: url, headers: headers, body: try JSON.data(body))
    }

    /// Whether the vendor enforces a schema (`response_format: json_schema`); the rest get JSON mode and the schema in the prompt.
    static func supportsJSONSchema(_ kind: ProviderKind) -> Bool { kind != .deepseek && kind != .qwen }

    /// A plain string for text-only messages; text and `image_url` data-URI parts otherwise.
    static func content(_ message: ChatMessage) -> Any {
        guard message.parts != nil else { return message.text }
        return message.contentParts.map { part -> [String: Any] in
            switch part {
            case .text(let t): return ["type": "text", "text": t]
            case .image(let data, let mediaType): return ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(data)"]]
            }
        }
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
