/*
 * AnthropicProvider.kt
 * TokenX
 *
 * Anthropic Messages API over HTTPS with server-sent events.
 */
package com.bclnet.tokenx.providers

import com.bclnet.tokenx.ChatEvent
import com.bclnet.tokenx.ChatMessage
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
import com.bclnet.tokenx.int
import com.bclnet.tokenx.obj
import com.bclnet.tokenx.str

class AnthropicProvider : Provider {
    override val kind = ProviderKind.ANTHROPIC

    override fun request(chat: ChatRequest, call: ProviderCall): HttpRequest {
        val key = call.key?.takeIf { it.isNotEmpty() } ?: throw TokenXException.MissingKey(ProviderKind.ANTHROPIC)
        val fiveGeneration = call.model.id.startsWith("claude-opus-5") || call.model.id.startsWith("claude-sonnet-5")
        val body = linkedMapOf<String, Any?>(
            "model" to call.model.id,
            "max_tokens" to (chat.maxTokens ?: call.maxTokens),
            "stream" to true,
            "messages" to messages(chat.messages),
        )
        chat.system?.takeIf { it.isNotEmpty() }?.let { body["system"] = it }
        // Sampling parameters are rejected on the 5-generation models; thinking effort takes their place there.
        val temperature = chat.temperature ?: call.profile.temperature
        if (temperature != null && !fiveGeneration) body["temperature"] = temperature
        if (fiveGeneration) call.profile.effort?.let { body["output_config"] = mapOf("effort" to it) }
        return HttpRequest(ENDPOINT, headers = mapOf("Content-Type" to "application/json", "x-api-key" to key, "anthropic-version" to VERSION, "Accept" to "text/event-stream"), body = MiniJson.stringify(body).toByteArray())
    }

    override fun makeParser(): ProviderStreamParser = Parser()

    private class Parser : SseStreamParser() {
        override fun handle(event: SseParser.Event): List<ChatEvent> {
            val json = MiniJson.parse(event.data) ?: return emptyList()
            when (json.str("type")) {
                "message_start" -> json.obj("message").obj("usage")?.int("input_tokens")?.let { usage = usage.copy(promptTokens = it) }
                "content_block_delta" -> {
                    val delta = json.obj("delta")
                    if (delta.str("type") == "text_delta") delta.str("text")?.takeIf { it.isNotEmpty() }?.let { return listOf(ChatEvent.Text(it)) }
                }
                "message_delta" -> {
                    json.obj("usage")?.int("output_tokens")?.let { usage = usage.copy(replyTokens = it) }
                    json.obj("delta").str("stop_reason")?.let { stop = stopReason(it) }
                }
                "message_stop" -> { finished = true; return listOf(ChatEvent.Done(usage, stop)) }
                "error" -> { finished = true; return listOf(ChatEvent.Done(usage, StopReason.OTHER), ChatEvent.Text(json.obj("error").str("message") ?: "error")) }
            }
            return emptyList()
        }
    }

    companion object {
        const val ENDPOINT = "https://api.anthropic.com/v1/messages"
        const val VERSION = "2023-06-01"

        /** Anthropic requires alternating roles starting with `user`; adjacent same-role turns are merged. */
        fun messages(messages: List<ChatMessage>): List<Map<String, Any?>> {
            val out = ArrayList<LinkedHashMap<String, Any?>>()
            for (m in messages) {
                val role = m.role.id
                val last = out.lastOrNull()
                if (last != null && last["role"] == role) last["content"] = (last["content"] as String) + "\n" + m.text
                else out += linkedMapOf("role" to role, "content" to m.text)
            }
            if (out.firstOrNull()?.get("role") != "user") out.add(0, linkedMapOf("role" to "user", "content" to "(start)"))
            return out
        }

        fun stopReason(reason: String): StopReason = when (reason) {
            "end_turn", "stop_sequence" -> StopReason.END
            "max_tokens" -> StopReason.MAX_TOKENS
            "refusal" -> StopReason.REFUSAL
            else -> StopReason.OTHER
        }
    }
}
