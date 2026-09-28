# TokenX

TokenX separates two things that usually get tangled: **managing** access to
AI models (which providers, whose keys, which model for which job, how much
was spent) and **using** them (an actor that wants a reply, a screen that
wants a summary). Both halves run in the same process; the consumer never
sees a key, a model name or a vendor.

```
  app settings ──► TokenServer ──► Provider (Anthropic | OpenAI | Gemini | local)
  (keys, active     │  store: keys (encrypted), settings, usage
   provider, caps)  │  policy: daily cap, profile → model, cost
                    ▼
  library/screen ◄─ TokenClient ─ TokenSession(consumer, profile, budget)
```

## The client side

A consumer holds a `TokenClient` and opens sessions:

```swift
let client = TokenClient(broker: server)             // the app hands this over
let session = client.session(consumer: "bush", profile: .character, budget: 20_000)
session.stream(ChatRequest(system: persona, messages: [.user("sing")]),
               onText: { delta in speak(delta) },
               completion: { result in /* ChatReply: text, usage, stop */ })
```

```kotlin
val session = TokenClient(server).session("bush", Profile.CHARACTER, budget = 20_000)
session.stream(ChatRequest(persona, listOf(ChatMessage.user("sing"))), { delta -> speak(delta) }) { result -> }
```

- **Profile** names the intent, never the model: `character` (short, warm, low
  effort), `assistant` (careful, longer), `fast` (cheap and quick), `vision`.
- **Consumer** is a free name for usage rows (an actor id, a screen).
- **Budget** is the session's own token allowance. The server's daily cap
  applies on top. `remaining`, `spent` and `isExhausted` are on the session.
- The reply streams as text deltas and ends with `Usage` (prompt and reply
  tokens) and a `StopReason` (`end`, `maxTokens`, `refusal`, `other`).
- Errors: `noProvider`, `missingKey`, `budgetExhausted`, `dailyCapReached`,
  `http(status, body)`, `transport`, `cancelled`.

`TokenBroker` is the interface between the halves. `TokenServer` implements
it in-process; a remote or out-of-process broker would implement the same
interface without touching consumers.

## The server side

The app owns a `TokenServer` and builds its settings screens on it. Nothing
about providers or profiles is stored: they are code (`Catalog`, `Profile`).
The store holds only:

| table | rows |
| --- | --- |
| `keys` | provider → API key ciphertext |
| `settings` | active provider, local server URL and model, daily token cap, whether prompts are logged |
| `usage` | one row per request: time, consumer, profile, provider, model, prompt and reply tokens, cost in micro-dollars, stop reason, optional prompt and reply text |

```swift
let server = TokenServer(store: try SQLiteStore(path: dbPath), cipher: KeychainCipher())
try server.activate(.anthropic, key: keyFromTheUser)    // stores the key encrypted, makes it active
server.isReady                                           // a provider is active and has what it needs
server.model(for: .character)                            // what would run right now
server.usageToday(), server.recentUsage(limit: 50)       // for the usage screen
try server.update { $0.dailyTokenCap = 200_000 }
```

Queries for lists and options come from the server (`configuredProviders`,
`ProviderKind.allCases`, `Catalog.models(for:)`, `usage(since:consumer:)`),
so an app can draw its own UI. Most apps will not need to:

### Bootstrap, model and UI pieces

`TokenXApple` / `tokenx-android` build the standard server in one call, and
the observable `TokenXModel` wraps it for screens:

```swift
let ai = TokenXModel(appId: "net.bcl.myapp")     // TokenXBootstrap.standard(appId:) underneath:
                                                  // Application Support/<appId>/tokenx.sqlite, KeychainCipher(service: appId + ".tokenx")
ai.settings, ai.configured, ai.usageToday, ai.recent, ai.lastError   // @Published
ai.activate(.anthropic, key: text); ai.removeKey(for: .openai); ai.update { $0.dailyTokenCap = 200_000 }
ai.setLocalServer(url: "http://host:11434/v1", model: "llama3"); ai.clearUsage()
ai.isReady; ai.modelName(for: .character)         // "Claude Sonnet 5 (Anthropic)"
ai.client.session(consumer: "bush", profile: .character, budget: 20_000)
```

```kotlin
val ai = TokenXModel(context)                     // TokenX.standard(context): noBackupFilesDir/tokenx.sqlite, KeystoreCipher("<package>.tokenx")
ai.settings; ai.configured; ai.usageToday; ai.recent; ai.lastError    // Compose state
ai.activate(ProviderKind.ANTHROPIC, text); ai.removeKey(...); ai.update { it.copy(dailyTokenCap = 200_000) }
```

`TokenXUI` (SwiftUI) and `tokenx-compose` hold the pieces a host embeds in
its own settings and status screens. They use platform controls in the
host's theme and bring no navigation or branding:

| piece | SwiftUI | Compose |
| --- | --- | --- |
| provider picker, key entry, local server URL and model, activate / remove key, prompt logging, today's usage, active model line | `TokenXSettingsSection(model:title:)` inside a `Form` | `TokenXSettings(model, modifier, title)` inside a `Column` |
| today's and 30-day totals, recent requests, clear | `TokenXUsageView(model:)` | `TokenXUsage(model, modifier)` |
| one line of totals | `TokenXUsageRow(totals:label:)` | `TokenXUsageRow(label, totals)` |
| readiness indicator | `TokenXStatusBadge(model:)` | `TokenXStatusBadge(model)` |

When a later TokenX needs something new from the user (another provider, a
different setting), the section grows and the host app only updates the
package.

### Secrets

Keys are encrypted before they reach SQLite. The cipher is the platform's:
`KeychainCipher` (TokenXApple) keeps an AES-GCM key in the Keychain, device
only and not backed up; `KeystoreCipher` (tokenx-android) keeps it in the
Android Keystore. `PlainCipher` exists for tests. The database itself lives
in the app's private, no-backup storage.

### Providers

Providers are plain HTTPS with server-sent events; no vendor SDKs, so Swift
and Kotlin behave identically and the core is testable with a fake transport.

| provider | endpoint | notes |
| --- | --- | --- |
| Anthropic | `POST /v1/messages`, `stream: true` | `output_config.effort` from the profile on the 5-generation models; sampling parameters are not sent there |
| OpenAI | `POST /v1/chat/completions`, `stream: true`, `stream_options.include_usage` | |
| Gemini | `POST /v1beta/models/{model}:streamGenerateContent?alt=sse` | |
| local | an OpenAI-compatible server (Ollama, LM Studio, vLLM) at `Settings.localBaseURL`; no key | model name from `Settings.localModel` |

### Catalog and profiles

The catalog lists three models per provider by tier (`fast`, `balanced`,
`best`) with prices for the cost column. A profile asks for a tier; the
active provider's model of that tier serves it (or the nearest tier the
provider has). Editing the catalog is a code change on purpose: it is the
opinion TokenX ships with.

### Policy

- **Daily cap**: `Settings.dailyTokenCap` across every consumer; checked
  against today's usage plus the request's estimated prompt before sending.
- **Session budget**: per `TokenSession`, checked the same way.
- **Usage** is recorded once per successful request with the provider's
  reported tokens (estimated when a provider reports none). Failed requests
  cost nothing.
- **Prompt logging** is off by default; `Settings.logPrompts` keeps the last
  user message and the reply on the usage row.

## Layout

```
Package.swift             Swift manifest (root, so SwiftPM can add the package by URL)
ios/Sources/TokenX        catalog, chat types, transport, providers, store, SQLiteStore, server, client
ios/Sources/TokenXApple   KeychainCipher, TokenXBootstrap.standard(appId:), TokenXModel (ObservableObject)
ios/Sources/TokenXUI      TokenXSettingsSection, TokenXUsageView, TokenXUsageRow, TokenXStatusBadge (SwiftUI)
ios/Sources/CSQLite       sqlite3 module map for Linux
ios/Tests/TokenXTests     16 tests with a fake transport and an in-memory / temp SQLite store
android/tokenx-core       Kotlin/JVM mirror (JDBC SQLite for desktop and tests), 16 tests
android/tokenx-android    AndroidSqlDatabase, KeystoreCipher, TokenX.standard(context)
android/tokenx-compose    TokenXModel (Compose state), TokenXSettings, TokenXUsage, TokenXUsageRow, TokenXStatusBadge
```
