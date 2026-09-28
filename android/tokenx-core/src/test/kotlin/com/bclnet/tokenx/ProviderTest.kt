package com.bclnet.tokenx

import com.bclnet.tokenx.providers.AnthropicProvider
import com.bclnet.tokenx.providers.GeminiProvider
import com.bclnet.tokenx.providers.OpenAIProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ProviderTest {
    private val chat = ChatRequest(system = "You are a bush.", messages = listOf(ChatMessage.user("hello"), ChatMessage.assistant("hi"), ChatMessage.user("sing")))

    private fun collect(provider: Provider, body: String): Pair<String, ChatEvent.Done?> {
        val parser = provider.makeParser()
        val text = StringBuilder()
        var done: ChatEvent.Done? = null
        val lines = body.split("\n").let { if (it.last().isEmpty()) it.dropLast(1) else it }
        fun take(events: List<ChatEvent>) = events.forEach { if (it is ChatEvent.Text) text.append(it.text) else if (it is ChatEvent.Done) done = it }
        for (line in lines) take(parser.feed(line))
        take(parser.finish())
        return text.toString() to done
    }

    @Test fun anthropicRequestAndStream() {
        val provider = AnthropicProvider()
        val request = provider.request(chat, ProviderCall(Catalog.model("claude-opus-5")!!, "sk-test", profile = Profile.CHARACTER))
        assertEquals(AnthropicProvider.ENDPOINT, request.url)
        assertEquals("sk-test", request.headers["x-api-key"])
        val body = request.bodyJson!!
        assertEquals("claude-opus-5", body["model"])
        assertEquals(400, body.int("max_tokens"))
        assertEquals(true, body["stream"])
        assertEquals("You are a bush.", body["system"])
        assertEquals("low", body.obj("output_config").str("effort"))
        assertNull(body["temperature"])
        assertEquals(listOf("user", "assistant", "user"), body.list("messages")!!.map { it.str("role") })
        val (text, done) = collect(provider, Canned.anthropic)
        assertEquals("Ask, and the bush shall sing.", text)
        assertEquals(Usage(25, 9), done?.usage)
        assertEquals(StopReason.END, done?.stop)
        val haiku = provider.request(chat, ProviderCall(Catalog.model("claude-haiku-4-5")!!, "k", profile = Profile.CHARACTER)).bodyJson!!
        assertEquals(0.9, haiku["temperature"])
        assertNull(haiku["output_config"])
        try { provider.request(chat, ProviderCall(Catalog.model("claude-opus-5")!!, null, profile = Profile.FAST)); fail() } catch (e: TokenXException.MissingKey) {}
    }

    @Test fun anthropicMergesAdjacentRoles() {
        val merged = AnthropicProvider.messages(listOf(ChatMessage.assistant("a"), ChatMessage.user("b"), ChatMessage.user("c")))
        assertEquals(listOf("user", "assistant", "user"), merged.map { it["role"] })
        assertEquals("b\nc", merged[2]["content"])
    }

    @Test fun openAIRequestAndStream() {
        val provider = OpenAIProvider()
        val request = provider.request(chat, ProviderCall(Catalog.model("gpt-5-mini")!!, "sk-o", profile = Profile.FAST))
        assertEquals("Bearer sk-o", request.headers["Authorization"])
        val body = request.bodyJson!!
        assertEquals(1024, body.int("max_completion_tokens"))
        assertEquals(true, body.obj("stream_options")?.get("include_usage"))
        assertEquals("system", body.list("messages")!!.first().str("role"))
        assertEquals(4, body.list("messages")!!.size)
        val (text, done) = collect(provider, Canned.openai)
        assertEquals("Hello there", text)
        assertEquals(Usage(12, 2), done?.usage)
    }

    @Test fun localServerUsesBaseUrlAndNoKey() {
        val provider = OpenAIProvider(ProviderKind.LOCAL)
        val model = Catalog.local[0].copy(id = "llama3")
        val request = provider.request(chat, ProviderCall(model, null, "http://192.168.1.20:11434/v1", Profile.CHARACTER))
        assertEquals("http://192.168.1.20:11434/v1/chat/completions", request.url)
        assertNull(request.headers["Authorization"])
        assertEquals("llama3", request.bodyJson!!["model"])
        assertEquals(0.9, request.bodyJson!!["temperature"])
        try { provider.request(chat, ProviderCall(model, null, null, Profile.CHARACTER)); fail() } catch (e: TokenXException.Transport) {}
    }

    @Test fun geminiRequestAndStream() {
        val provider = GeminiProvider()
        val request = provider.request(chat, ProviderCall(Catalog.model("gemini-2.5-flash")!!, "g", profile = Profile.ASSISTANT))
        assertTrue(request.url.endsWith("gemini-2.5-flash:streamGenerateContent?alt=sse"))
        assertEquals("g", request.headers["x-goog-api-key"])
        val body = request.bodyJson!!
        assertEquals(listOf("user", "model", "user"), body.list("contents")!!.map { it.str("role") })
        assertNotNull(body["systemInstruction"])
        val (text, done) = collect(provider, Canned.gemini)
        assertEquals("Woof.", text)
        assertEquals(Usage(7, 2), done?.usage)
        assertEquals(StopReason.END, done?.stop)
    }
}
