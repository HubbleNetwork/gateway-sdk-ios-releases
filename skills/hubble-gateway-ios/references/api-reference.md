# HubbleGatewaySDK — Public API Reference

SDK version 0.7.1. Everything below is the complete public surface — if a symbol isn't here, it doesn't exist; don't invent methods. All types live in `import HubbleGatewaySDK`. The main class and `GatewayPermissions` are `@MainActor`-isolated.

## HubbleGateway (main entry point)

`@MainActor public final class HubbleGateway` — singleton: `HubbleGateway.shared`.

### State properties (read-only)

| Property | Type | Notes |
|---|---|---|
| `initializationState` | `InitializationState` | `.notStarted / .initializing / .ready / .failed` |
| `isScanning` | `Bool` | BLE scan currently active |
| `operatingMode` | `GatewayOperatingMode` | `.full` / `.foregroundOnly` / `.notOperational` — one value, mutually exclusive; see below |
| `isFullyOperational` | `Bool` | shorthand for `operatingMode == .full`: ready + collection enabled + BT authorized & powered on + location `.authorizedAlways` |
| `isDataCollectionEnabled` | `Bool` | persistent user opt-out flag |
| `gatewayId` | `String?` | assigned at registration |
| `isRegistered` | `Bool` | |
| `activeGroupHash` | `String?` | SHA-256 hex of the Group ID in effect (the dashboard's group hash; the fallback's while it is in use); never the Group ID itself; nil before `start` |
| `isUsingFallbackGroupId` | `Bool` | running under `fallbackSdkKey` (primary empty or refused with 401) |
| `isGatewayDisabled` | `Bool` | registration answered 403 `gateway_disabled`; nothing new uploaded, retried hourly |
| `lastLocation` | `LocationFix?` | |
| `isBluetoothPoweredOn` | `Bool` | false until permission determined (CBCentralManager is deferred) |
| `isActiveScanningOverride` | `Bool` | active (high-cadence) mode pinned |
| `privacyPolicyUrl` | `String?` | from config |

### Lifecycle & control

```swift
// Call before app launch finishes. configProvider enables auto-restart after process death.
static func registerBackgroundTasks(configProvider: (@Sendable @MainActor () -> HubbleGatewayConfig?)? = nil)

func start(config: HubbleGatewayConfig) throws   // GatewayError.alreadyStarted if already started
@discardableResult func startScanning() -> ScanStartResult
func stopScanning()                               // user-intent switch, NOT a screen pause — see below
func stop()                                       // full unwind to .notStarted; keeps queue, toggle AND registration
func registerIfNeeded() async throws
@discardableResult func changeGroupId(_ groupId: String) async -> GroupChangeResult // switch Gateway Group — see below
func setDataCollectionEnabled(_ enabled: Bool)    // persistent opt-out
func deleteAllData()                              // GDPR/CCPA erasure; does NOT change the opt-out flag
func addScanListener(_ listener: ScanListener)    // ⚠️ held WEAKLY — keep your own strong ref or you get NO callbacks
func removeScanListener(_ listener: ScanListener)
func uploadDiagnostics() async throws -> UploadDiagnostics
func startActiveScanning()                        // pin fast cadence: 60 s uploads, 30 s dedup, high-precision GPS
func stopActiveScanning()
@available(iOS 26.0, *)
func requestBacklogDrain(title: String, subtitle: String) throws  // user-initiated BGContinuedProcessingTask

// Preflight config check — nonisolated static, safe anywhere
static func validateIntegration(bundle: Bundle = .main) -> IntegrationCheckResult

// Redirect SDK logs to a host-owned destination. nonisolated static —
// install in App.init() BEFORE registerBackgroundTasks to also capture
// startup/background-relaunch logs. Sink retained STRONGLY; nil removes.
static func setLogSink(_ sink: GatewayLogSink?, minLevel: GatewayLogEntry.Level = .info)
```

**`GatewayOperatingMode`** — `.full` when everything is granted including background location; `.foregroundOnly` when location is `.authorizedWhenInUse`, which is a **supported mode, not a broken one**: scanning, location pairing and upload all work exactly as in `.full` while the app is foregrounded, and stop when it is backgrounded; `.notOperational` when the SDK is not started, data collection is off, Bluetooth is unauthorized or powered off, or location was never granted. Read it live (it reflects Settings changes made while backgrounded) and `switch` on it rather than pairing booleans. It says which mode you are in, not what is missing — for that use `GatewayPermissions.currentStatus()`, a `ScanStartResult`'s `missingPermissions`, or `validateIntegration()`.

**`changeGroupId(_:)`** switches a running SDK to another Gateway Group ID — no `stop()`/`start()`/`deleteAllData()`. Same ID as the one in effect: no-op (no network, queue untouched). Different ID: new sightings and location fixes belong to the new group at once, and — when data collection is enabled — the device registers under the new group before the call returns (`gatewayId` changes). **Unsent sightings and location fixes of the previous group are still uploaded, under the previous group's registration** (never under the new one): it stays current until the new registration succeeds, then is kept aside until its data is uploaded, its credentials stop working, or 7 days pass (the rest is then dropped). If that group is revoked or this device's gateway is disabled before its data is uploaded, the data is dropped (same for a primary revoked while the SDK moves to `fallbackSdkKey`) — never uploaded under another group. Scanning, the opt-out toggle, listeners and background tasks are untouched. Never throws; returns `GroupChangeResult`: `.unchanged`, `.switched`, `.switchedToFallback`, `.switchedPendingRegistration(reason)` (switch in effect, registration pending: `dataCollectionDisabled` / `uploadsRestricted` / `networkError` / `serverError` / `groupIdRefused` / `gatewayDisabled`; the SDK retries on its own, no backoff — a disabled gateway hourly) or `.notApplied(reason)` (`notStarted` / `emptyGroupId`, nothing changed). Handle future cases with `@unknown default`. `start(config:)` with a Group ID different from the stored registration's behaves the same way. The SDK does not persist the Group ID: the `registerBackgroundTasks` `configProvider` must return the Group ID last switched to, or a background relaunch switches back.

**`fallbackSdkKey`** — used when `sdkKey` is empty or registration with it is refused (HTTP 401), including after the current registration dies and re-registering with `sdkKey` is refused. Never on 403 `gateway_disabled` (the device was disabled — see `isGatewayDisabled`), network errors, 429 or 5xx. While on it, `sdkKey` is retried hourly and on every `start`/`changeGroupId`; data never crosses between the two Group IDs. For an app that moves users between an organization's group and a shared one, pass the organization's ID as `sdkKey` and the shared one as `fallbackSdkKey`.

**`stopScanning()` is not a lifecycle pause.** It clears the *persisted*
scanning intent — the flag the SDK reads on a background relaunch to decide
whether to resume after process death. A host that calls it when its scan
screen closes silently disables background auto-resume until something calls
`startScanning()` again. It means "the user is done contributing for now",
not "my screen closed".

There is no pause API, and none is needed: the SDK runs one continuous scan
in foreground *and* background, so a screen that stops wanting results should
just `removeScanListener(_:)` and leave the scan running.

## HubbleGatewayConfig

```swift
public struct HubbleGatewayConfig: Sendable {
    init(sdkKey: String,
         fallbackSdkKey: String = "",              // backup Group ID: used when sdkKey is empty or refused (401)
         respectLowPowerMode: Bool = true,
         uploadOnCellular: Bool = true,
         privacyPolicyUrl: String = "",
         locationAccuracyFloorMeters: Double = 50,         // fixes worse than this are not paired
         movingFreshnessSeconds: TimeInterval = 30,        // max fix age while moving
         stationaryFreshnessSeconds: TimeInterval = 30 * 60,  // max fix age while stationary
         additionalScanServiceUUIDs: [String] = [])        // scan-only, e.g. ["FCA7"], max 6
    // The three thresholds are host-owned (no server override); invalid values
    // (zero, negative, non-finite) are logged and replaced by the defaults.

    /// Accepted entries after validation and dedup.
    let additionalScanServiceUUIDs: [CBUUID]
}
```

The API base URL is compile-time baked (`https://gw-api.hubble.com`) — no runtime override for integrators. Cadence/dedup/batch tuning is internal and not host-configurable. **This is about configuration only — it does not mean listener delivery is deduped.** Scan listeners receive *every* sighting the scanner emitted, before any dedup; dedup governs local storage and upload, nothing above it. The location-quality thresholds (accuracy floor, moving/stationary freshness) are the exception: they are set on the initializer above and are host-owned, so the value the host passes is the value used. `additionalScanServiceUUIDs` widens the scan filter only: matching advertisements are delivered to `ScanListener`, and adding a UUID never makes the SDK store or upload it. `FCA6` is always scanned; only it and the other services the Gateway Group ID is enabled for (such as Tile's `FEED`) are ever stored and uploaded, so any other service the scan happens to match stays listeners-only. Malformed UUID strings are ignored with a log line; duplicates are dropped; at most 6 extra UUIDs are kept, the rest logged and dropped.

## GatewayPermissions

`@MainActor public enum GatewayPermissions` — the SDK never presents system prompts; the host drives them here.

```swift
// Synchronous status reads (no prompt)
static func currentStatus() -> PermissionStatus
static func bluetoothStatus() -> BluetoothAuthorization
static func locationStatus() -> LocationAuthorization
static func motionStatus() -> MotionAuthorization
static func requirementsGuide() -> [GatewayPermissionRequirement]  // ordered checklist for building UI
// Only .bluetooth and .locationWhenInUse are `required: true`.
// .locationAlways is `required: false`: with When-In-Use the SDK scans,
// pairs fixes and uploads while the app is on screen
// (`operatingMode == .foregroundOnly`), so Always buys the background
// rather than being a precondition — render it as an upgrade, not a
// blocker. .motion is `required: false` too (speed-based fallback).

// One-call escalation: BT → Location WhenInUse → Always → Motion.
// The Always step uses the in-app system prompt ("Change to Always Allow")
// when still available, falling back to a Settings round-trip once that
// one-shot prompt has been consumed on this install.
// presentingAlwaysExplainer: show your in-app rationale; return true to
// proceed with the escalation.
static func request(
    presentingAlwaysExplainer: @MainActor () async -> Bool = { true },
    bluetoothTimeout: TimeInterval = 30,
    locationTimeout: TimeInterval = 30,
    settingsReturnTimeout: TimeInterval = 120,
    motionTimeout: TimeInterval = 30
) async -> PermissionStatus

// Individual steps if you need custom flow
static func requestBluetooth(timeout:) async -> BluetoothAuthorization
static func requestLocationWhenInUse(timeout:) async -> LocationAuthorization
static func requestMotion(timeout:) async -> MotionAuthorization
// In-app "Change to Always Allow" prompt. No-ops once the one-shot prompt
// was consumed — check isLocationAlwaysPromptAvailable, then fall back to
// openSettingsForLocationAlways.
static func requestLocationAlways(timeout:) async -> LocationAuthorization
static var isLocationAlwaysPromptAvailable: Bool
static func openSettingsForLocationAlways(timeout:) async -> LocationAuthorization  // fallback path
```

```swift
public struct PermissionStatus: Sendable {
    let bluetooth: BluetoothAuthorization    // notDetermined/denied/restricted/authorized/unknown
    let location: LocationAuthorization      // notDetermined/denied/restricted/authorizedWhenInUse/authorizedAlways
    let motion: MotionAuthorization          // notDetermined/denied/restricted/authorized
    var isReady: Bool                        // enough to scan in foreground
    var isReadyForBackground: Bool           // requires location .authorizedAlways
}

public struct GatewayPermissionRequirement: Sendable, Equatable {
    enum Kind: String { case bluetooth, locationWhenInUse, locationAlways, motion }
    let kind: Kind
    let rationale: String
    let required: Bool          // motion is false
    let requestOrder: Int       // 0…3
    let requiresSeparateRequest: Bool
    let granted: Bool
}
```

## ScanStartResult

```swift
public struct ScanStartResult: Sendable, Equatable {
    let didStart: Bool
    let missingPermissions: [GatewayPermissionRequirement.Kind]
    let failureReason: FailureReason?        // .notReady / .dataCollectionDisabled / .missingPermissions
    var isBackgroundCapable: Bool            // false ⇒ foreground-only until Always granted
}
```

## ScanListener & diagnostics

```swift
public protocol ScanListener: AnyObject, Sendable {
    func onScanResult(_ result: GatewayScanResult)             // main queue
    func onUploadDiagnostics(_ diagnostics: UploadDiagnostics) // default no-op
}
```

**Delivery is per raw advertisement, above dedup.** Nothing is merged or suppressed on the way to the listener; the dedup window applies only to the rows the SDK stores and uploads. The unit is one callback per *sighting the scanner emitted*, and one advertisement yields **at most one** sighting of a service the SDK uploads: `0xFCA6` first, then any other Hubble service the SDK uploads, and the first of those with usable service data wins. So an advertisement carrying service data for two uploaded services produces **one** callback, not two (`UploadDiagnostics.multiPayloadAdvertisements` counts those). A host scan-only UUID added via `additionalScanServiceUUIDs` is emitted on top of the payload sighting, so an advertisement matching both fires twice. A host scan-only service the advertisement lists without service data (advertised by UUID alone) is delivered with **empty** `serviceData`; such a sighting is never stored or uploaded. Skip empty `serviceData` before keying on it.

That delivery contract is what makes a live scan UI possible (RSSI moves, every rotated `serviceData` payload arrives), and it is also the cost: in the foreground `CBCentralManagerScanOptionAllowDuplicatesKey` is honored, so each nearby beacon delivers **several callbacks per second**, and the aggregate scales with how many beacons are in range. The SDK's own foreground profiling of this path measured roughly **4 callbacks per second (~240/min)** in aggregate, over an unrecorded number of beacons — an order-of-magnitude figure, not a per-beacon rate and not a ceiling.

Callbacks arrive on the **main queue**. Hosts must coalesce before touching UI — accumulate into a dictionary keyed on `serviceData` and render on a timer (500 ms–1 s is plenty); do not drive SwiftUI state directly from the callback.

The listener is held **weakly** (see `addScanListener` above) and `onUploadDiagnostics` has a default no-op implementation.

There is no AsyncStream in the SDK — the listener protocol is the only delivery mechanism. Build a stream adapter in the host (see swiftui-integration.md).

## GatewayLogSink (log redirection)

```swift
public struct GatewayLogEntry: Sendable {
    public enum Level: String, Sendable, CaseIterable, Comparable { case debug, info, notice, error } // debug < info < notice < error
    public let level: Level
    public let category: String   // "ble" | "location" | "upload" | "storage" | "lifecycle"
    public let message: String
    public let timestamp: Date
}

public protocol GatewayLogSink: AnyObject, Sendable {
    func log(_ entry: GatewayLogEntry)
}
```

Install with `HubbleGateway.setLogSink(mySink, minLevel: .info)`. Delivery contract: called **synchronously on arbitrary queues** — implementations must be thread-safe and fast (buffer, never do I/O inline). Additive: os.log output and the SDK's diagnostics upload continue unchanged. Unlike `ScanListener`, the sink is retained **strongly**. `.debug` is per-advertisement volume — opt in only for live debugging. Entries can contain location coordinates and device identifiers.

```swift
public struct UploadDiagnostics: Sendable, Codable {
    let pendingPackets, uploadingPackets, failedPackets: Int
    let pendingLocations, uploadingLocations, failedLocations: Int
    let lastUploadAt, lastLocationsUploadAt, lastLogsUploadAt: Date?
    let lastHeartbeatAt: Date?            // last successful backend check-in; in memory, resets with the process
    let lastUploadError: String?
    let lastSuccessfulBatchSize: Int
    let bytesUploadedLast24h: Int64
    let skipUntil: Date?      // cycle backoff / server Retry-After window
    let multiPayloadAdvertisements: Int     // ads carrying data for >1 uploaded service; only one (FCA6 first) became a sighting
    let strippedPayloadAdvertisements: Int  // callbacks listing an uploaded service without its service data — an upper bound on iOS background stripping
    let activeGroupHash: String?            // SHA-256 hex of the Group ID in effect (same as HubbleGateway.activeGroupHash)
    let isUsingFallbackGroupId: Bool        // running under fallbackSdkKey
    let isGatewayDisabled: Bool             // this device's gateway is disabled in the active group (403)
}
```

Both advertisement counters are in-memory, count since `start(config:)` and are reset by `deleteAllData()`.

## Models

```swift
public struct GatewayScanResult: Sendable, Equatable {
    let peripheralIdentifier: UUID   // ROTATES — do not use as device identity
    let serviceUUID: CBUUID          // 0xFCA6 (Hubble), 0xFEED (Tile), or another scanned service
    let serviceData: Data            // stable device identity — dedup on this (empty: host scan-only service listed without data)
    let rssi: Int
    let timestamp: Date
    let location: LocationFix?
}

public struct LocationFix: Sendable, Equatable, Codable {
    let latitude, longitude, horizontalAccuracy, verticalAccuracy,
        altitude, speed, bearing: Double
    let timestamp: Date
}

public enum InitializationState: String, Sendable { case notStarted, initializing, ready, failed }
```

## Errors

```swift
public enum GatewayError: Error, Sendable, CustomStringConvertible {
    case notStarted, alreadyStarted
    case bluetoothUnauthorized, bluetoothUnsupported, locationUnauthorized
    case registrationFailed(underlying: String)
    case uploadFailed(status: Int, body: String?, retryAfter: TimeInterval?)
    case tokenRevoked, tokenExpired
    case persistenceFailure(String)
    case invalidConfig(String)
}
```

## IntegrationCheck

```swift
public struct IntegrationCheckResult { let isValid: Bool; let hasWarnings: Bool; let issues: [IntegrationIssue] }
public struct IntegrationIssue { let severity: Severity; let key: String; let message: String }
public enum Severity { case error, warning }
```

## Auth model

Only auth input is `sdkKey`, sent once as `X-Sdk-Key` at registration; the server returns short-lived device + refresh tokens stored in Keychain (service `com.hubble.gateway`). Token refresh is automatic and serialized. There is no delegated-auth or OAuth option in 0.7.1.
