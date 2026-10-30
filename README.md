# HubbleGatewaySDK (iOS)

A passive background BLE gateway that scans for Hubble (`0xFCA6`)
advertisements (and Tile `0xFEED` advertisements for Tile-enabled SDK keys),
pairs them with the device's location, and uploads batches on a
**60 s to 15 min** cadence (foreground / moving vs. background stationary).

### The Hubble service UUID

`0xFCA6` is the short form of Hubble Network's Bluetooth-SIG-assigned
16-bit service UUID. In full 128-bit form it's:

```
0000FCA6-0000-1000-8000-00805F9B34FB
```

It's listed in the official [Bluetooth SIG 16-bit UUID assigned numbers
register](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/Assigned_Numbers.pdf)
(page 119).

For SDK keys enabled for the Tile network, the SDK also scans for Tile's
service UUID (`0xFEED`).

## Requirements

- iOS 16.0+
- Swift 5.9+
- Xcode 15+

## Getting an SDK key

SDK keys (`hsk_...`) are currently issued manually. To obtain one:

1. You must have a Hubble account — sign up at
   [docs.hubble.com](https://docs.hubble.com) if you don't have one yet.
2. Contact us via [support@hubble.com](mailto:support@hubble.com) to
   discuss your intended gateway deployment use case. We'll generate a
   key for your organization.

## Install

`Package.swift`:

```swift
.package(url: "https://github.com/HubbleNetwork/gateway-sdk-ios-releases.git", from: "0.7.0")
```

Or in Xcode: **File ▸ Add Package Dependencies…**

## AI-assisted integration (agent skill)

This repo ships an agent skill in [`skills/hubble-gateway-ios/`](skills/hubble-gateway-ios/)
that teaches AI coding assistants (Claude Code and other agents supporting the
skill format) the SDK's actual API surface, required project setup, permission
flow, background execution model, and troubleshooting steps. The SDK is not in
model training data — without the skill, assistants will guess at the API.

To use it with Claude Code, copy the skill into your project (or into
`~/.claude/skills/` to make it available everywhere):

```sh
git clone --depth 1 https://github.com/HubbleNetwork/gateway-sdk-ios-releases.git /tmp/hubble-sdk
mkdir -p .claude/skills
cp -R /tmp/hubble-sdk/skills/hubble-gateway-ios .claude/skills/
```

Claude Code picks it up automatically — it triggers whenever you mention
Hubble, the gateway SDK, or work in a project depending on `HubbleGatewaySDK`.
Try prompts like:

> Integrate HubbleGatewaySDK into my app, including background scanning

> Why isn't the gateway uploading when my app is in the background?

What's inside:

- `SKILL.md` — the four host-app requirements, SDK-key handling, common gotchas
- `references/api-reference.md` — the complete public API reference
- `references/swiftui-integration.md` + `assets/` — a ready-made observable
  `GatewayController` wrapper and SwiftUI wiring
- `references/background-and-troubleshooting.md` — background execution model,
  App Store submission notes, and a troubleshooting table

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
        // missing Info.plist keys as an assertionFailure, instead of
        // letting a release build register nothing and silently never
        // run a background task.
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
        // Build the SAME config here as at your foreground start() —
        // including any additionalScanServiceUUIDs. This closure is what
        // a background relaunch starts from, so a UUID you leave out here
        // is a UUID the SDK stops hearing after iOS kills the app.
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
    //    BT → WhenInUse → Always → Motion. The Always step uses the
    //    in-app system prompt ("Change to Always Allow"); it only
    //    falls back to a Settings round-trip when the user already
    //    consumed that one-shot prompt on this install.
    _ = await GatewayPermissions.request {
        // Present your own alert / sheet explaining why Location
        // needs to be "Always". Return true to continue with the
        // escalation, false to skip it and stay at WhenInUse.
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
`GatewayPermissions.requestLocationAlways()` (in-app system prompt;
check `isLocationAlwaysPromptAvailable` and fall back to
`GatewayPermissions.openSettingsForLocationAlways()` once the one-shot
prompt has been consumed), and
`GatewayPermissions.requestMotion()` in your own onboarding order.
Motion is optional — when not granted the SDK falls back to
CoreLocation-speed motion detection.

With When-In-Use the SDK works fully while your app is foregrounded:
sightings are scanned, paired with a fresh location fix and uploaded.
Always is what adds the background. `startScanning()` reports which of the
two you are in — `.startedForegroundOnly` carries `.locationAlways` in
`missingPermissions` while still having started — and
`HubbleGateway.shared.operatingMode` answers the same question at any time
afterwards: `.full`, `.foregroundOnly` or `.notOperational`. Gate your UI on
that rather than on a pair of booleans; `isFullyOperational` is kept as
shorthand for `== .full` and deliberately still reads `false` in
foreground-only mode.

**Need a snapshot without prompting?**
`GatewayPermissions.currentStatus()` returns the current
`PermissionStatus` synchronously.
`GatewayPermissions.requirementsGuide()` returns a structured
`[GatewayPermissionRequirement]` (kind, rationale, required flag,
granted state) that's convenient for rendering a custom permissions
screen.

Only Bluetooth and Location When-In-Use carry `required: true`.
`locationAlways` is reported as **`required: false`** — not because
background operation is unimportant, but because the gateway is a
working gateway without it: with When-In-Use the SDK scans, pairs
sightings with a location fix and uploads them for as long as your app
is on screen (`operatingMode == .foregroundOnly`). What Always buys is
the background, which is a product decision rather than a technical
precondition, so a checklist built on the `required` flag should present
Always as an upgrade and not as a blocker that stops the user before
they ever reach a working integration. `motion` is `required: false` for
the same kind of reason — the SDK falls back to speed-based motion
detection.

**Granted a permission later** (user came back from Settings while the
app was running)? Just call `startScanning()` again — the SDK also
self-heals on every foregrounding — and re-arms location monitoring the
moment a revoked authorization is re-granted — attaching the Bluetooth central and
motion updates once their permissions are determined.

### 4. Observe sightings

The SDK emits every raw beacon sighting via a `ScanListener`. Callbacks
land on the main queue; the SDK holds listeners weakly, so keep a
strong reference yourself.

Delivery is **per raw advertisement, before dedup**. The SDK's dedup window
applies to the rows it stores and uploads, never to what a listener sees:
nothing is merged or suppressed on the way to a `ScanListener`. An
advertisement yields **at most one** sighting of a service the SDK uploads —
`0xFCA6` first, then any other Hubble service the SDK uploads — so for
Hubble's own services that is one callback per advertisement even when the
advertisement carries service data for two of them. A scan-only service the
host added via `additionalScanServiceUUIDs` is delivered on top of that, so
an advertisement matching both fires twice.

In the foreground the scan runs with duplicates allowed, so each nearby
beacon produces **several main-queue callbacks per second**, and the total
scales with how many beacons are in range — the SDK's own foreground
profiling measured roughly 4 ingest callbacks per second (~240/min) in
aggregate. Treat that as an order of magnitude, not a per-beacon rate.
**Coalesce before touching UI**: accumulate into a dictionary keyed on
`serviceData` and render on a 500 ms–1 s timer rather than driving view
state from the callback.

```swift
final class DevicesFeed: ScanListener {
    func onScanResult(_ result: GatewayScanResult) {
        // result.peripheralIdentifier: UUID
        // result.serviceUUID:          CBUUID  (FCA6 Hubble, FEED Tile, or another scanned service)
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

> **Deduping devices? Key on `serviceData`, not `peripheralIdentifier`.**
> iOS derives the peripheral identifier from the beacon's advertised
> Bluetooth address, and Hubble beacons rotate that address — so the same
> physical beacon reappears under a new `peripheralIdentifier` after each
> rotation. The device identity lives in the `serviceData` payload.

**Building a live "devices nearby" list?** The `HubbleGatewaySample`
companion app ships a `GatewayController` you can copy verbatim — it
wraps the listener, dedupes sightings by `serviceData` into an
`@Observable [DiscoveredDevice]` that SwiftUI binds to directly, and
exposes an `AsyncStream<GatewayScanResult>` via `discoveries()` for
reactive consumers (analytics, filtering, tests). Each `discoveries()`
call returns an independent stream; cancelling the consuming `Task`
detaches it.

## Configuration

`HubbleGatewayConfig(sdkKey:)` is the whole surface for typical
integrators. The public initializer takes seven fields — all but
`sdkKey` are optional and have sensible defaults:

```swift
let config = HubbleGatewayConfig(
    sdkKey: "hsk_…",
    respectLowPowerMode: true,
    uploadOnCellular: false,          // defer uploads until Wi-Fi
    privacyPolicyUrl: "https://your-app.com/privacy",
    // Location-pairing thresholds — defaults shown; leave them out
    // unless your deployment needs something different.
    locationAccuracyFloorMeters: 50,
    movingFreshnessSeconds: 30,
    stationaryFreshnessSeconds: 30 * 60
)
```

| Field | Default | What it controls |
|---|---|---|
| `sdkKey` | (required) | Sent in `X-Sdk-Key` on registration. |
| `respectLowPowerMode` | `true` | Skip the upload cycle when iOS Low Power Mode is on. |
| `uploadOnCellular` | `true` | Set `false` to defer uploads until Wi-Fi. Server may tighten this but not loosen it. |
| `privacyPolicyUrl` | `""` | Surface it from your own UI — the SDK stores but doesn't render. |
| `locationAccuracyFloorMeters` | `50` | Fixes with a worse `horizontalAccuracy` are not paired with a sighting. |
| `movingFreshnessSeconds` | `30` | Oldest fix that may be paired while the device is moving. |
| `stationaryFreshnessSeconds` | `1800` | Oldest fix that may be paired while the device is stationary. Shorten it (a fleet might use 5 min) so a sighting after departure isn't pinned to the parking spot. |

The three location thresholds must be finite and greater than zero; any
other value is logged and the default used instead. See
[Advanced tuning](#advanced-tuning-internal) for why these three are
exposed and the neighbouring knobs are not.

The API endpoint is **baked into the SDK at compile time**
(`HubbleGatewayConfig.productionAPIBaseURL`) — third-party integrators
always hit production. There is no runtime override.

### Advanced tuning (internal)

Scan/upload cadence, dedup windows, packet batch size and retention are
**not** part of the public initializer. They live in an internal
`AdvancedTuning` value (`config.tuning`), matching the Android SDK. This
is deliberate: they are tuned as a fleet rather than per integration,
and exposing them as third-party knobs would fight that.

The location-pairing thresholds (accuracy floor, moving and stationary
freshness) are the exception: `HubbleGatewayConfig`'s initializer exposes
them directly, with defaults matching `AdvancedTuning`'s (50 m / 30 s /
30 min). Unlike the knobs above, nothing overrides these — whatever the host sets
here is final. They're exposed because the right
threshold is genuinely use-case-dependent (a warehouse deployment may
tolerate 5-minute-old, 100 m fixes; a fleet tracker needs 10-second,
20 m ones) in a way cadence/batch/dedup aren't.
Defaults include a **60 s / 15 min** upload cadence (active / stationary),
**500-packet** batches, **30 s / 5 min** dedup windows (moving /
stationary), and **7-day** on-device retention (uploaded rows pruned
after 7 days; un-uploaded rows dropped after `2 ×` = 14 days).

The one scan knob on the public initializer is `additionalScanServiceUUIDs`:
extra service UUIDs the SDK should hear, given as 16-, 32- or 128-bit
strings. They are **scan-only**. Advertisements that match reach your
`ScanListener` like any other sighting. Adding a UUID here never makes the
SDK store or upload it, request a location fix for it or start an upload
cycle on its account, so adding one does not change what Hubble receives
or what the scan costs in network and battery.
`0xFCA6` is always scanned. It and the other services your SDK key is
enabled for (such as Tile's `0xFEED`) are the only ones the SDK stores and
uploads — anything else the scan matches stays listeners-only.
Malformed entries are ignored with a log line; duplicates are dropped. At most
**6** extra UUIDs are accepted (hardware scan-filter slots are limited per
chipset, and the SDK already spends some on its own services); anything past that
is dropped with a log line rather than silently bloating the filter. Typical
use: a service a tag advertises only when it needs attention from the host
app, so the app can react without running a second scanner. Because iOS
background scanning requires an explicit service filter, this is also the
only way such a service can wake the app while it is suspended.

## Understanding log messages

All SDK log lines are tagged `GSDK:` and go through `os.Logger`
(subsystem `com.hubble.gateway`). Watch live with:

```
log stream --predicate 'subsystem == "com.hubble.gateway"'
```

Lines logged at `.notice`/`.error` are persisted to disk and can be
recovered after the fact (e.g. after an unattended field test) with:

```
sudo log collect --device --last 30m
```

Lines at `.info`/`.debug` are memory-buffered only and won't survive
being collected later — they're for live streaming while attached.

### Redirecting logs to your own destination

Install a `GatewayLogSink` to receive every SDK log line in-process and
forward it wherever you like (a file, Datadog/Sentry, an in-app debug
console):

```swift
final class MyLogSink: GatewayLogSink {
    func log(_ entry: GatewayLogEntry) {
        // entry.level (.debug/.info/.notice/.error), entry.category
        // ("ble", "location", "upload", "storage", "lifecycle"),
        // entry.message, entry.timestamp
        myLogger.write("[\(entry.category)] \(entry.message)")
    }
}

// In App.init(), BEFORE registerBackgroundTasks — that ordering also
// captures startup and background-relaunch logs:
HubbleGateway.setLogSink(MyLogSink(), minLevel: .info)
```

Contract: the sink is called synchronously on arbitrary queues — keep it
fast and thread-safe (buffer, don't do I/O inline). `minLevel` filters
SDK-side (default `.info`; `.debug` is per-advertisement volume — opt in
only while actively debugging). The sink is additive — os.log output and
the SDK's diagnostics upload keep working — and is retained strongly;
pass `nil` to remove it. Note that entries can include location
coordinates and device identifiers, so treat downstream storage
accordingly.

| Log line | Level | Meaning |
|----------|-------|---------|
| `ingest svc=… bytes=… rssi=… motion=… loc=ok` | `.debug` | A scan result was stored with a usable location fix attached. |
| `ingest … loc=nil` | `.debug` | No cached location fix exists yet at all — packet is held with `location_json = NULL`, excluded from upload until a fix arrives. |
| `ingest … loc=stale` | `.debug` | Cached fix is older than the backfill window (30 min stationary / 30 s moving) — packet held, and a one-shot fresh-fix request is triggered. |
| `ingest … loc=invalid` | `.debug` | Cached fix has a negative `horizontalAccuracy` (CoreLocation's invalid-position sentinel) — packet held. |
| `ingest … loc=inaccurate` | `.debug` | Cached fix exists but exceeds the 50 m accuracy threshold — packet held. |
| `ingest … loc=future` | `.debug` | Cached fix has a timestamp in the future (clock skew) — rejected, packet held. |
| `no eligible packets (pending=N, noLocation=M)` | `.notice` | Upload cycle ran but found nothing to send. `M` is how many of the `N` pending rows are held back *solely* by the `location_json IS NOT NULL` claim filter. `M` ≈ `N` cycle after cycle while BLE is finding things means the problem is location pairing, not the uploader — cross-reference the `ingest … loc=` lines above for which gate rejected the fix. |
| `no eligible locations (pending=…, uploading=…, failed=…) — <reason>` | `.notice` | Same idea for the independent `/locations` upload stream; `<reason>` spells out why (no fixes captured yet, already uploaded, in backoff, etc). |
| `posting N packets` / `posting N locations` | `.notice` | A batch is being sent to the server. |
| `Upload failed [stage]: <class>` | `.error` / `.notice` | An upload stage failed; `stage` is `packets`/`locations`/`logs`/`heartbeat`/`cycle` and `<class>` the error class (`urlerror -1001`, `http 503`, `token revoked`, …). Error-level the first time a stage fails with a given class; a repeat of the same class on that stage stays `.notice` until it recovers or the class changes. |
| `Backing off N s after failure #K` / `Upload cycle recovered — clearing backoff` | `.info` | The cycle-level backoff being armed after a failing cycle, and cleared by the first clean one. |
| `HubbleGateway ready` / `... (dormant — data collection disabled)` | `.notice` | SDK finished `start()`; the dormant variant means `isDataCollectionEnabled == false`. |
| `auto-started from persisted scanning intent` | `.notice` | Process was killed and relaunched by iOS; the SDK resumed scanning on its own because a scanning intent was persisted from before the kill. |
| `Motion state -> moving/stationary (natural=…, override=…)` | `.notice` | Motion classification changed — drives location accuracy/cadence and dedup window width. |
| `Priming location fix (start_scanning)` / `(will_enter_foreground)` | `.info` | The SDK asked for a fix outside the per-sighting path, because `startScanning()` ran or the app came back on screen. Only logged when a request actually fired — a fresh enough cache, a refresh already in flight, or a recent failure all suppress it silently. |
| `One-shot fresh fix delivered but still above the accuracy floor — backing off` | `.notice` | The SDK asked for a precise fix, got one, and it is still too imprecise to pair with a packet (typically indoors). Further requests pause briefly rather than repeating per sighting. Persistent occurrences mean the device cannot currently produce a fix good enough to upload with. |
| `One-shot fresh fix was coarser than the cached fix — keeping the cache, backing off` | `.notice` | Same situation, other side: the fix that came back is wider than the one already cached, so the SDK keeps the cached one and pauses before asking again. Also typical indoors, and likewise not an error. |
| `Triggering one-shot fresh fix (cached older than Ns)` / `One-shot fresh fix delivered` | `.notice` | The stale-fix recovery path: a cached fix aged out, so the SDK requested (and then received) a fresh one-off `CLLocation` update outside the normal continuous/SLC stream. |
| `Authorization changed to N` / `Cannot start — authorization=N` | `.info` / `.error` | CoreLocation authorization status changed; see [`CLAuthorizationStatus`](https://developer.apple.com/documentation/corelocation/clauthorizationstatus) for what `N` maps to. |
| `Authorization restored — re-armed significant-change monitoring` | `.notice` | Location permission was revoked and re-granted while the gateway was running; the SDK re-armed its location wake source automatically — no action needed. |
| `background refresh/processing task not scheduled — …` | `.error` | The SDK could not schedule a background task because the host app's integration is incomplete: the task identifier is missing from `BGTaskSchedulerPermittedIdentifiers`, `registerBackgroundTasks()` did not run before launch finished, or iOS rejected the submit. That task will not run on its BGTask schedule until it is fixed; other tasks, and uploads triggered by foreground activity or the BLE/location wake paths, are unaffected. The line names the one fix that applies; `validateIntegration()` can confirm a missing Info.plist key, but it reads the Info.plist only, so it will not flag a missing `registerBackgroundTasks()` call. Reported once per identifier per cause per launch, not on every attempt. |
| `background … task not scheduled — background scheduling is unavailable on this device` | `.notice` | Not an integration problem: Background App Refresh is switched off for the app, the device is restricted, or this is the Simulator. Nothing to fix in code. |
| `iOS declined BGTask registration — …` | `.error` | iOS declined to register a handler at launch — either the SDK's identifiers are not declared in `BGTaskSchedulerPermittedIdentifiers`, or something else registered them first. Emitted once, at `registerBackgroundTasks()`. |
| Any `Log.error` line (network/decode/DB failures) | `.error` | Always persisted regardless of level — these are the only lines guaranteed to survive today without the `.notice` promotions above. |

The `ingest …` lines are `.debug`: they fire once per BLE advertisement, so
they are neither written to the unified log's persistent store nor shipped
with the SDK's diagnostics. They will **not** appear in a `log collect`
archive. Read them live instead:

```bash
log stream --device --predicate 'subsystem == "com.hubble.gateway"' --level debug
```

Everything at `.notice` and above is persisted and survives in a collected
archive, so day-to-day field diagnosis does not depend on the debug stream.

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

The opt-out is a gate, not just a stop: while it is off, `startScanning()`
returns `.dataCollectionDisabled` without starting anything, and discovered
advertisements are dropped before they are stored, uploaded, or delivered
to a `ScanListener`. Turning it back on re-arms the SDK but does **not**
resume scanning by itself — call `startScanning()` when the user opts back
in.

Note that `stopScanning()` clears the *persisted* scanning intent, so
background auto-resume after process death stays off until `startScanning()`
is called again. Treat it as a user-intent switch, not a screen-lifecycle
pause: a UI that stops needing results should call
`removeScanListener(_:)` and leave the scan running.

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

Proprietary — Hubble Network, Inc. Licensed under the Hubble SDK License — see [LICENSE](LICENSE).

Third-party notices: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
