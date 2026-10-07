/*
 * GeminiProvider.kt
 * TokenX
 *
 * Google Gemini generateContent over HTTPS with server-sent events.
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

class GeminiProvider : Provider {
    override val kind = ProviderKind.GEMINI

    override fun request(chat: ChatRequest, call: ProviderCall): HttpRequest {
        val key = call.key?.takeIf { it.isNotEmpty() } ?: throw TokenXException.MissingKey(ProviderKind.GEMINI)
        val body = linkedMapOf<String, Any?>(
            "contents" to chat.messages.map { mapOf("role" to (if (it.role == ChatMessage.Role.USER) "user" else "model"), "parts" to parts(it)) },
        )
        chat.system?.takeIf { it.isNotEmpty() }?.let { body["systemInstruction"] = mapOf("parts" to listOf(mapOf("text" to it))) }
        val config = linkedMapOf<String, Any?>("maxOutputTokens" to (chat.maxTokens ?: call.maxTokens))
        (chat.temperature ?: call.profile.temperature)?.let { config["temperature"] = it }
        if (chat.jsonSchema != null) config["responseMimeType"] = "application/json"
        body["generationConfig"] = config
        return HttpRequest("$BASE${call.model.id}:streamGenerateContent?alt=sse", headers = mapOf("Content-Type" to "application/json", "x-goog-api-key" to key, "Accept" to "text/event-stream"), body = MiniJson.stringify(body).toByteArray())
    }

    override fun makeParser(): ProviderStreamParser = Parser()

    private class Parser : SseStreamParser() {
        override fun handle(event: SseParser.Event): List<ChatEvent> {
            val json = MiniJson.parse(event.data) ?: return emptyList()
            val out = ArrayList<ChatEvent>()
            json.obj("usageMetadata")?.let { usage = Usage(it.int("promptTokenCount") ?: usage.promptTokens, it.int("candidatesTokenCount") ?: usage.replyTokens) }
            for (candidate in json.list("candidates") ?: emptyList()) {
                for (part in candidate.obj("content").list("parts") ?: emptyList()) part.str("text")?.takeIf { it.isNotEmpty() }?.let { out += ChatEvent.Text(it) }
                candidate.str("finishReason")?.let { stop = when (it) { "MAX_TOKENS" -> StopReason.MAX_TOKENS; "SAFETY" -> StopReason.REFUSAL; else -> StopReason.END } }
            }
            return out
        }
    }

    companion object {
        const val BASE = "https://generativelanguage.googleapis.com/v1beta/models/"

        /** Text parts and `inlineData` image parts. */
        fun parts(message: ChatMessage): List<Map<String, Any?>> = message.contentParts.map { part ->
            when (part) {
                is ChatPart.Text -> mapOf("text" to part.text)
                is ChatPart.Image -> mapOf("inlineData" to mapOf("mimeType" to part.mediaType, "data" to part.data))
            }
        }
    }
}
