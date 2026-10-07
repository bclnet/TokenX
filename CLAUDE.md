# TokenX

Token management for apps that use AI models, in the same process as the
app. The **server side** (`TokenServer`) knows the providers, holds API keys
encrypted in SQLite, keeps the usage ledger and picks a model per profile.
The **client side** (`TokenClient` / `TokenSession`) is what a library holds:
a session for a profile with a budget that streams replies. Consumers never
learn which vendor or model answered.

TokenX is a standalone library: it must not know about JsonMind, JsonScene or
QRX. Adapters live with the consumers (JsonMind's `TokenXMindProvider`).
`docs/TOKENX.md` is the reference.

## Layout

```
Package.swift               products TokenX, TokenXApple, TokenXUI; CSQLite system library (pkg-config sqlite3 on Linux only)
ios/Sources/TokenX          Catalog (ProviderKind anthropic/openai/gemini/local, ModelTier, ModelInfo, Profile
                            character/assistant/fast/vision), Chat types (ChatPart text/image, ChatMessage.parts,
                            ChatRequest.jsonSchema, ChatReply.model/provider), Transport (URLSession + SSE parser),
                            Provider protocol, Providers/{Anthropic,OpenAI,Gemini}Provider, Store (SecretCipher,
                            KeyRepository, Settings, UsageRecord/UsageTotals, TokenStore, InMemoryStore),
                            SQLiteStore (sqlite3 C API), TokenServer, TokenClient/TokenSession
ios/Sources/TokenXApple     KeychainCipher (CryptoKit AES-GCM, key in Keychain), TokenXBootstrap.standard(appId:),
                            TokenXModel (ObservableObject over the server)
ios/Sources/TokenXUI        SwiftUI pieces: TokenXSettingsSection, TokenXUsageView, TokenXUsageRow, TokenXRemainingView, TokenXStatusBadge
ios/Tests/TokenXTests       23 tests with FakeTransport and canned SSE bodies
android/tokenx-core         Kotlin/JVM mirror; MiniJson (no serialization dependency); JdbcSqlDatabase for tests; 23 tests
android/tokenx-android      AndroidSqlDatabase, KeystoreCipher, TokenX.standard(context)
android/tokenx-compose      TokenXModel (Compose state), TokenXSettings, TokenXUsage, TokenXUsageRow, TokenXRemaining, TokenXStatusBadge
js/                         TypeScript mirror, npm package `tokenx` (Node / Workers / React Native): src/*.ts file for file
                            with ios/Sources/TokenX, fetch + ReadableStream transport, async TokenStore, InMemoryStore,
                            AesGcmCipher (WebCrypto, host-supplied key); no UI pieces; test/*.test.ts, 22 vitest tests
```

## Build and test

```
swift test                                   # Linux (libsqlite3-dev) or macOS
cd android && ./gradlew build                # JVM tests plus the Android and Compose AARs
cd js && npm ci && npm run typecheck && npm test
```

## Design decisions (agreed with the owner)

- No vendor SDKs: Anthropic Messages API, OpenAI chat completions and Gemini
  `streamGenerateContent` over plain HTTPS and server-sent events.
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

## Gotchas

- Anything under `#if canImport(SwiftUI)` or `canImport(Combine)` is skipped on Linux, so
  TokenXApple's model and all of TokenXUI are only compiled in Xcode. Check their API use
  against Store.swift and TokenServer.swift by hand, and parse-check with `swiftc -parse`.
- The SSE parsers flush the last event in `finish()` by feeding an empty line; fixtures
  need not end with a blank line.
- Budget and daily-cap tests use exact thresholds (budget 36, cap 36); keep the fake
  usage numbers in step when changing accounting.
- Local `master` in a checkout may be stale; work was pushed from `claude/tokenx`.
