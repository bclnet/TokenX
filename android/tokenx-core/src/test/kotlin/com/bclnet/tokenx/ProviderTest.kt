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
        val request = provider.request(chat, ProviderCall(Catalog.model("claude-opus-5-5")!!, "sk-test", profile = Profile.CHARACTER))
        assertEquals(AnthropicProvider.ENDPOINT, request.url)
        assertEquals("sk-test", request.headers["x-api-key"])
        assertEquals("server-side-fallback-2026-07-01", request.headers["anthropic-beta"])
        val body = request.bodyJson!!
        assertEquals("claude-opus-5-5", body["model"])
        assertEquals("default", body["fallbacks"])
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
        val haikuRequest = provider.request(chat, ProviderCall(Catalog.model("claude-haiku-4-5")!!, "k", profile = Profile.CHARACTER))
        val haiku = haikuRequest.bodyJson!!
        assertEquals(0.9, haiku["temperature"])
        assertNull(haiku["output_config"])
        assertNull(haiku["fallbacks"])
        assertNull(haikuRequest.headers["anthropic-beta"])
        val sonnet = provider.request(chat, ProviderCall(Catalog.model("claude-sonnet-5-5")!!, "k", profile = Profile.ASSISTANT))
        assertEquals("server-side-fallback-2026-07-01", sonnet.headers["anthropic-beta"])
        assertEquals("default", sonnet.bodyJson!!["fallbacks"])
        try { provider.request(chat, ProviderCall(Catalog.model("claude-opus-5-5")!!, null, profile = Profile.FAST)); fail() } catch (e: TokenXException.MissingKey) {}
    }

    @Test fun anthropicImagePartsAndJsonSchema() {
        val provider = AnthropicProvider()
        val schema = mapOf("type" to "object", "properties" to mapOf("ok" to mapOf("type" to "boolean")), "required" to listOf("ok"), "additionalProperties" to false)
        val request = provider.request(
            ChatRequest(messages = listOf(ChatMessage.user(listOf(ChatPart.Text("Photo 1"), ChatPart.Image("AAAA", "image/jpeg"), ChatPart.Text("Compare.")))), maxTokens = 8000, jsonSchema = schema),
            ProviderCall(Catalog.model("claude-opus-5-5")!!, "k", profile = Profile.VISION),
        )
        val body = request.bodyJson!!
        assertEquals(8000, body.int("max_tokens"))
        val content = body.list("messages")!!.first().list("content")!!
        assertEquals(listOf("text", "image", "text"), content.map { it.str("type") })
        assertEquals("base64", content[1].obj("source").str("type"))
        assertEquals("image/jpeg", content[1].obj("source").str("media_type"))
        assertEquals("AAAA", content[1].obj("source").str("data"))
        assertEquals("high", body.obj("output_config").str("effort"))
        assertEquals("json_schema", body.obj("output_config").obj("format").str("type"))
        assertEquals(listOf("ok"), body.obj("output_config").obj("format").obj("schema").list("required"))
        val merged = AnthropicProvider.messages(listOf(ChatMessage.user("first"), ChatMessage.user(listOf(ChatPart.Image("BBBB", "image/png")))))
        assertEquals(1, merged.size)
        assertEquals(listOf("text", "image"), merged[0].list("content")!!.map { it.str("type") })
    }

    @Test fun anthropicReportsRefusalStop() {
        val (text, done) = collect(AnthropicProvider(), Canned.anthropicRefusal)
        assertEquals(StopReason.REFUSAL, done?.stop)
        assertEquals("", text)
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

    @Test fun openAIImagePartsAndJsonSchema() {
        val provider = OpenAIProvider()
        val request = provider.request(
            ChatRequest(messages = listOf(ChatMessage.user(listOf(ChatPart.Text("What is this?"), ChatPart.Image("AAAA", "image/png")))), jsonSchema = mapOf("type" to "object")),
            ProviderCall(Catalog.model("gpt-5")!!, "k", profile = Profile.VISION),
        )
        val body = request.bodyJson!!
        val content = body.list("messages")!!.first().list("content")!!
        assertEquals(listOf("text", "image_url"), content.map { it.str("type") })
        assertEquals("data:image/png;base64,AAAA", content[1].obj("image_url").str("url"))
        assertEquals("json_schema", body.obj("response_format").str("type"))
        assertEquals("reply", body.obj("response_format").obj("json_schema").str("name"))
        assertEquals("object", body.obj("response_format").obj("json_schema").obj("schema").str("type"))
        val plain = provider.request(chat, ProviderCall(Catalog.model("gpt-5")!!, "k", profile = Profile.FAST)).bodyJson!!
        assertEquals("hello", plain.list("messages")!![1].str("content"))
        assertNull(plain["response_format"])
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

    @Test fun geminiImagePartsAndJsonSchema() {
        val provider = GeminiProvider()
        val request = provider.request(
            ChatRequest(messages = listOf(ChatMessage.user(listOf(ChatPart.Text("What is this?"), ChatPart.Image("AAAA", "image/webp")))), jsonSchema = mapOf("type" to "object")),
            ProviderCall(Catalog.model("gemini-2.5-pro")!!, "g", profile = Profile.VISION),
        )
        val body = request.bodyJson!!
        val parts = body.list("contents")!!.first().list("parts")!!
        assertEquals("What is this?", parts[0].str("text"))
        assertEquals("image/webp", parts[1].obj("inlineData").str("mimeType"))
        assertEquals("AAAA", parts[1].obj("inlineData").str("data"))
        assertEquals("application/json", body.obj("generationConfig").str("responseMimeType"))
        val plain = provider.request(chat, ProviderCall(Catalog.model("gemini-2.5-pro")!!, "g", profile = Profile.FAST)).bodyJson!!
        assertNull(plain.obj("generationConfig").str("responseMimeType"))
    }
}
