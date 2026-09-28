/*
 * Chat.kt
 * TokenX
 *
 * The request and the streamed reply, in TokenX's own terms. Providers
 * translate these to their wire formats; consumers never see a provider.
 */
package com.bclnet.tokenx

data class ChatMessage(val role: Role, val text: String) {
    enum class Role(val id: String) { USER("user"), ASSISTANT("assistant") }
    companion object {
        fun user(text: String) = ChatMessage(Role.USER, text)
        fun assistant(text: String) = ChatMessage(Role.ASSISTANT, text)
    }
}

data class ChatRequest(
    val system: String? = null,
    val messages: List<ChatMessage>,
    /** Overrides the profile's defaults when set. */
    val maxTokens: Int? = null,
    val temperature: Double? = null,
) {
    /** Roughly four characters per token; used before a request to check budgets. */
    val estimatedPromptTokens: Int
        get() {
            val chars = (system?.toByteArray(Charsets.UTF_8)?.size ?: 0) + messages.sumOf { it.text.toByteArray(Charsets.UTF_8).size + 8 }
            return (chars + 3) / 4
        }
}

data class Usage(val promptTokens: Int = 0, val replyTokens: Int = 0) {
    val total: Int get() = promptTokens + replyTokens
}

enum class StopReason(val id: String) {
    END("end"), MAX_TOKENS("maxTokens"), REFUSAL("refusal"), OTHER("other");
    companion object { fun of(id: String?): StopReason = entries.firstOrNull { it.id == id } ?: OTHER }
}

/** What a provider emits while a reply streams. */
sealed class ChatEvent {
    data class Text(val text: String) : ChatEvent()
    data class Done(val usage: Usage, val stop: StopReason) : ChatEvent()
}

data class ChatReply(val text: String, val usage: Usage, val stop: StopReason)

sealed class TokenXException(message: String) : Exception(message) {
    object NoProvider : TokenXException("no AI provider is configured")
    data class MissingKey(val provider: ProviderKind) : TokenXException("no API key for ${provider.displayName}")
    object BudgetExhausted : TokenXException("the session's token budget is spent")
    object DailyCapReached : TokenXException("the daily token cap is reached")
    data class Http(val status: Int, val body: String) : TokenXException("HTTP $status: ${body.take(200)}")
    data class Transport(val reason: String) : TokenXException("transport: $reason")
    data class Malformed(val reason: String) : TokenXException("malformed reply: $reason")
    object Cancelled : TokenXException("cancelled")
}
