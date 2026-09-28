/*
 * TokenServer.kt
 * TokenX
 *
 * The server side: owns the store, the cipher and the transport, knows the
 * keys, picks the model for a profile, enforces the daily cap and records
 * usage. Apps configure it (keys, active provider) and build their settings
 * screens on its query methods; consumers only ever hold a TokenClient.
 */
package com.bclnet.tokenx

import java.util.Calendar

/** What consumers see. In-process today; the interface is the seam for a remote broker later. */
interface TokenBroker {
    /** Whether requests can be served right now (a provider is active and, if it needs one, has a key). */
    val isReady: Boolean
    /** Streams a reply. `consumer` names who asked (for usage rows). */
    fun stream(request: ChatRequest, profile: Profile, consumer: String, onEvent: (ChatEvent) -> Unit, completion: (Result<ChatReply>) -> Unit): Cancellable
}

class TokenServer(val store: TokenStore, val cipher: SecretCipher, val transport: HttpTransport = HttpUrlConnectionTransport()) : TokenBroker {
    /** Overrides the catalog's providers (tests inject fakes). */
    val providers = HashMap<ProviderKind, Provider>()
    /** The start of "today" for the daily cap, epoch milliseconds; midnight local time by default. */
    var dayStart: () -> Long = { Calendar.getInstance().apply { set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis }

    // MARK: - Configuration (the app's settings screens call these)

    val settings: Settings get() = runCatching { store.settings() }.getOrDefault(Settings())

    fun update(change: (Settings) -> Settings) { store.save(change(store.settings())) }

    fun setKey(key: String?, provider: ProviderKind) {
        val trimmed = key?.trim()
        if (trimmed.isNullOrEmpty()) store.setKeyData(null, provider) else store.setKeyData(cipher.encrypt(trimmed.toByteArray(Charsets.UTF_8)), provider)
    }

    fun key(provider: ProviderKind): String? = store.keyData(provider)?.let { String(cipher.decrypt(it), Charsets.UTF_8) }

    fun hasKey(provider: ProviderKind): Boolean = runCatching { store.keyData(provider) != null }.getOrDefault(false)

    val configuredProviders: List<ProviderKind> get() = runCatching { store.providersWithKeys() }.getOrDefault(emptyList())

    /** Picks the provider and stores its key in one step. */
    fun activate(provider: ProviderKind, key: String? = null) {
        if (key != null) setKey(key, provider)
        update { it.copy(activeProvider = provider) }
    }

    override val isReady: Boolean
        get() {
            val p = settings.activeProvider ?: return false
            return if (p == ProviderKind.LOCAL) settings.localBaseUrl != null else hasKey(p)
        }

    /** The model a profile will run on right now. */
    fun model(profile: Profile): ModelInfo? {
        val p = settings.activeProvider ?: return null
        var m = Catalog.model(profile, p)
        if (p == ProviderKind.LOCAL) settings.localModel?.let { m = m.copy(id = it, name = it) }
        return m
    }

    fun usageToday(): UsageTotals = runCatching { store.totals(dayStart(), null) }.getOrDefault(UsageTotals())
    fun usage(sinceMillis: Long, consumer: String? = null): UsageTotals = runCatching { store.totals(sinceMillis, consumer) }.getOrDefault(UsageTotals())
    fun recentUsage(limit: Int = 50, consumer: String? = null): List<UsageRecord> = runCatching { store.recent(limit, consumer) }.getOrDefault(emptyList())

    // MARK: - TokenBroker

    override fun stream(request: ChatRequest, profile: Profile, consumer: String, onEvent: (ChatEvent) -> Unit, completion: (Result<ChatReply>) -> Unit): Cancellable {
        val settings = this.settings
        val kind = settings.activeProvider ?: return failed(TokenXException.NoProvider, completion)
        settings.dailyTokenCap?.let { cap -> if (usageToday().totalTokens + request.estimatedPromptTokens >= cap) return failed(TokenXException.DailyCapReached, completion) }
        val key = try { key(kind) } catch (e: Exception) { return failed(TokenXException.Transport(e.message ?: e.toString()), completion) }
        if (kind.needsKey && key == null) return failed(TokenXException.MissingKey(kind), completion)
        val model = model(profile) ?: return failed(TokenXException.NoProvider, completion)
        val provider = providers[kind] ?: Providers.provider(kind)
        val call = ProviderCall(model, key, settings.localBaseUrl, profile)
        val http = try { provider.request(request, call) } catch (e: TokenXException) { return failed(e, completion) } catch (e: Exception) { return failed(TokenXException.Transport(e.message ?: e.toString()), completion) }
        val parser = provider.makeParser()
        val text = StringBuilder()
        var done: ChatEvent.Done? = null
        val deliver: (ChatEvent) -> Unit = { event ->
            when (event) {
                is ChatEvent.Text -> text.append(event.text)
                is ChatEvent.Done -> if (done == null) done = event
            }
            onEvent(event)
        }
        return transport.stream(http, onStatus = {}, onLine = { line -> parser.feed(line).forEach(deliver) }, completion = { result ->
            result.fold(onFailure = { completion(Result.failure(it)) }, onSuccess = {
                parser.finish().forEach(deliver)
                val reply = text.toString()
                var usage = done?.usage ?: Usage()
                val stop = done?.stop ?: StopReason.OTHER
                if (usage.promptTokens == 0) usage = usage.copy(promptTokens = request.estimatedPromptTokens)
                if (usage.replyTokens == 0) usage = usage.copy(replyTokens = (reply.toByteArray(Charsets.UTF_8).size + 3) / 4)
                runCatching {
                    store.record(UsageRecord(consumer = consumer, profile = profile, provider = kind, model = model.id, promptTokens = usage.promptTokens, replyTokens = usage.replyTokens,
                        costMicros = model.costMicros(usage.promptTokens, usage.replyTokens), stop = stop,
                        prompt = if (settings.logPrompts) request.messages.lastOrNull()?.text else null, reply = if (settings.logPrompts) reply else null))
                }
                completion(Result.success(ChatReply(reply, usage, stop)))
            })
        })
    }

    private fun failed(error: TokenXException, completion: (Result<ChatReply>) -> Unit): Cancellable { completion(Result.failure(error)); return NoopCancellable }
}
