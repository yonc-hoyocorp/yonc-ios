# YOnC SDK — iOS sample

A small SwiftUI app that integrates the YOnC iOS SDK the way a partner app does: download the
model the network assigns to the iPhone, then switch on **Turbo Mode** — the phone contributes
its idle compute to the YOnC network while it charges, and the network reports what each of your
users earned.

One Swift file holds the whole integration; `project.yml` holds the three things an Xcode target
needs for the SDK.

## Requirements

- **iOS 26.0+**, arm64 devices. Simulators work on Apple-silicon Macs — but **device attestation
  does not exist on the simulator** (the SDK reports `Unavailable` there).
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
    .package(id: "yonc.sdk", from: "0.3.0")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Yonc", package: "yonc.sdk")])
]
```

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

## 3. Start the SDK once

```swift
import Yonc

let sdk = Yonc.start(name: "MyApp", version: "1.0")
```

Keep the returned handle for the app's lifetime; it owns the engine glue, the SDK graph and the
Turbo background continuation. The handle exposes `models` and `turbo`.

## 4. One model on the device

Turbo runs the network's tasks on a model stored on the phone, so the host has to get one there
(Turbo switched on earlier simply waits for it). The network serves a catalogue tailored to the device and names a default:

```swift
try await sdk.models.initialize()            // on-disk scan + the catalogue the network offers this device
try await sdk.models.download()              // the model the network designates as default

for await entries in sdk.models.models {     // [ModelEntry]: NotDownloaded / Downloading(progress) / Local
    render(entries)
}
try await sdk.models.delete(modelId: entry.info.id)
```

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
for await safe in sdk.turbo.safeState { … }     // isCharging / isWifi / thermal + the verdict isSafe
for await state in sdk.turbo.attestation { … }  // NotConfigured, Idle, Enrolling, Enrolled, Admitting, Unavailable, Failed
```

Turbo serves tasks only while the device is in a **safe state**: on iOS that means charging, on
Wi-Fi and thermally comfortable. A locked screen is not required: when the user locks the phone
the SDK asks iOS for a continued-processing window (a visible progress pill) and keeps serving
until iOS ends it. You observe the safe state; the SDK evaluates it.

### Battery and notifications on iOS

Nothing to request: iOS has no vendor battery managers and Turbo needs no notification
permission. The only prerequisite is the `BGTaskSchedulerPermittedIdentifiers` entry above; when
the user locks the phone iOS shows its own progress pill for the continued-processing window and
may deny or end the window at any time — the SDK stops serving cleanly and restarts the session
by itself when iOS grants a new window; you only observe `turbo.status`.

## 6. Attestation and your user id

The network verifies that a device is genuine (App Attest) before it takes part, and reports
per-user totals back to you under an id you choose. Both ride in the start call:

```swift
let sdk = Yonc.start(
    name: "MyApp",
    version: "1.0",
    attestation: AttestationConfig(
        applicationId: "<issued by YOnC for your bundle id + team>",
        externalReportingId: currentUser.opaqueId    // your own user id, 1–128 UTF-8 bytes, no surrounding whitespace
    )
)
```

- `externalReportingId` is opaque to the SDK and the network: never parsed, never logged, no
  personal data required. Changing it re-enrolls the device under the new label on the next Turbo
  start. The identity is fixed for the process lifetime in this SDK version.
- Everything operator-side ships inside the SDK; the two values above are all a host supplies.
- Without a config the device connects unattested; the network admits that only while
  enforcement is off for your application.
- On a sticky refusal the SDK parks Turbo in `AttestationFailed` and stops retrying;
  `sdk.turbo.retryAttestation()` is the user's explicit second try.
- Simulators cannot run App Attest: the state reads `Unavailable` and the device connects
  unattested.

This sample reads the two values from launch arguments (`-yoncApplicationId`, `-yoncReportingId`)
or from Info.plist keys filled by the build settings `YONC_APPLICATION_ID` /
`YONC_EXTERNAL_REPORTING_ID` — see `project.yml`.

## 7. Build and run

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

## App Store notes

- Both SDK frameworks ship privacy manifests (`PrivacyInfo.xcprivacy`): no tracking, no data
  collection, one required-reason API (file timestamps).
- The SDK uses HTTPS/TLS only — the standard `ITSAppUsesNonExemptEncryption = NO` declaration
  applies (verify against your own app's crypto usage).

## Known limitations

- Attestation needs a physical device with the App Attest entitlement; the identity is fixed at
  `Yonc.start`.
- Downloads are foreground-only and do not resume.
- If your app embeds another Kotlin/Native framework, the console warns about a duplicate Kotlin
  runtime; the warning is cosmetic, but the combination is untested — tell us if you need it.
