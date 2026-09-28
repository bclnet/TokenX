# TokenX

Token management for apps that use AI models, in the same process as the app.
The **server side** knows the providers, holds the API keys (encrypted) and
the usage ledger, and picks a model for a job. The **client side** is what a
library or a screen holds: open a session for a *profile* with a budget,
stream a reply. The consumer never learns which vendor or model answered.

```swift
// the app, once
let server = TokenServer(store: try SQLiteStore(path: dbPath), cipher: KeychainCipher())
try server.activate(.anthropic, key: keyEnteredByTheUser)

// a consumer, anywhere
let session = TokenClient(broker: server).session(consumer: "bush", profile: .character, budget: 20_000)
session.stream(ChatRequest(system: persona, messages: [.user("sing")]), onText: { print($0) }) { result in }
```

`docs/TOKENX.md` explains the two halves, the profiles, the store and the
policy. Providers are Anthropic, OpenAI, Google Gemini and any
OpenAI-compatible local server, all over plain HTTPS and server-sent events
with no vendor SDKs. Profiles and the model catalog are opinionated code,
not rows; the SQLite database holds only keys, a few settings and usage.

| platform | package | secrets |
| --- | --- | --- |
| iOS, macOS | Swift package `TokenX` (+ `TokenXApple`), sources in `ios/` | Keychain-held AES-GCM key |
| Android, JVM | Gradle modules `tokenx-core`, `tokenx-android` in `android/` | Android Keystore AES-GCM key |

TokenX knows nothing about the apps or libraries that use it. Adapters live
with the consumers (for example JsonMind's `TokenXMindProvider`).

## Building

```
swift test                                 # Linux (needs libsqlite3-dev) or macOS; 16 tests
cd android && ./gradlew build              # 16 JVM tests plus the Android library
```

## License

MIT, see [LICENSE](LICENSE).
