# HubbleGatewaySDK (iOS)

A passive background BLE gateway that scans for Hubble (`0xFCA6`) and Tile
(`0xFEED`) advertisements, pairs them with the device's location, and
uploads batches on a **60 s to 15 min** cadence (foreground / moving vs.
background stationary).

## Requirements

- iOS 16.0+
- Swift 5.9+
- Xcode 15+

## Install

`Package.swift`:

```swift
.package(url: "https://github.com/HubbleNetwork/gateway-sdk-ios-releases.git", from: "0.5.0")
```

Or in Xcode: **File ▸ Add Package Dependencies…**

## Quickstart

### 1. Add these `Info.plist` keys

Purpose strings must be **specific and user-benefit framed** — vague
copy (`"This app needs your location"`) is an instant App Review
rejection (Guideline 5.1.1).

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>
  Scans for nearby Hubble Network beacon advertisements so this
  device contributes to the crowd-sourced lost-item recovery network.
</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>
  Your approximate location is paired with nearby Hubble Network
  beacon sightings so the network can help locate lost items.
</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>
  Your approximate location is paired with nearby Hubble Network
  beacon sightings so the network can help locate lost items.
</string>
<key>NSMotionUsageDescription</key>
<string>
  Detects whether the device is moving so battery usage can be
  reduced when stationary.
</string>

<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>location</string>
    <string>fetch</string>
    <string>processing</string>
</array>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.hubble.gateway.refresh</string>
    <string>com.hubble.gateway.processing</string>
    <string>com.hubble.gateway.continued</string>
</array>
```

The third `BGTaskScheduler` identifier is only consumed on iOS 26+
(user-initiated backlog drain — `HubbleGateway.requestBacklogDrain`).
Safe to list on lower deployment targets.

### 2. Register background tasks before launch finishes

```swift
import HubbleGatewaySDK

@main
struct MyApp: App {
    init() {
        // Optional debug preflight: catches mis-typed BGTask IDs and
        // missing Info.plist keys as an assertionFailure instead of
        // a runtime NSException on release.
        #if DEBUG
        let check = HubbleGateway.validateIntegration()
        if !check.isValid { assertionFailure(check.description) }
        #endif

        // The configProvider makes the gateway survive process death:
        // iOS routinely kills backgrounded apps and relaunches them
        // straight into the background. When that happens and scanning
        // was active before the kill, the SDK auto-runs start(config:)
        // + startScanning() from this closure — no user interaction.
        // Return nil to skip auto-start (e.g. not authenticated yet).
        HubbleGateway.registerBackgroundTasks {
            HubbleGatewayConfig(sdkKey: "YOUR_SDK_KEY")
        }
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

`registerBackgroundTasks(configProvider:)` **must** run before launch
completes — in `App.init()` for SwiftUI, or
`application(_:didFinishLaunchingWithOptions:)` for UIKit. The
`configProvider` is optional but strongly recommended: without it a
background relaunch leaves the SDK `.notStarted` until the user
reopens the app and starts it manually.

**Where to keep the SDK key:** the inline string above is for brevity —
anything compiled into the app is extractable from a shipped binary.
The SDK treats the key as a runtime parameter and never persists it;
it is used once, at gateway registration, after which all traffic runs
on short-lived tokens in the Keychain. For production, fetch the key
from your own backend behind your own user auth and, if you cache it
for background relaunches, keep it in your app's Keychain.

### 3. Request permissions, then start scanning

**The SDK never presents a system permission prompt on its own** —
`start(config:)` and `startScanning()` only consume whatever has
already been granted (same contract as the Android SDK, where an SDK
cannot present runtime-permission dialogs at all). You drive the
prompts, in your own UI flow, via `GatewayPermissions`:

```swift
Task { @MainActor in
    // 1. Drive the prompts. One call runs the full escalation:
    //    BT → WhenInUse → Settings round-trip for Always → Motion.
    _ = await GatewayPermissions.request {
        // Present your own alert / sheet explaining why Location
        // needs to be "Always". Return true to open Settings, false
        // to skip the escalation and stay at WhenInUse.
        await presentAlwaysExplainer()
    }

    // 2. Bring the SDK up — no prompts can fire here.
    try HubbleGateway.shared.start(config: HubbleGatewayConfig(sdkKey: "hsk_…"))

    // 3. Start scanning. The result reports what's missing instead of
    //    prompting for it.
    let result = HubbleGateway.shared.startScanning()
    if !result.didStart {
        // result.failureReason: .missingPermissions / .notReady /
        //                       .dataCollectionDisabled
        // result.missingPermissions: e.g. [.bluetooth, .locationWhenInUse]
        showPermissionScreen(missing: result.missingPermissions)
    } else if !result.isBackgroundCapable {
        // Scanning runs, but stops in background: Location is only
        // WhenInUse. result.missingPermissions == [.locationAlways].
        showAlwaysUpsell()
    }
}
```

**Prefer to drive each prompt yourself?** Call
`GatewayPermissions.requestBluetooth()`,
`GatewayPermissions.requestLocationWhenInUse()`,
`GatewayPermissions.openSettingsForLocationAlways()`, and
`GatewayPermissions.requestMotion()` in your own onboarding order.
Motion is optional — when not granted the SDK falls back to
CoreLocation-speed motion detection.

**Need a snapshot without prompting?**
`GatewayPermissions.currentStatus()` returns the current
`PermissionStatus` synchronously.
`GatewayPermissions.requirementsGuide()` returns a structured
`[GatewayPermissionRequirement]` (kind, rationale, required flag,
granted state) that's convenient for rendering a custom permissions
screen.

**Granted a permission later** (user came back from Settings while the
app was running)? Just call `startScanning()` again — the SDK also
self-heals on every foregrounding, attaching the Bluetooth central and
motion updates once their permissions are determined.

### 4. Observe sightings

The SDK emits every raw beacon sighting via a `ScanListener`. Callbacks
land on the main queue; the SDK holds listeners weakly, so keep a
strong reference yourself.

```swift
final class DevicesFeed: ScanListener {
    func onScanResult(_ result: GatewayScanResult) {
        // result.peripheralIdentifier: UUID
        // result.serviceUUID:          CBUUID  (FCA6 Hubble, FEED Tile)
        // result.serviceData:          Data
        // result.rssi:                 Int
        // result.timestamp:            Date
        // result.location:             LocationFix?  (latest cached fix, if any)
    }
    func onUploadDiagnostics(_ diagnostics: UploadDiagnostics) { … }
}

let feed = DevicesFeed()
HubbleGateway.shared.addScanListener(feed)
```

`result.location` is the SDK's most recent cached fix at delivery time —
it has **not** passed the freshness/accuracy gate that decides whether a
location is persisted with the packet, so it can be older or coarser
than what actually ships to the server (or present when the stored row
got `NULL`).

**Building a live "devices nearby" list?** The `HubbleGatewaySample`
companion app ships a `GatewayController` you can copy verbatim — it
wraps the listener, dedupes sightings by peripheral into an
`@Observable [DiscoveredDevice]` that SwiftUI binds to directly, and
exposes an `AsyncStream<GatewayScanResult>` via `discoveries()` for
reactive consumers (analytics, filtering, tests). Each `discoveries()`
call returns an independent stream; cancelling the consuming `Task`
detaches it.

## Configuration

`HubbleGatewayConfig(sdkKey:)` is the whole surface for typical
integrators. The public initializer takes only four fields — all but
`sdkKey` are optional and have sensible defaults:

```swift
let config = HubbleGatewayConfig(
    sdkKey: "hsk_…",
    respectLowPowerMode: true,
    uploadOnCellular: false,          // defer uploads until Wi-Fi
    privacyPolicyUrl: "https://your-app.com/privacy"
)
```

| Field | Default | What it controls |
|---|---|---|
| `sdkKey` | (required) | Sent in `X-Sdk-Key` on registration. |
| `respectLowPowerMode` | `true` | Skip the upload cycle when iOS Low Power Mode is on. |
| `uploadOnCellular` | `true` | Set `false` to defer uploads until Wi-Fi. Server may tighten this but not loosen it. |
| `privacyPolicyUrl` | `""` | Surface it from your own UI — the SDK stores but doesn't render. |

The API endpoint is **baked into the SDK at compile time**
(`HubbleGatewayConfig.productionAPIBaseURL`) — third-party integrators
always hit production. There is no runtime override.

### Advanced tuning (internal)

Scan/upload cadence, dedup windows, packet batch size, location-pairing
thresholds and retention are **not** part of the public initializer.
They live in an internal `AdvancedTuning` value (`config.tuning`),
matching the Android SDK. This is deliberate: several are
server-overridable at registration (so a locally-set value is only a
fallback the backend can outrank), and the rest directly govern data
quality and battery, so they aren't exposed as third-party knobs.
Defaults include a **60 s / 15 min** upload cadence (active / stationary),
**500-packet** batches, **30 s / 5 min** dedup windows (moving /
stationary), and **7-day** on-device retention (uploaded rows pruned
after 7 days; un-uploaded rows dropped after `2 ×` = 14 days).

Server-driven overrides — delivered at registration and on each
heartbeat — can retune the upload intervals, packet batch size, dedup
windows, and cellular gating at runtime, with **no app update
required**.

## Privacy & data collection

The SDK exposes two user-controllable surfaces:

```swift
// Persistent opt-out. Halts scan + location + uploads immediately; the
// SDK stays initialized but dormant. Survives app restarts.
HubbleGateway.shared.setDataCollectionEnabled(false)

// GDPR/CCPA erasure. Wipes DB rows, tokens, server-config overlay,
// upload backoff. Does NOT flip the collection toggle — pair with the
// call above for a full opt-out.
HubbleGateway.shared.deleteAllData()
```

`HubbleGateway.shared.stop()` fully unwinds the SDK back to
`.notStarted` — useful for tests or when you need to swap config at
runtime. It doesn't touch persisted state.

## App Store submission checklist

The SDK ships its own `PrivacyInfo.xcprivacy` declaring
`UserDefaults` required-reason, Precise/Coarse Location, Device ID,
Crash Data, and Other Diagnostic Data. Your host app still needs three
things before submission (Info.plist purpose strings from step 1 above
cover the fourth):

### 1. App Store Connect — privacy nutrition labels

| Apple category | Linked to user | Used for tracking | Purpose |
|---|---|---|---|
| Location ▸ Precise Location | Yes | No | App Functionality |
| Location ▸ Coarse Location | Yes | No | App Functionality |
| Identifiers ▸ Device ID | Yes | No | App Functionality |
| Diagnostics ▸ Crash Data | Yes | No | App Functionality |
| Diagnostics ▸ Other Diagnostic Data | Yes | No | App Functionality |

Motion data is intentionally **not** declared — `CMMotionActivityManager`
output drives an on-device state machine and never leaves the device.

### 2. Privacy policy URL (Guideline 5.1.2)

Set the URL in App Store Connect and make it reachable from inside the
app. It must explain:

- The device's location is recorded and shipped to Hubble's servers
  when nearby Hubble beacons are detected.
- Nearby Bluetooth advertisements (third-party device data) are
  captured and sent to Hubble's servers.
- Retention: uploaded data is pruned from the device after 7 days
  (`localRetention` config); data that could not be uploaded is kept at
  most 14 days (2 × `localRetention`) before being dropped.
- The opt-out: `HubbleGateway.shared.setDataCollectionEnabled(false)`.
- The erasure: `HubbleGateway.shared.deleteAllData()`.

Pass `privacyPolicyUrl` into `HubbleGatewayConfig(...)` and read it
back via `HubbleGateway.shared.privacyPolicyUrl` when you need to
link out from your own UI.

### 3. App Tracking Transparency (ATT)

The SDK does **not** require ATT on its own — `NSPrivacyTracking` in
its manifest is `false`, no tracking domains are contacted, and the
data is not correlated with any other identifier.

Present `ATTrackingManager.requestTrackingAuthorization` **only** if
your own app:

- Correlates Hubble data with data from other companies' apps/websites.
- Sends user identifiers to advertising networks or data brokers.
- Uses the data for cross-app personalised advertising.

If none of the above applies, **do not** show the ATT prompt — Apple
rejects unnecessary prompts (Guideline 5.1.2).

## License

Proprietary — Hubble Network, Inc.
