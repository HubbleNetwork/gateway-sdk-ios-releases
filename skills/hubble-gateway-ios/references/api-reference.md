# HubbleGatewaySDK — Public API Reference

SDK version 0.6.4. Everything below is the complete public surface — if a symbol isn't here, it doesn't exist; don't invent methods. All types live in `import HubbleGatewaySDK`. The main class and `GatewayPermissions` are `@MainActor`-isolated.

## HubbleGateway (main entry point)

`@MainActor public final class HubbleGateway` — singleton: `HubbleGateway.shared`.

### State properties (read-only)

| Property | Type | Notes |
|---|---|---|
| `initializationState` | `InitializationState` | `.notStarted / .initializing / .ready / .failed` |
| `isScanning` | `Bool` | BLE scan currently active |
| `isFullyOperational` | `Bool` | ready + collection enabled + BT authorized & powered on + location `.authorizedAlways` |
| `isDataCollectionEnabled` | `Bool` | persistent user opt-out flag |
| `gatewayId` | `String?` | assigned at registration |
| `isRegistered` | `Bool` | |
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
func stopScanning()                               // clears persisted scanning intent
func stop()                                       // full unwind to .notStarted; keeps persisted data
func registerIfNeeded() async throws
func setDataCollectionEnabled(_ enabled: Bool)    // persistent opt-out
func deleteAllData()                              // GDPR/CCPA erasure; does NOT change the opt-out flag
func addScanListener(_ listener: ScanListener)    // held WEAKLY — keep your own strong ref
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

## HubbleGatewayConfig

```swift
public struct HubbleGatewayConfig: Sendable {
    init(sdkKey: String,
         respectLowPowerMode: Bool = true,
         uploadOnCellular: Bool = true,
         privacyPolicyUrl: String = "")
}
```

The API base URL is compile-time baked (`https://gw-api.hubble.com`) — no runtime override for integrators. Cadence/dedup/batch tuning is internal and partly server-driven; it is not host-configurable.

## GatewayPermissions

`@MainActor public enum GatewayPermissions` — the SDK never presents system prompts; the host drives them here.

```swift
// Synchronous status reads (no prompt)
static func currentStatus() -> PermissionStatus
static func bluetoothStatus() -> BluetoothAuthorization
static func locationStatus() -> LocationAuthorization
static func motionStatus() -> MotionAuthorization
static func requirementsGuide() -> [GatewayPermissionRequirement]  // ordered checklist for building UI

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
    let lastUploadError: String?
    let lastSuccessfulBatchSize: Int?
    let bytesUploadedLast24h: Int
    let skipUntil: Date?      // server Retry-After backoff window
}
```

## Models

```swift
public struct GatewayScanResult: Sendable, Equatable {
    let peripheralIdentifier: UUID   // ROTATES — do not use as device identity
    let serviceUUID: CBUUID          // 0xFCA6 (Hubble) or 0xFEED (Tile)
    let serviceData: Data            // stable device identity — dedup on this
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

Only auth input is `sdkKey`, sent once as `X-Sdk-Key` at registration; the server returns short-lived device + refresh tokens stored in Keychain (service `com.hubble.gateway`). Token refresh is automatic and serialized. There is no delegated-auth or OAuth option in 0.6.4.
