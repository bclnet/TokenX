# TokenX

Token management for apps that use AI models, in the same process as the
app. The **server side** (`TokenServer`) knows the providers, holds API keys
encrypted in SQLite, keeps the usage ledger and picks a model per profile.
The **client side** (`TokenClient` / `TokenSession`) is what a library holds:
a session for a profile with a budget that streams replies. Consumers never
learn which vendor or model answered.

TokenX is a standalone library: it must not know about JsonMind, JsonScene or
QRX. Adapters live with the consumers (JsonMind's `TokenXMindProvider`).
`docs/TOKENX.md` is the reference; `docs/INTEGRATION.md` is the guide for
projects that adopt the library.

## Layout

```
Package.swift               products TokenX, TokenXApple, TokenXUI; CSQLite system library (pkg-config sqlite3 on Linux only)
ios/Sources/TokenX          Catalog (ProviderKind anthropic/openai/gemini/deepseek/kimi/qwen/local, ModelTier, ModelInfo, Profile
                            character/assistant/fast/vision), Chat types (ChatPart text/image, ChatMessage.parts,
                            ChatRequest.jsonSchema, ChatReply.model/provider), Transport (URLSession + SSE parser),
                            Provider protocol, Providers/{Anthropic,OpenAI,Gemini}Provider (OpenAIProvider also serves
                            deepseek, kimi, qwen and local at their own endpoints), Store (SecretCipher,
                            KeyRepository, Settings, UsageRecord/UsageTotals, TokenStore, InMemoryStore),
                            SQLiteStore (sqlite3 C API), TokenServer, TokenClient/TokenSession
ios/Sources/TokenXApple     KeychainCipher (CryptoKit AES-GCM, key in Keychain), TokenXBootstrap.standard(appId:),
                            TokenXModel (ObservableObject over the server)
ios/Sources/TokenXUI        SwiftUI pieces: TokenXSettingsSection, TokenXUsageView, TokenXUsageRow, TokenXRemainingView, TokenXStatusBadge
ios/Tests/TokenXTests       25 tests with FakeTransport and canned SSE bodies
android/tokenx-core         Kotlin/JVM mirror; MiniJson (no serialization dependency); JdbcSqlDatabase for tests; 25 tests
android/tokenx-android      AndroidSqlDatabase, KeystoreCipher, TokenX.standard(context)
android/tokenx-compose      TokenXModel (Compose state), TokenXSettings, TokenXUsage, TokenXUsageRow, TokenXRemaining, TokenXStatusBadge
js/                         TypeScript mirror, npm package `tokenx` (Node / Workers / React Native): src/*.ts file for file
                            with ios/Sources/TokenX, fetch + ReadableStream transport, async TokenStore, InMemoryStore,
                            AesGcmCipher (WebCrypto, host-supplied key); no UI pieces; test/*.test.ts, 24 vitest tests
```

## Build and test

```
swift test                                   # Linux (libsqlite3-dev) or macOS
cd android && ./gradlew build                # JVM tests plus the Android and Compose AARs
cd js && npm ci && npm run typecheck && npm test
```

## Design decisions (agreed with the owner)

- No vendor SDKs: Anthropic Messages API, OpenAI chat completions and Gemini
  `streamGenerateContent` over plain HTTPS and server-sent events. DeepSeek (api.deepseek.com),
  Kimi (api.moonshot.ai) and Qwen (dashscope-intl.aliyuncs.com compatible mode, the shared
  international endpoint) are OpenAI-compatible and share OpenAIProvider with per-kind rules:
  `max_completion_tokens` for OpenAI and Kimi, `max_tokens` elsewhere; no temperature for OpenAI
  or Kimi; the profile's effort drives each vendor's thinking switch (DeepSeek `thinking`, Kimi
  `reasoning_effort` on K3 / `thinking` on K2, Qwen `enable_thinking`), low turns thinking off;
  DeepSeek and Qwen get `response_format: json_object` with the schema appended to the system
  prompt, the others `json_schema`.
- Providers, the model catalog and profiles are opinionated code, not database rows.
  The database holds only keys (ciphertext), a few settings and usage.
- Anthropic requests on 5-generation models send `output_config.effort` and no sampling
  parameters; Opus 5.5 and Sonnet 5.5 requests also send `anthropic-beta: server-side-fallback-2026-07-01`
  with `"fallbacks": "default"`. OpenAI streams with `stream_options.include_usage`.
- Image parts are allowed on every profile; the catalog's `vision` flag picks the model. Wire mapping:
  Anthropic base64 image blocks, OpenAI `image_url` data URIs, Gemini `inlineData`; the estimate adds
  about 1,600 tokens per image. `jsonSchema` maps to Anthropic `output_config.format`, OpenAI
  `response_format` and Gemini `responseMimeType: application/json`.
- Repository pattern over SQLite; the app is free to query for its own UI, but the
  UI packages exist so most apps embed `TokenXSettingsSection` / `TokenXSettings` and pick up
  new requirements by updating the package. UI pieces use platform controls in the host's
  theme, with no navigation or branding.
- Speech-to-text is not TokenX's concern; it stays in the app.
- Keep Swift, Kotlin and TypeScript in step, with tests on all three sides. The TS store API is
  async and the TS package has no UI pieces; publishing `tokenx` to npm is a separate step.

## Keep the integration guide current

`docs/INTEGRATION.md` is what adopting projects follow, so it must never lag
the code. Any change that touches what a host or consumer sees updates the
guide in the same commit: a public type, initializer, method or property on
`TokenServer`, `TokenClient`, `TokenSession`, `ChatRequest`, `ChatMessage`,
`ChatReply`, `Settings` or the UI pieces; a new or removed provider, profile
or error case; a change to how a package is added, bootstrapped or tested;
a new platform. Keep its snippets runnable against the current API on all
three platforms, keep the numbered sections and the closing checklist, and
add a section rather than a footnote when a feature changes how a project
integrates. When in doubt whether a change belongs there: if an adopter would
have to read the source to learn it, it belongs in the guide.

## Gotchas

- Anything under `#if canImport(SwiftUI)` or `canImport(Combine)` is skipped on Linux, so
  TokenXApple's model and all of TokenXUI are only compiled in Xcode. Check their API use
  against Store.swift and TokenServer.swift by hand, and parse-check with `swiftc -parse`.
- The SSE parsers flush the last event in `finish()` by feeding an empty line; fixtures
  need not end with a blank line.
- Budget and daily-cap tests use exact thresholds (budget 36, cap 36); keep the fake
  usage numbers in step when changing accounting.
- Local `master` in a checkout may be stale; work was pushed from `claude/tokenx`.
