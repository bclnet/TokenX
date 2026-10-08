# Integrating TokenX

How an app or a library adds TokenX and uses it, on each platform. Read
[TOKENX.md](TOKENX.md) for the design; this page is the how-to. Every snippet
here uses an API that exists in the package today, and CLAUDE.md asks that
this page change in the same commit as the API it describes.

TokenX splits two roles, and most projects play both:

- **The host app** owns a `TokenServer`: it adds the package, bootstraps the
  server once, embeds the settings pieces so the user can enter keys and pick a
  provider, and hands a `TokenClient` to whoever needs replies.
- **A consumer** (a library, a screen, an actor) holds a `TokenClient`, opens a
  `TokenSession` for a *profile* with a budget and streams replies. It never
  sees keys, vendors or model names, so it ports between apps unchanged.

## 1. Add the package

| platform | how |
| --- | --- |
| iOS, macOS | Swift Package Manager, by URL: `https://github.com/bclnet/TokenX`. Products: `TokenX` (core), `TokenXApple` (Keychain cipher, bootstrap, observable model), `TokenXUI` (SwiftUI pieces). A consumer library depends on `TokenX` only. iOS 15, macOS 12 and up. |
| Android, JVM | Gradle modules in `android/`, group `com.bclnet.tokenx`: `tokenx-core` (pure Kotlin/JVM), `tokenx-android` (Keystore cipher, Android SQLite, bootstrap; minSdk 26), `tokenx-compose` (Compose state and pieces). Until they are on a Maven repository, either `includeBuild("../TokenX/android")` with `dependencySubstitution`, or run `./gradlew publishToMavenLocal` in `android/` and depend on `com.bclnet.tokenx:tokenx-core:1.0.0` etc. with `mavenLocal()`. A JVM consumer library depends on `tokenx-core` only. |
| Node, Workers, React Native | npm package `tokenx` in `js/`, not yet published. Install from the checkout: `npm install ../TokenX/js` (a `file:` dependency) or add it as a workspace. The package ships TypeScript sources (`src/index.ts`), so the host builds with a bundler or `tsx`/Vite/Metro that compiles TypeScript. |

## 2. Bootstrap the server once (host app)

Create one server per app at launch and keep it for the app's lifetime. The
standard bootstrap puts the SQLite database in private, no-backup storage and
the cipher key in the platform's secure store; if either cannot be opened it
falls back to an in-memory store so the app still runs.

```swift
import TokenXApple
let ai = TokenXModel(appId: "net.bcl.myapp")      // wraps TokenXBootstrap.standard(appId:)
// or, without the observable model:
let server = TokenXBootstrap.standard(appId: "net.bcl.myapp")
```

```kotlin
import com.bclnet.tokenx.compose.TokenXModel
val ai = TokenXModel(context)                      // wraps TokenX.standard(context): noBackupFilesDir/tokenx.sqlite, KeystoreCipher
// or, without the Compose model:
val server = TokenX.standard(context)
```

```ts
import { AesGcmCipher, TokenServer } from 'tokenx';
const server = new TokenServer(store, new AesGcmCipher(process.env.TOKENX_CIPHER_KEY!));
// AesGcmCipher.generateSecret() makes a key once; keep it in the host's secret store (a Worker secret, a device keychain).
```

The TypeScript side has no bootstrap because it has no fixed database: pass a
`TokenStore` (see section 8) and a `SecretCipher`. `InMemoryStore` and
`PlainCipher` exist for tests and prototypes.

To build your own server on Apple or Android, compose the parts directly:
`TokenServer(store: try SQLiteStore(path:), cipher: KeychainCipher())` /
`TokenServer(SQLiteStore(AndroidSqlDatabase(db)), KeystoreCipher())`. A custom
`HttpTransport` is the third argument (tests use a fake; see section 9).

## 3. Let the user configure it (host app)

The server is not ready until a provider is active and has what it needs: an
API key, or for `local` a base URL. Embed the settings piece in your own
settings screen and you are done; it lists every provider, takes the key,
local server URL and model, prompt logging, the daily cap's today line, and
the credit the user read off the provider's billing page.

```swift
import TokenXUI
Form {
    TokenXSettingsSection(model: ai)                 // title: defaults to "AI provider"
}
TokenXStatusBadge(model: ai)                         // a readiness dot for a toolbar
TokenXRemainingView(model: ai)                       // credit left, else tokens left under the cap, else today's usage
TokenXUsageView(model: ai)                           // today's and 30-day totals, recent requests, clear
```

```kotlin
Column { TokenXSettings(ai) }                        // title = null leaves the heading to the host
TokenXStatusBadge(ai); TokenXRemaining(ai); TokenXUsage(ai)
```

The pieces use platform controls in the host's theme and bring no navigation
or branding. Call `ai.refresh()` after a request so the usage lines update.

The providers a user can pick, each with its own API key: Anthropic, OpenAI,
Google Gemini, DeepSeek, Kimi (Moonshot), Qwen (Alibaba Cloud Model Studio),
Grok (xAI), Mistral, Cohere and OpenRouter; plus `local`, an OpenAI-compatible
server reached by URL with no key. Which models each one runs, and at what
price, is the catalog's opinion (see TOKENX.md); the host never chooses.

To draw your own UI instead, everything the pieces use is public on the
server and the model: `activate(provider, key:)`, `removeKey(for:)`,
`setLocalServer(url:model:)`, `setCredit(dollars, for:)`, `update { settings in }`,
`configuredProviders`, `isReady`, `model(for: profile)`, `usageToday()`,
`remainingToday()`, `credit(for:)`, `recentUsage(limit:)`,
`usage(since:consumer:)`, `ProviderKind.allCases`, `Catalog.models(for:)`.
The TypeScript server has the same methods, all `async`.

Settings a host may want to set itself:

```swift
try server.update { $0.dailyTokenCap = 200_000 }     // tokens per calendar day across every consumer; nil is unlimited
try server.update { $0.logPrompts = true }           // keep the last user message and the reply on each usage row (off by default)
```

## 4. Hand out clients (host app)

Consumers get a `TokenClient`, never the server. `TokenXModel` carries one as
`ai.client`; otherwise make one with `TokenClient(broker: server)`. The client
only knows the `TokenBroker` interface, so a host could later swap the
in-process server for a remote broker without touching consumers.

```swift
let session = ai.client.session(consumer: "bush", profile: .character, budget: 20_000)
```

## 5. Ask for replies (consumer)

A session carries who is asking (`consumer`, free text that ends up on usage
rows), which profile, and an optional budget of tokens the session may spend
in total. The server's daily cap applies on top.

| profile | intent | reply length | effort |
| --- | --- | --- | --- |
| `character` | a character talking to a person: short, warm | 400 tokens | low |
| `assistant` | general assistance: longer, careful answers | 4096 | high |
| `fast` | classification, extraction, short rewrites; the cheapest model | 1024 | low |
| `vision` | requests that carry images | 4096 | high |

A profile names an intent, never a model. The active provider's model of the
profile's tier serves it, and the reply says what answered (`reply.model`,
`reply.provider`) for the consumer's records only.

```swift
let request = ChatRequest(system: persona, messages: [.user("sing")])
let handle = session.stream(request, onText: { delta in speak(delta) }) { result in
    switch result {
    case .success(let reply): print(reply.text, reply.usage.total, reply.stop)   // stop: .end, .maxTokens, .refusal, .other
    case .failure(let error): show(error.description)
    }
}
handle.cancel()                                      // optional; the completion then reports .cancelled
session.send(request) { result in }                  // the whole reply at once
```

```kotlin
val session = ai.client.session("bush", Profile.CHARACTER, budget = 20_000)
session.stream(ChatRequest(persona, listOf(ChatMessage.user("sing"))), { delta -> speak(delta) }) { result ->
    result.onSuccess { reply -> }.onFailure { e -> /* TokenXException */ }
}
```

```ts
const session = new TokenClient(server).session('bush', 'character', 20_000);
const reply = await session.stream({ system: persona, messages: [ChatMessage.user('sing')] }, (delta) => speak(delta), signal);
await session.send(request);                         // the whole reply at once
```

Callbacks arrive off the main thread on Apple (URLSession's delegate queue)
and on a worker thread on the JVM; hop to the main thread before touching UI.
Keep conversation history yourself: `ChatRequest.messages` is the whole
transcript each time, alternating `user` and `assistant`.

Overrides: `maxTokens` and `temperature` on `ChatRequest` replace the
profile's defaults for one request.

## 6. Images and structured replies

A message is text, or text and image parts. Images go inline as base64 with
their MIME type; the catalog's `vision` flag steers the request to a model that
can see them, and each image counts about 1,600 tokens against budgets.

```swift
let message = ChatMessage.user(parts: [.text("What is in this photo?"), .image(data: base64, mediaType: "image/jpeg")])
```

```kotlin
ChatMessage.user(listOf(ChatPart.Text("What is in this photo?"), ChatPart.Image(base64, "image/jpeg")))
```

```ts
ChatMessage.user([{ type: 'text', text: 'What is in this photo?' }, { type: 'image', mediaType: 'image/jpeg', data: base64 }]);
```

For a reply you will parse, give the request a JSON schema; the reply text is
then the JSON document. Providers that enforce schemas get it as such, the
rest get JSON mode with the schema in the prompt, so still validate the result.

```swift
ChatRequest(messages: [.user(text)], jsonSchema: ["type": "object", "properties": ["mood": ["type": "string"]], "required": ["mood"]])
```

## 7. Budgets, errors and what to show

Before anything is sent, the session checks its budget and the server checks
the daily cap against today's usage plus the estimated prompt. Both fail fast
with no request made.

| error | meaning | what a consumer does |
| --- | --- | --- |
| `noProvider` | the user has not picked a provider | point them at the settings screen |
| `missingKey(provider)` | the active provider has no key | same |
| `budgetExhausted` | this session's budget is spent or the prompt would not fit | open a new session, or stop |
| `dailyCapReached` | the app-wide cap for today | tell the user; `server.remainingToday()` says how much was left |
| `http(status, body)` | the provider refused (bad key, rate limit, bad request) | show the body's message |
| `transport(message)` | network or local server trouble | retry later |
| `cancelled` | the handle was cancelled | nothing |

A refusal is not an error: the reply comes back with `stop == .refusal` and
usually empty text. Failed requests are never charged; successful ones are
recorded once with the provider's token counts (estimated when a provider
reports none) and costed from the catalog's prices.

On the session, `remaining`, `spent`, `requests` and `isExhausted` let a
consumer pace itself; on the server, `usageToday()`, `remainingToday()` and
`credit()` feed the host's screens.

## 8. Your own store (TypeScript, or a custom database)

`TokenStore` is three small repositories: keys (ciphertext per provider),
settings (flat key/value pairs) and usage rows. The TypeScript interface is
`async`, so a SQL-over-the-network store fits; `settingsToPairs` and
`settingsFromPairs` give you the exact rows the Swift and Kotlin SQLite stores
keep, so one schema can be shared across platforms. Scope the store per tenant
if your server hosts several (a multi-tenant Worker gives each organisation its
own store and cipher key).

On Apple and Android the shipped `SQLiteStore` is normally enough; to back it
with another database on the JVM, implement `SqlDatabase` (execute, query) the
way `JdbcSqlDatabase` and `AndroidSqlDatabase` do.

## 9. Testing a consumer

Do not hit the network in tests. Build a server on `InMemoryStore` and
`PlainCipher` with a fake transport that serves canned server-sent-event
bodies, activate a provider with any key, and drive the consumer through a
real `TokenClient`. The repository's own tests (`FakeTransport` and `Canned` in
`ios/Tests/TokenXTests`, `android/tokenx-core/src/test`, `js/test`) are the
template; copying those two files into a consumer's test target is the
intended use.

```swift
let server = TokenServer(store: InMemoryStore(), cipher: PlainCipher(), transport: fake)
try server.activate(.anthropic, key: "test")
let client = TokenClient(broker: server)
```

A consumer library can also implement `TokenBroker` itself for a pure stub.

## 10. Writing an adapter

TokenX knows nothing about the libraries that use it; the adapter lives with
the consumer. The shape that has worked: the library declares a small provider
interface of its own (for example "stream a reply for this persona and
transcript"), and the adapter implements it by holding a `TokenClient`, opening
one `TokenSession` per actor or screen with a budget, and mapping the
library's turns to `ChatMessage`s. Keep the adapter thin: no vendor or model
names, no keys, and no catalog lookups. If the adapter needs something TokenX
does not expose, that is a TokenX change, not an adapter workaround.

## Checklist for a new integration

1. Package added; a consumer library depends on the core product only.
2. One server bootstrapped at launch; `TokenXModel` kept for the app's lifetime.
3. Settings piece embedded; the user can enter a key and see today's usage.
4. Consumers receive a `TokenClient`, open sessions with a profile and a budget.
5. Errors mapped to the table in section 7; `noProvider` and `missingKey` lead to settings.
6. Images use `user(parts:)`; parsed replies use `jsonSchema` and still validate.
7. Tests use `InMemoryStore`, `PlainCipher` and a fake transport.
