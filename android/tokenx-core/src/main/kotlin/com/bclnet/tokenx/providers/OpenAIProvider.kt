/*
 * OpenAIProvider.kt
 * TokenX
 *
 * OpenAI chat completions over HTTPS with server-sent events. The same code
 * serves LOCAL: an OpenAI-compatible server (Ollama, LM Studio, vLLM) at a
 * base URL from the settings, with no key.
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
        val messages = ArrayList<Map<String, Any?>>()
        chat.system?.takeIf { it.isNotEmpty() }?.let { messages += mapOf("role" to "system", "content" to it) }
        messages += chat.messages.map { mapOf("role" to it.role.id, "content" to content(it)) }
        val body = linkedMapOf<String, Any?>("model" to call.model.id, "stream" to true, "stream_options" to mapOf("include_usage" to true), "messages" to messages)
        if (kind == ProviderKind.OPENAI) {
            body["max_completion_tokens"] = chat.maxTokens ?: call.maxTokens
        } else {
            body["max_tokens"] = chat.maxTokens ?: call.maxTokens
            (chat.temperature ?: call.profile.temperature)?.let { body["temperature"] = it }
        }
        chat.jsonSchema?.let { body["response_format"] = mapOf("type" to "json_schema", "json_schema" to mapOf("name" to "reply", "schema" to it)) }
        val headers = linkedMapOf("Content-Type" to "application/json", "Accept" to "text/event-stream")
        val url = if (kind == ProviderKind.LOCAL) {
            (call.baseUrl ?: throw TokenXException.Transport("no local server URL")).trimEnd('/') + "/chat/completions"
        } else {
            val key = call.key?.takeIf { it.isNotEmpty() } ?: throw TokenXException.MissingKey(ProviderKind.OPENAI)
            headers["Authorization"] = "Bearer $key"
            ENDPOINT
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

        /** A plain string for text-only messages; text and `image_url` data-URI parts otherwise. */
        fun content(message: ChatMessage): Any = if (message.parts == null) message.text else message.contentParts.map { part ->
            when (part) {
                is ChatPart.Text -> mapOf("type" to "text", "text" to part.text)
                is ChatPart.Image -> mapOf("type" to "image_url", "image_url" to mapOf("url" to "data:${part.mediaType};base64,${part.data}"))
            }
        }
    }
}
