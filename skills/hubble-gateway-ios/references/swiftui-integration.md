# SwiftUI Integration Patterns

The recommended architecture is two layers, mirroring the official sample app (`HubbleGatewaySample`):

1. **`GatewayController`** — a reusable `@MainActor @Observable` wrapper around `HubbleGateway.shared`. Copy it verbatim from this skill's assets: [assets/GatewayController.swift](../assets/GatewayController.swift) + [assets/DiscoveredDevice.swift](../assets/DiscoveredDevice.swift). It has zero app-specific dependencies (requires iOS 17+ for `@Observable`; on iOS 16 targets convert it to `ObservableObject`/`@Published`).
2. **App-specific flow model** — alerts, blocker messages, onboarding. Write this per-app; don't try to generalize it.

## What GatewayController gives you

- Mirrors every SDK state field as observable `private(set) var`s (`permissions`, `initializationState`, `isScanning`, `gatewayId`, `lastLocation`, `lastDiagnostics`, `isBluetoothPoweredOn`, `discoveredDevices`) so views bind directly.
- Refreshes on a 5 s poll **and** on `UIApplication.didBecomeActiveNotification` — permission changes made in Settings surface without reopening the app. (Also call `refresh()` from a `scenePhase` `.active` transition if you prefer scene-based wiring.)
- Bridges `ScanListener` callbacks onto the main actor via a privately-retained `ScanCollector` (satisfies the SDK's weak-listener requirement).
- Dedupes devices into `[DiscoveredDevice]` keyed on `serviceData` (peripheral IDs rotate).
- `discoveries() -> AsyncStream<GatewayScanResult>` — independent multiplexed stream per caller, `bufferingNewest(200)`; the SDK itself only offers the listener protocol.
- `waitForBluetoothPoweredOn(timeout:)` — poll helper for the start flow (the SDK's `CBCentralManager` is deferred until BT permission is determined).

## App entry point

```swift
import SwiftUI
import HubbleGatewaySDK

@main
struct MyApp: App {
    init() {
        #if DEBUG
        let check = HubbleGateway.validateIntegration()
        if !check.isValid { assertionFailure(check.description) }
        #endif
        // Must run before launch finishes; the closure enables auto-restart
        // of scanning after process death (BGTask fire / BLE restoration).
        HubbleGateway.registerBackgroundTasks {
            guard let key = MyKeyStore.cachedSDKKey else { return nil }
            return HubbleGatewayConfig(sdkKey: key)
        }
    }
    var body: some Scene { WindowGroup { RootView() } }
}
```

Note: for the `configProvider` to work after process death the key must be available synchronously (Keychain cache) — a network fetch can't happen there.

## The start flow (permissions → start → scan)

```swift
@MainActor @Observable
final class AppModel {
    let controller = GatewayController()
    var showAlwaysExplainer = false
    var startBlocker: String?
    private var explainerContinuation: CheckedContinuation<Bool, Never>?

    func start() async {
        // 1. Host-driven permission escalation. The explainer closure shows
        //    an in-app alert before the "Always" escalation (in-app system
        //    prompt, or Settings once that one-shot prompt is consumed).
        let status = await GatewayPermissions.request(presentingAlwaysExplainer: {
            await withCheckedContinuation { cont in
                self.explainerContinuation = cont
                self.showAlwaysExplainer = true
            }
        })

        // 2. Start SDK + scanning; surface the result instead of guessing.
        do {
            try controller.configure(HubbleGatewayConfig(sdkKey: /* key */))
        } catch GatewayError.alreadyStarted {
            // fine — already running
        } catch {
            startBlocker = "\(error)"; return
        }

        let result = controller.startScanning()
        if !result.didStart {
            startBlocker = blockerMessage(for: result)
        } else if !result.isBackgroundCapable {
            // works, but foreground-only until location Always is granted
        }
        _ = await controller.waitForBluetoothPoweredOn()
        _ = status
    }

    func resolveAlwaysExplainer(escalate: Bool) {
        explainerContinuation?.resume(returning: escalate)
        explainerContinuation = nil
    }

    private func blockerMessage(for result: ScanStartResult) -> String {
        switch result.failureReason {
        case .dataCollectionDisabled: return "Data collection is turned off."
        case .missingPermissions:
            return "Missing: " + result.missingPermissions.map(\.rawValue).joined(separator: ", ")
        case .notReady, nil: return "Gateway isn't ready yet."
        // SDK enums are non-frozen (binary framework with library evolution):
        // exhaustive switches need @unknown default or they warn.
        @unknown default: return "Scanning could not start."
        }
    }
}
```

Wire the explainer alert in the view:

```swift
struct RootView: View {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack { /* sections reading model.controller.* */ }
            .alert("Background location needed", isPresented: $model.showAlwaysExplainer) {
                // Label the accept button for the path the SDK will take:
                // "Continue" → in-app "Change to Always Allow" prompt;
                // "Open Settings" once that one-shot prompt is consumed.
                Button(GatewayPermissions.isLocationAlwaysPromptAvailable ? "Continue" : "Open Settings") {
                    model.resolveAlwaysExplainer(escalate: true)
                }
                Button("Not now", role: .cancel) { model.resolveAlwaysExplainer(escalate: false) }
            } message: {
                Text("To relay beacons while the app is closed, set Location to “Always”.")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.controller.refresh() }
            }
    }
}
```

## Consuming discoveries

Bound list (already deduped and sorted by last-seen):

```swift
ForEach(model.controller.discoveredDevices) { device in
    LabeledContent(device.serviceData.map { String(format: "%02X", $0) }.joined()) {
        Text("\(device.lastRSSI) dBm · \(device.sightingCount)×")
    }
}
```

Raw event stream (analytics, pipelines — each caller gets an independent stream):

```swift
.task {
    for await result in model.controller.discoveries() {
        analytics.track(result)
    }
}
```

## Redirecting SDK logs into the app

Install the sink first in `App.init()` so startup/background-relaunch logs are captured:

```swift
@main
struct MyApp: App {
    init() {
        HubbleGateway.setLogSink(AppLogSink.shared, minLevel: .info)  // 1st
        // ... validateIntegration + registerBackgroundTasks (2nd) ...
    }
}
```

A sink that buffers off the hot path and feeds both a vendor logger and an in-app debug console:

```swift
final class AppLogSink: GatewayLogSink {
    static let shared = AppLogSink()
    private let queue = DispatchQueue(label: "gateway-logs")  // hop off the producing queue

    func log(_ entry: GatewayLogEntry) {
        queue.async {
            ThirdPartyLogger.log("[\(entry.category)] \(entry.message)", level: entry.level.rawValue)
            Task { @MainActor in DebugConsoleModel.shared.append(entry) }  // optional UI feed
        }
    }
}
```

For an in-app console view, keep a capped `@Observable` array (e.g. last 500 entries) on the main actor and render it in a `List` — mirrors how `GatewayController` buffers discoveries.

## Building a permissions UI

`GatewayPermissions.requirementsGuide()` returns an ordered `[GatewayPermissionRequirement]` (kind, rationale, required, granted) — render it directly as a checklist instead of hardcoding rows. `PermissionStatus.isReadyForBackground` is the single flag for a "background ready" indicator.

## SDK key injection for samples/dev builds

xcconfig pattern (sample-only — production apps should fetch the key from their backend):

1. `Secrets.xcconfig` (gitignored): `HUBBLE_SDK_KEY = hsk_...`; set as base configuration of the target.
2. Info.plist: `<key>HubbleSDKKey</key><string>$(HUBBLE_SDK_KEY)</string>`
3. Runtime: `Bundle.main.object(forInfoDictionaryKey: "HubbleSDKKey") as? String` — fail fast if missing or still a placeholder.
