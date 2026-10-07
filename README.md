# TokenX

Token management for apps that use AI models, in the same process as the app.
The **server side** knows the providers, holds the API keys (encrypted) and
the usage ledger, and picks a model for a job. The **client side** is what a
library or a screen holds: open a session for a *profile* with a budget,
stream a reply. The consumer never learns which vendor or model answered.

```swift
// the app, once: SQLite in Application Support, cipher key in the Keychain
let ai = TokenXModel(appId: "net.bcl.myapp")          // TokenXApple; wraps TokenXBootstrap.standard(appId:)

// its settings screen: one section in the app's own Form
Form { TokenXSettingsSection(model: ai) }              // TokenXUI

// a consumer, anywhere
let session = ai.client.session(consumer: "bush", profile: .character, budget: 20_000)
session.stream(ChatRequest(system: persona, messages: [.user("sing")]), onText: { print($0) }) { result in }
```

```kotlin
val ai = TokenXModel(context)                          // tokenx-compose; wraps TokenX.standard(context)
Column { TokenXSettings(ai) }                          // in the app's settings screen
val session = ai.client.session("bush", Profile.CHARACTER, budget = 20_000)
```

```ts
const server = new TokenServer(store, new AesGcmCipher(secret));   // tokenx (npm); the store API is async
const session = new TokenClient(server).session('bush', 'character', 20_000);
const reply = await session.stream({ system: persona, messages: [ChatMessage.user('sing')] }, (delta) => speak(delta));
```

`docs/TOKENX.md` explains the two halves, the profiles, the store and the
policy. Providers are Anthropic, OpenAI, Google Gemini and any
OpenAI-compatible local server, all over plain HTTPS and server-sent events
with no vendor SDKs. Profiles and the model catalog are opinionated code,
not rows; the SQLite database holds only keys, a few settings and usage.

| platform | package | secrets |
| --- | --- | --- |
| iOS, macOS | Swift package `TokenX` (+ `TokenXApple` bootstrap and model, `TokenXUI` SwiftUI pieces), sources in `ios/` | Keychain-held AES-GCM key |
| Android, JVM | Gradle modules `tokenx-core`, `tokenx-android`, `tokenx-compose` in `android/` | Android Keystore AES-GCM key |
| Node, Workers, React Native | npm `tokenx`, sources in `js/` (async store API, no UI pieces) | host-supplied AES-GCM key (`AesGcmCipher`) |

The UI packages hold embeddable pieces, not screens: a settings section, a
usage view and a status badge in the host's own theme. When TokenX changes
what it needs from the user, the host app picks it up by updating the
package.

Messages carry text and inline images (`ChatMessage.user(parts:)`; the
`vision` flag in the catalog picks a model that can see them), a request can
ask for a reply that fits a JSON schema (`ChatRequest.jsonSchema`), and the
reply says which model and provider answered.

TokenX knows nothing about the apps or libraries that use it. Adapters live
with the consumers (for example JsonMind's `TokenXMindProvider`).

## Building

```
swift test                                 # Linux (needs libsqlite3-dev) or macOS; 23 tests
cd android && ./gradlew build              # 23 JVM tests plus the Android and Compose libraries
cd js && npm ci && npm test                # 22 tests on a fake transport with canned SSE bodies
```

## License

MIT, see [LICENSE](LICENSE).
