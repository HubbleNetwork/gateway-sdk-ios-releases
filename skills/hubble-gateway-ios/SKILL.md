---
name: hubble-gateway-ios
description: Integrate the Hubble Network Gateway iOS SDK (HubbleGatewaySDK) into an iOS app — installation, Info.plist and background-mode setup, permission flow, starting/stopping the gateway, observing discovered BLE devices in SwiftUI, diagnostics, and troubleshooting. Use this skill whenever the user mentions Hubble, HubbleGateway, gateway SDK, turning an app into a BLE gateway, scanning for Hubble/Tile beacons, or is working in a project that depends on HubbleGatewaySDK — even if they only ask a small question about permissions, background scanning, or upload behavior. Do not guess this SDK's API from memory; it is not in training data.
---

# Hubble Gateway iOS SDK Integration

HubbleGatewaySDK turns a host iOS app into a BLE gateway: it scans for Hubble (0xFCA6) and Tile (0xFEED) beacon advertisements, pairs them with location fixes, and uploads batches to Hubble's network — in the foreground and background. The SDK does heavy lifting internally (adaptive scanning, dedup, batching, retry/backoff, BGTask scheduling, Keychain token management), but it deliberately never presents permission prompts and never configures the host project — the host app must do four things correctly, listed below.

**iOS 16+, Swift Package.** Add via SwiftPM: `https://github.com/HubbleNetwork/gateway-sdk-ios-releases.git`, product `HubbleGatewaySDK`. All public API is `@MainActor` and accessed through the singleton `HubbleGateway.shared`. Note: the SDK supports iOS 16, but the bundled `GatewayController` asset uses `@Observable` (iOS 17+) — for an iOS 16 deployment target convert it to `ObservableObject`/`@Published` before use.

## Reference files — read before writing code

- **[references/api-reference.md](references/api-reference.md)** — full public API surface: `HubbleGateway`, `HubbleGatewayConfig`, `GatewayPermissions`, `ScanListener`, models, errors. Read this before calling any SDK method; do not invent signatures.
- **[references/swiftui-integration.md](references/swiftui-integration.md)** — the recommended `@Observable` wrapper (`GatewayController`) with AsyncStream device feed, plus app-entry and permission-flow code. Read when wiring the SDK into SwiftUI views.
- **[references/background-and-troubleshooting.md](references/background-and-troubleshooting.md)** — background execution model, upload cadence, known issues, App Store submission notes, and a troubleshooting table. Read when the user asks "why isn't it scanning/uploading in the background" or prepares a release.

## The four non-negotiable host requirements

Integration failures almost always trace to one of these. Verify all four before debugging anything else.

### 1. Info.plist keys

```xml
<!-- Usage strings (all four required; motion is optional at runtime but the string must exist) -->
<key>NSBluetoothAlwaysUsageDescription</key>          <string>…</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>…</string>
<key>NSLocationWhenInUseUsageDescription</key>         <string>…</string>
<key>NSMotionUsageDescription</key>                    <string>…</string>

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

No entitlements file changes and no App Tracking Transparency prompt are needed (`NSPrivacyTracking` is false; the SDK bundles its own privacy manifest).

### 2. Register background tasks before launch finishes

In `App.init()` (or `application(_:didFinishLaunchingWithOptions:)`):

```swift
init() {
    #if DEBUG
    let check = HubbleGateway.validateIntegration()
    if !check.isValid { assertionFailure(check.description) }
    #endif

    HubbleGateway.registerBackgroundTasks {
        HubbleGatewayConfig(sdkKey: /* fetch or read key */)
    }
}
```

The `configProvider` closure is what lets the SDK auto-restart scanning after process death (BGTask fire or BLE state restoration). Omitting it means background relaunches silently do nothing. `validateIntegration()` catches missing plist keys/modes/IDs at first run — always include it behind `#if DEBUG`.

### 3. Host-driven permission flow

The SDK never prompts. Escalation order matters (Bluetooth → Location When-In-Use → Always → Motion), and `GatewayPermissions.request(presentingAlwaysExplainer:)` drives the whole sequence in one call — the closure is your chance to show an in-app rationale before the "Always" escalation. That escalation uses the in-app system prompt ("Change to Always Allow") when it's still available; iOS shows that upgrade prompt only once per install, so once it's been consumed the SDK falls back to a Settings round-trip (`isLocationAlwaysPromptAvailable` tells you which path applies). Background operation requires location **Always**; motion is optional (the SDK falls back to CoreLocation-speed-based motion detection).

### 4. Start, then check the result

```swift
try HubbleGateway.shared.start(config: HubbleGatewayConfig(sdkKey: key))
let result = HubbleGateway.shared.startScanning()
if !result.didStart { /* inspect result.failureReason / result.missingPermissions */ }
if !result.isBackgroundCapable { /* warn: works foreground-only until Always granted */ }
```

`startScanning()` never throws — it returns a `ScanStartResult` you must inspect and surface to the user.

## Redirecting SDK logs (GatewayLogSink)

When the user wants SDK logs in their own pipeline (file, Datadog/Sentry, in-app debug console) — or is debugging and wants to see what the SDK does — install a log sink:

```swift
final class MySink: GatewayLogSink {
    func log(_ entry: GatewayLogEntry) { /* level, category, message, timestamp */ }
}
// In App.init(), BEFORE registerBackgroundTasks — captures startup and
// background-relaunch logs too:
HubbleGateway.setLogSink(MySink(), minLevel: .info)
```

Rules that matter: the sink is called **synchronously on arbitrary queues** — keep it fast and thread-safe, buffer instead of doing I/O inline. It is retained **strongly** (unlike `ScanListener`); `nil` removes it. `minLevel: .debug` is per-advertisement volume — recommend it only for live debugging sessions. Additive: os.log output and Hubble's diagnostics upload continue unchanged. Entries can contain coordinates and device identifiers — flag that to the user if they forward logs to third parties. Full contract in [references/api-reference.md](references/api-reference.md).

## SDK key handling

SDK keys are issued manually: the integrator needs a Hubble account and should contact [support@hubble.com](mailto:support@hubble.com) to discuss their gateway deployment use case and get a key generated for their organization.

The `sdkKey` (`hsk_…`) is used once at registration (`X-Sdk-Key` header); afterwards the SDK runs on short-lived Keychain tokens. For samples/prototypes an xcconfig → Info.plist injection is fine (see the sample app's `Secrets.xcconfig` pattern), but for production apps recommend fetching the key from the customer's backend after their own auth, then passing it to `start(config:)` at runtime — a key baked into the binary is extractable.

Critical constraint: the `configProvider` closure passed to `registerBackgroundTasks` runs on background process relaunch, before any network call is possible — the key must be available **synchronously** there (cache it in the Keychain after the first backend fetch). A provider that returns nil because the key isn't cached silently disables background auto-restart.

## Gotchas that bite everyone

- **Dedup devices on `serviceData`, not `peripheralIdentifier`** — Hubble beacons rotate their advertised BLE address, so the peripheral UUID changes; `serviceData` is the stable identity.
- **Keep a strong reference to your `ScanListener`** — the SDK holds listeners weakly; a listener created inline is deallocated immediately and you get no callbacks.
- **BLE scanning does not work in the Simulator** — always test on a real device.
- **`isBluetoothPoweredOn` stays false until the permission flow runs** — the SDK defers creating its `CBCentralManager` until Bluetooth permission is determined; don't treat it as a radio check before requesting permissions.
- **Config is one-shot** — `start(config:)` throws `GatewayError.alreadyStarted` on a second call; call `stop()` first if reconfiguring. Upload cadence, dedup windows, and batch sizes are internal/server-driven, not host-configurable.
- **User-facing privacy controls** — `setDataCollectionEnabled(false)` is the persistent opt-out; `deleteAllData()` is GDPR/CCPA erasure (it does *not* flip the opt-out toggle). Ship both if the app has a privacy settings screen.
