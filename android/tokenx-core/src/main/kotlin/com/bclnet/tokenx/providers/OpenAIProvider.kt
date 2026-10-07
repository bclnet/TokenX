/*
 * OpenAIProvider.kt
 * TokenX
 *
 * OpenAI chat completions over HTTPS with server-sent events. The same code
 * serves the OpenAI-compatible vendors (DeepSeek, Kimi, Qwen) at their own
 * endpoints, and LOCAL: an OpenAI-compatible server (Ollama, LM Studio, vLLM)
 * at a base URL from the settings, with no key.
 */
package com.bclnet.tokenx.providers

import com.bclnet.tokenx.ChatEvent
import com.bclnet.tokenx.ChatMessage
import com.bclnet.tokenx.ChatPart
import com.bclnet.tokenx.ChatRequest
import com.bclnet.tokenx.HttpRequest
import com.bclnet.tokenx.MiniJson
import com.bclnet.tokenx.Provider
import com.bclnet.tokenx.ProviderCall
import com.bclnet.tokenx.ProviderKind
import com.bclnet.tokenx.ProviderStreamParser
import com.bclnet.tokenx.SseParser
import com.bclnet.tokenx.SseStreamParser
import com.bclnet.tokenx.StopReason
import com.bclnet.tokenx.TokenXException
import com.bclnet.tokenx.Usage
import com.bclnet.tokenx.int
import com.bclnet.tokenx.list
import com.bclnet.tokenx.obj
import com.bclnet.tokenx.str

class OpenAIProvider(override val kind: ProviderKind = ProviderKind.OPENAI) : Provider {
    override fun request(chat: ChatRequest, call: ProviderCall): HttpRequest {
        var system = chat.system ?: ""
        val maxTokens = chat.maxTokens ?: call.maxTokens
        val body = linkedMapOf<String, Any?>("model" to call.model.id, "stream" to true, "stream_options" to mapOf("include_usage" to true))
        // OpenAI and Kimi have retired `max_tokens`; the others still document it.
        body[if (kind == ProviderKind.OPENAI || kind == ProviderKind.KIMI) "max_completion_tokens" else "max_tokens"] = maxTokens
        // OpenAI's current models reject sampling parameters; Kimi fixes the temperature per model.
        if (kind != ProviderKind.OPENAI && kind != ProviderKind.KIMI) (chat.temperature ?: call.profile.temperature)?.let { body["temperature"] = it }
        // The vendors whose models think by default take the profile's effort as a switch: low turns thinking off.
        val effort = call.profile.effort
        if (effort != null) {
            when (kind) {
                ProviderKind.DEEPSEEK -> {
                    body["thinking"] = if (effort == "low") mapOf("type" to "disabled") else mapOf("type" to "enabled", "reasoning_effort" to effort)
                }
                ProviderKind.KIMI -> {
                    if (call.model.id.startsWith("kimi-k3")) body["reasoning_effort"] = effort
                    else body["thinking"] = mapOf("type" to (if (effort == "low") "disabled" else "enabled"))
                }
                ProviderKind.QWEN -> {
                    body["enable_thinking"] = effort != "low"
                }
                else -> {}
            }
        }
        chat.jsonSchema?.let { schema ->
            if (supportsJsonSchema(kind)) {
                body["response_format"] = mapOf("type" to "json_schema", "json_schema" to mapOf("name" to "reply", "schema" to schema))
            } else {
                // JSON mode only: the schema goes in the prompt, which must mention JSON for these APIs to accept the mode.
                body["response_format"] = mapOf("type" to "json_object")
                system += (if (system.isEmpty()) "" else "\n\n") + "Reply with a single JSON object that matches this JSON schema: " + MiniJson.stringify(schema)
            }
        }
        val messages = ArrayList<Map<String, Any?>>()
        if (system.isNotEmpty()) messages += mapOf("role" to "system", "content" to system)
        messages += chat.messages.map { mapOf("role" to it.role.id, "content" to content(it)) }
        body["messages"] = messages
        val headers = linkedMapOf("Content-Type" to "application/json", "Accept" to "text/event-stream")
        val url = if (kind == ProviderKind.LOCAL) {
            (call.baseUrl ?: throw TokenXException.Transport("no local server URL")).trimEnd('/') + "/chat/completions"
        } else {
            val key = call.key?.takeIf { it.isNotEmpty() } ?: throw TokenXException.MissingKey(kind)
            headers["Authorization"] = "Bearer $key"
            endpoint(kind) ?: throw TokenXException.Transport("no endpoint for ${kind.id}")
        }
        return HttpRequest(url, headers = headers, body = MiniJson.stringify(body).toByteArray())
    }

    override fun makeParser(): ProviderStreamParser = Parser()

    private class Parser : SseStreamParser() {
        override fun handle(event: SseParser.Event): List<ChatEvent> {
            if (event.data == "[DONE]") { finished = true; return listOf(ChatEvent.Done(usage, stop)) }
            val json = MiniJson.parse(event.data) ?: return emptyList()
            val out = ArrayList<ChatEvent>()
            json.obj("usage")?.let { usage = Usage(it.int("prompt_tokens") ?: usage.promptTokens, it.int("completion_tokens") ?: usage.replyTokens) }
            for (choice in json.list("choices") ?: emptyList()) {
                choice.obj("delta").str("content")?.takeIf { it.isNotEmpty() }?.let { out += ChatEvent.Text(it) }
                choice.str("finish_reason")?.let { stop = when (it) { "length" -> StopReason.MAX_TOKENS; "content_filter" -> StopReason.REFUSAL; else -> StopReason.END } }
            }
            return out
        }
    }

    companion object {
        const val ENDPOINT = "https://api.openai.com/v1/chat/completions"
        const val DEEPSEEK_ENDPOINT = "https://api.deepseek.com/chat/completions"
        const val KIMI_ENDPOINT = "https://api.moonshot.ai/v1/chat/completions"
        const val QWEN_ENDPOINT = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"

        /** The hosted endpoint for a kind; `null` for LOCAL, whose base URL comes from the settings. */
        fun endpoint(kind: ProviderKind): String? = when (kind) {
            ProviderKind.OPENAI -> ENDPOINT
            ProviderKind.DEEPSEEK -> DEEPSEEK_ENDPOINT
            ProviderKind.KIMI -> KIMI_ENDPOINT
            ProviderKind.QWEN -> QWEN_ENDPOINT
            else -> null
        }

        /** Whether the vendor enforces a schema (`response_format: json_schema`); the rest get JSON mode and the schema in the prompt. */
        fun supportsJsonSchema(kind: ProviderKind) = kind != ProviderKind.DEEPSEEK && kind != ProviderKind.QWEN

        /** A plain string for text-only messages; text and `image_url` data-URI parts otherwise. */
        fun content(message: ChatMessage): Any = if (message.parts == null) message.text else message.contentParts.map { part ->
            when (part) {
                is ChatPart.Text -> mapOf("type" to "text", "text" to part.text)
                is ChatPart.Image -> mapOf("type" to "image_url", "image_url" to mapOf("url" to "data:${part.mediaType};base64,${part.data}"))
            }
        }
    }
}
