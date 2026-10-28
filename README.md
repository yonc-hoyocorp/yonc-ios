# YOnC SDK — iOS sample

A small SwiftUI app that integrates the YOnC iOS SDK the way a partner app does: download the
model the network assigns to the iPhone, chat with it **on the device**, and switch on **Turbo
Mode** — the phone contributes its idle compute to the YOnC network while it charges, and the
network reports what each of your users earned.

One Swift file holds the whole integration; `project.yml` holds the three things an Xcode target
needs for the SDK.

**0.6.0:** on-device chat — `sdk.localChat` opens a conversation with a downloaded model and
streams the reply; it runs only while Turbo is off (section 7). `ModelInfo.licenseUrl` links each
model's licence terms. The entry point is `Yonc.create`, the name Android and Flutter use;
`Yonc.start`, its 0.5.0 name, still compiles and is deprecated. Reporting a problem: section 9. No
breaking change: a 0.5.0 integration moves to 0.6.0 without code changes.

## Requirements

- The SDK **runs on iOS 26.0+**, arm64 devices. The package links into apps whose minimum is iOS
  15.0, so an app that supports older systems keeps its minimum and calls the SDK behind
  `if #available(iOS 26.0, *)` (this sample's own minimum is 26.0). Simulators work on
  Apple-silicon Macs — but **device attestation does not exist on the simulator** (the SDK reports
  `Unavailable` there).
- Xcode 26+, Swift Package Manager. [XcodeGen](https://github.com/yonaskolb/XcodeGen) to
  generate the project from `project.yml` (`brew install xcodegen`).
- Credentials for the YOnC package registry (issued by YOnC).

## 1. Add the SDK from the YOnC package registry

The SDK is distributed as a Swift package through a **Swift package registry** on the YOnC
artifact server (not a git URL). Package identity: `yonc.sdk`. Configure the registry once per
machine and log in with the credentials YOnC issued:

```
swift package-registry set --global --scope yonc https://ymm.jfrog.io/artifactory/api/swift/ios-yonc-swift
swift package-registry login https://ymm.jfrog.io/artifactory/api/swift/ios-yonc-swift --username <user> --password <token>
```

The login also covers the binary XCFrameworks the package references (same server, checksum
verified by SwiftPM).

**In a Swift package**, depend on the identity directly:

```swift
dependencies: [
    .package(id: "yonc.sdk", exact: "0.6.1")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Yonc", package: "yonc.sdk")])
]
```

Pin the version exactly. For a 0.x version SwiftPM reads `from:` as "anything below 1.0", so a
fresh resolve would pick up a later release that can break your build; raise the pin deliberately.

**In an Xcode app project** (this sample), Xcode offers no UI for registry packages: add a small
local package that declares the registry dependency and re-exports `Yonc`, and make the app
depend on that package by path — `Dependencies/Package.swift` here is exactly that, eight lines.
Everything else (`import Yonc`, the API) is identical.

Xcode reads the registry credentials from the login keychain, where `swift package-registry
login` stored them; on the first resolve macOS may ask you to allow Xcode access to that item —
click *Always Allow*. Headless machines (CI, ssh) have no keychain UI: resolve there with plain
SwiftPM (`swift package resolve` in `Dependencies/`, credentials via `~/.netrc`) rather than with
`xcodebuild`.

- Do **not** add your own dependency on `google-ai-edge/LiteRT-LM`: the SDK pins a verified
  version and links it; a second copy duplicates native symbols.

## 2. Two target settings

- `Info.plist` → `BGTaskSchedulerPermittedIdentifiers`: `<your bundle id>.yonc.turbo.*`. This lets
  Turbo keep serving under a locked screen through iOS's continued-processing window. Without it
  Turbo still works in the foreground; the denial is reported, never thrown.
- Entitlement `com.apple.developer.devicecheck.appattest-environment` (App Attest) — required for
  device attestation. Enable the App Attest capability for the app id in your developer account.

Recommended for multi-GB models: `com.apple.developer.kernel.increased-memory-limit` and
`com.apple.developer.kernel.extended-virtual-addressing`.

## 3. Create the SDK once

```swift
import Yonc

let sdk = Yonc.create(name: "MyApp", version: "1.0")
```

Keep the returned handle for the app's lifetime; it owns the engine glue, the SDK graph and the
Turbo background continuation. The handle exposes `models`, `turbo` and `localChat`.

## 4. One model on the device

Turbo runs the network's tasks on a model stored on the phone, so the host has to get one there
(Turbo switched on earlier simply waits for it). The network serves a catalogue tailored to the device and names a default:

```swift
try await sdk.models.initialize()            // on-disk scan + the catalogue the network offers this device
try await sdk.models.download()              // the model the network designates as default

for await entries in sdk.models.models {     // [ModelEntry]: NotDownloaded / Downloading / Local
    render(entries)
}
for await id in sdk.models.defaultModelId {  // ModelId?: which entry download() fetches; nil until the catalogue names one
    markDefault(id)
}
try await sdk.models.delete(modelId: entry.info.id)   // ids are ModelId; `.value` is the network's text
```

Sizes are bytes: `ModelInfo.sizeBytes` is the exact download size, and a `ModelEntryDownloading`
carries `receivedBytes` and `totalBytes` (`progress` is their ratio); all 0 while unknown. Units
and rounding are yours, for example `ByteCountFormatter.string(fromByteCount:countStyle: .file)`.

`ModelInfo.licenseUrl` is a link to the model's licence terms, served with the catalogue (empty
when the network has none for an entry). Show it beside the model — on the row, or in your About
screen — so your users can read the terms of the model they run.

"Initialize, then download" is all a host has to do: on a first launch `download()` waits for the
catalogue to arrive. A downloaded model is a `ModelEntryLocal`; only the SDK can create one, so
holding it is the proof of download. Downloads run in the foreground (keep the app open), do not
resume after an interruption, and the files are multi-GB — recommend Wi-Fi. Storage, file
protection and iCloud-backup exclusion are handled inside the SDK.

## 5. Turbo Mode

```swift
sdk.turbo.start()        // offer this device to the network — it picks which downloaded model runs
sdk.turbo.stop()

for await status in sdk.turbo.status { … }      // Off, WaitingForSafeState, Connecting, Preparing, Connected, Working, Error, AttestationFailed
for await stats in sdk.turbo.stats { … }        // tasksDone / tokensGenerated / lastHalt
for await safe in sdk.turbo.safeState { … }     // isCharging / isWifi / thermal + the verdict isSafe + unmet
for await state in sdk.turbo.attestation { … }  // NotConfigured, Idle, Enrolling, Enrolled, Admitting, Unavailable, Failed
```

Turbo serves tasks only while the device is in a **safe state**: on iOS that means charging, on
Wi-Fi and thermally comfortable. A locked screen is not required: when the user locks the phone
the SDK asks iOS for a continued-processing window (a visible progress pill) and keeps serving
until iOS ends it. You observe the safe state; the SDK evaluates it.

`safeState.unmet` names what holds Turbo back right now (`SafeCondition`: charging, Wi-Fi, screen
locked, thermal, background work), under this platform's rules and only those — iOS never lists the
screen lock. Show these to the user instead of re-deriving them from the raw signals; keep a
default branch, later releases may add conditions.

### Battery and notifications on iOS

Nothing to request: iOS has no vendor battery managers and Turbo needs no notification
permission. The only prerequisite is the `BGTaskSchedulerPermittedIdentifiers` entry above; when
the user locks the phone iOS shows its own progress pill for the continued-processing window and
may deny or end the window at any time — the SDK stops serving cleanly and restarts the session
by itself when iOS grants a new window; you only observe `turbo.status`.

## 6. Attestation and your user id

The network verifies that a device is genuine (App Attest) before it takes part, and reports
per-user totals back to you under an id you choose. Both ride in the create call:

```swift
let sdk = Yonc.create(
    name: "MyApp",
    version: "1.0",
    attestation: AttestationConfig(
        applicationId: "<issued by YOnC for your bundle id + team>",
        externalReportingId: currentUser.opaqueId    // your own user id, 1–128 UTF-8 bytes, no surrounding whitespace
    )
)
```

- `externalReportingId` is opaque to the SDK and the network: never parsed, never logged, no
  personal data required. When your user signs in to another account while the app runs, call
  `try sdk.turbo.setReportingLabel(label:)`: Turbo leaves its connection at once (a task in flight
  is not credited to the previous account) and re-enrolls under the new label; with Turbo off, the
  label is used at the next start. It throws for a label the network would reject. Keep passing the
  current label to `Yonc.create` on every launch.
- Everything operator-side ships inside the SDK; the two values above are all a host supplies.
- Without a config the device connects unattested; the network admits that only while
  enforcement is off for your application.
- On a sticky refusal the SDK parks Turbo in `AttestationFailed` and stops retrying;
  `sdk.turbo.retryAttestation()` is the user's explicit second try.
- Simulators cannot run App Attest: the state reads `Unavailable` and the device connects
  unattested.

This sample reads the two values from launch arguments (`-yoncApplicationId`, `-yoncReportingId`)
or from Info.plist keys filled by the build settings `YONC_APPLICATION_ID` /
`YONC_EXTERNAL_REPORTING_ID` — see `project.yml`. With both set, the Turbo tab also shows an
account field to try `setReportingLabel`.

## 6a. Another Router (optional)

By default the SDK talks to the YOnC network its release was built for. A partner that runs its
own YOnC Router instance (for example an in-country deployment) passes its address:

```swift
let sdk = Yonc.create(name: "MyApp", version: "1.0", routerUrl: URL(string: "https://router.example/"))
```

Attestation values are issued per Router: use the `applicationId` issued for that Router.

## 7. On-device chat

`sdk.localChat` runs conversations on the phone's own engine with a model already on the device.
Nothing the user types and nothing the model answers leaves the phone: a chat turn sends nothing
to the network.

```swift
for await availability in sdk.localChat.availability { … }   // .ready, .noModel, .turboOn

let session = sdk.localChat.session(model: local)             // a new, empty conversation on a ModelEntryLocal
for try await event in session.send("Salom!") {               // AsyncThrowingStream<TokenEvent, Error>
    if !event.thinking { answer += event.text }               // reasoning (models that think) is flagged, the answer is plain text
}
session.model                                                 // the ModelEntryLocal it runs on
session.history                                               // [ChatMessage]: the committed exchanges, answer text only
session.lastTokenCounts                                       // engine-counted input/output tokens of the last completed reply
session.reset()                                               // start over in place
session.close()                                               // end the conversation: history discarded, model unloaded
```

- **Availability.** `.ready`, `.noModel` (nothing downloaded yet) or `.turboOn`; `value` is the
  current state, iteration yields it first and then every change. Read it before showing the chat
  entry; this sample disables the message field otherwise. Chat does not gate on battery, charging
  or temperature, needs no attestation and no YOnC consent — only a downloaded model.
- **Chat and Turbo share the device's one engine, so chat runs only while Turbo is off.** A message
  sent while Turbo is on throws `ChatError.unavailable(.turboOn)` before it reaches the engine;
  switching Turbo on stops a reply in flight the same way. After Turbo is switched off, chat is
  available again within seconds. Chat never interrupts a network task, so it does not touch
  earnings, Turbo statistics or attestation.
- **One conversation at a time.** `session(model:)` starts a new, empty conversation. It keeps its
  own history and builds every prompt from it; you pass only the next message. The engine holds one
  conversation: switching between two sessions rebuilds the other's context on its next message.
- **`send` streams.** The stream finishes when the reply is complete, or throws. Cancelling the
  iterating task stops the generation (`CancellationError`). The first message loads the model,
  which takes seconds on a large model. One reply at a time per session. Every `TokenEvent` carries
  the engine's metrics (`metrics.ttftMs`, `metrics.decodeTokenCount`, `metrics.decodeTokS`). A
  stopped or failed reply keeps its partial answer in `history`, and the next message continues.
- **Errors:** `ChatError.unavailable(reason)` (Turbo on, also mid-reply) and `ChatError.failed(message)`
  for everything else — the model could not be loaded or is damaged (delete and download again),
  the engine stopped, a reply was already streaming in this session, or the session was closed.
  The next message retries.
- **Lifecycle.** While a chat is in use, the engine keeps the model loaded in the app's process.
  `close()` ends the conversation for good: a reply in flight stops, the history is discarded and
  the model is unloaded from memory, unless Turbo is on or another session's reply is streaming.
  The session is finished (a later `send` throws `ChatError.failed`); the next conversation is a
  new `session(model:)`, whose first message loads the model again. Call it when your chat screen
  closes (this sample's *Close chat* button). Chat needs no Info.plist key or entitlement of its
  own; the memory entitlements in section 2 help the larger models.
- **Limits.** One reply at a time per session, one conversation at a time on the engine. The
  context window and what happens when a conversation outgrows it are not specified in this
  release: keep conversations short and start over with `reset()` or a new session.
- **Models and languages.** Any downloaded catalogue model can open a conversation (section 4).
  Gemma 3 1B, the model the network assigns by default, is the one chat is checked with; the others
  are possible but not the default. Gemma 3 1B is a small general model: it has not been measured
  in Uzbek or Russian, and a model of this size is not expected to hold a conversation in Uzbek
  well.
- **Generation options.** None in this release: a model's `temperature` from the catalogue sets
  its sampling, and every chat reply runs under a repetition penalty (1.1 over the last 64 tokens,
  the same on iOS and Android) so a small model escapes verbatim loops. A system prompt,
  temperature and output length per conversation are planned; tell YOnC which you need and in
  which chat scenarios.
- **Privacy.** A chat turn sends nothing to the network: the user's messages and the model's
  replies stay on the phone. The SDK uses the network for the model catalogue, model downloads and
  Turbo. The SDK applies no content filtering of its own; the models carry only their own
  training, so any filtering your app needs is on your side.
- **Testing the states.** Delete the downloaded model and availability is `.noModel`; switch Turbo
  on and it is `.turboOn`; with a model on the phone and Turbo off it is `.ready`. Engine failures
  and thermal limits cannot be forced from the app. The smallest model in the catalogue is
  Gemma 3 1B; there is no smaller test model. To test against the YOnC test or UAT Router, pass
  its address as `routerUrl` (section 6a) with the application id issued for it.

## 8. Build and run

```
xcodegen generate
open YoncSample.xcodeproj
```

or from the command line:

```
xcodebuild -project YoncSample.xcodeproj -scheme YoncSample \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build \
  YONC_APPLICATION_ID=<id> YONC_EXTERNAL_REPORTING_ID=<user>
```

## 9. Reporting a problem

The SDK has no debug flag. With a bug report send YOnC:

- the steps to reproduce;
- the SDK version (the `yonc.sdk` version you pinned);
- the iPhone model and iOS version;
- the log around the failure: the Xcode console of a run from Xcode, or a Console.app capture
  (the phone selected; the SDK's background-work lines carry the subsystem `dev.yonc.sdk`).

## App Store notes

- Both SDK frameworks ship privacy manifests (`PrivacyInfo.xcprivacy`): no tracking, no data
  collection, one required-reason API (file timestamps).
- The SDK uses HTTPS/TLS only — the standard `ITSAppUsesNonExemptEncryption = NO` declaration
  applies (verify against your own app's crypto usage).

## Known limitations

- Attestation needs a physical device with the App Attest entitlement.
- Downloads are foreground-only and do not resume.
- Chat and Turbo share the engine: no chat while Turbo is on (section 7). Chat has no system
  prompt, sampling or output-length options yet, and a small model is not expected to hold a
  conversation in every language.
- If your app embeds another Kotlin/Native framework, the console warns about a duplicate Kotlin
  runtime; the warning is cosmetic, but the combination is untested — tell us if you need it.
