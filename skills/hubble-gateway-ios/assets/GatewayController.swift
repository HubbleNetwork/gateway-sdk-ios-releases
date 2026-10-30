import Foundation
import Observation
import HubbleGatewaySDK
import UIKit

/// Reference integration of `HubbleGateway` for SwiftUI hosts. Copy this
/// file into your own app — it has no sample-app-specific concerns:
///
/// - Mirrors every SDK state field as `@Observable` properties so SwiftUI
///   views can bind directly.
/// - Polls the SDK on a 5 s timer and on `UIApplication.didBecomeActive` so
///   permission flips made in Settings surface without the user reopening
///   the app.
/// - Bridges ``ScanListener`` callbacks onto the `@MainActor` and maintains
///   a deduped ``DiscoveredDevice`` list keyed on `serviceData` (the
///   peripheral identifier rotates with the beacon's advertised address).
/// - Coalesces that list: listener callbacks arrive per raw sighting, so
///   they only touch an index, and the observable array is republished on a
///   500 ms coalescing window rather than once per callback.
///
/// Anything UI-flow related (alerts, blocker text, text-field state) lives
/// in ``AppModel`` next door — keep that boundary when adopting.
@MainActor
@Observable
final class GatewayController {

    // MARK: - SDK state mirrors

    private(set) var permissions: PermissionStatus = GatewayPermissions.currentStatus()
    private(set) var initializationState: InitializationState = .notStarted
    private(set) var isScanning: Bool = false
    private(set) var isActiveScanning: Bool = false
    private(set) var gatewayId: String?
    private(set) var lastLocation: LocationFix?
    private(set) var lastDiagnostics: UploadDiagnostics?
    private(set) var isBluetoothPoweredOn: Bool = false

    // MARK: - Derived state

    private(set) var discoveredDevices: [DiscoveredDevice] = []
    /// Where sightings actually land; ``discoveredDevices`` is republished
    /// from it once per coalescing window. Deliberately unbounded — the sample keeps
    /// every device it has ever seen, and the list is re-sorted in full on
    /// each republish. A product screen wants a TTL or a cap here.
    @ObservationIgnored private var deviceIndex: [Data: DiscoveredDevice] = [:]
    /// Set by ``ingest(_:)``, cleared by ``republishDevicesIfNeeded()``.
    @ObservationIgnored private var devicesNeedRepublish = false

    // MARK: - Internals

    // `@Observable` tracks every stored property, private ones included, so
    // the internals below are opted out: only `discoveredDevices` and the
    // state mirrors above are meant to invalidate a view. Without this, the
    // per-sighting path pays observation bookkeeping nobody reads.
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var republishTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var scanCollector: ScanCollector?
    /// One `AsyncStream.Continuation` per active subscriber to
    /// ``discoveries()``. Callers get an independent stream each — the
    /// SDK's `ScanListener` is a single-fan-in source, so this multiplex
    /// gives multiple SwiftUI views / analytics tasks independent views
    /// of the same event feed without stealing from each other.
    @ObservationIgnored
    private var discoveryContinuations: [UUID: AsyncStream<GatewayScanResult>.Continuation] = [:]

    init() {
        installLifecycleObservers()
        refresh()
        startPolling()
    }

    // No deinit cleanup needed — controller lives for the lifetime of the
    // host app (its `AppModel` owner is held by `RootView`'s `@State`).

    // MARK: - SDK lifecycle

    /// Starts the SDK with the given config and attaches the scan-collector
    /// bridge. Subsequent calls (after the first) are no-ops on the SDK
    /// side — re-attaching the bridge is idempotent.
    func configure(_ config: HubbleGatewayConfig) throws {
        if HubbleGateway.shared.initializationState != .ready {
            try HubbleGateway.shared.start(config: config)
        }
        attachScanCollector()
        refresh()
    }

    /// Returns the SDK's ``ScanStartResult`` so flow callers can surface
    /// missing permissions — the SDK reports them instead of prompting.
    @discardableResult
    func startScanning() -> ScanStartResult {
        let result = HubbleGateway.shared.startScanning()
        refresh()
        return result
    }

    func stopScanning() {
        HubbleGateway.shared.stopScanning()
        refresh()
    }

    func setActiveScanning(_ enabled: Bool) {
        if enabled {
            HubbleGateway.shared.startActiveScanning()
        } else {
            HubbleGateway.shared.stopActiveScanning()
        }
        refresh()
    }

    func deleteAll() {
        HubbleGateway.shared.deleteAllData()
        deviceIndex = [:]
        discoveredDevices = []
        devicesNeedRepublish = false
        refresh()
    }

    /// Empties the local ``discoveredDevices`` list without touching the
    /// SDK's persistent scan buffer, tokens, or config. Purely a UI
    /// affordance — the next sighting the SDK ships to `ScanListener`
    /// repopulates the list.
    func clearDiscoveredDevices() {
        deviceIndex = [:]
        discoveredDevices = []
        devicesNeedRepublish = false
    }

    func registerNow() async throws {
        try await HubbleGateway.shared.registerIfNeeded()
        refresh()
    }

    /// Pull the latest snapshot from the SDK into the observable mirrors.
    /// Cheap — no I/O, just property reads.
    func refresh() {
        permissions = GatewayPermissions.currentStatus()
        initializationState = HubbleGateway.shared.initializationState
        isScanning = HubbleGateway.shared.isScanning
        isActiveScanning = HubbleGateway.shared.isActiveScanningOverride
        gatewayId = HubbleGateway.shared.gatewayId
        lastLocation = HubbleGateway.shared.lastLocation
        isBluetoothPoweredOn = HubbleGateway.shared.isBluetoothPoweredOn

        Task {
            if let snap = try? await HubbleGateway.shared.uploadDiagnostics() {
                lastDiagnostics = snap
            }
        }
    }

    // MARK: - Wait helpers for start-flow callers

    /// Polls `isBluetoothPoweredOn` until it flips true or `timeout`
    /// elapses. The SDK defers its `CBCentralManager` until Bluetooth
    /// permission is determined (it never triggers the prompt itself),
    /// so call this only *after* the permission flow + `startScanning()`
    /// — before that the property is `false` by construction.
    func waitForBluetoothPoweredOn(timeout: TimeInterval = 8) async -> Bool {
        let stepMs: UInt64 = 100
        let maxIterations = Int(timeout * 1000) / Int(stepMs)
        for _ in 0..<maxIterations {
            if HubbleGateway.shared.isBluetoothPoweredOn { return true }
            try? await Task.sleep(nanoseconds: stepMs * 1_000_000)
        }
        return HubbleGateway.shared.isBluetoothPoweredOn
    }

    // MARK: - Async scan feed

    /// Returns a fresh `AsyncStream<GatewayScanResult>` that emits every
    /// raw scan sighting delivered by the SDK's `ScanListener`. Each
    /// call yields an independent stream — safe to call from multiple
    /// SwiftUI views, analytics tasks, or background pipelines. Buffers
    /// the newest 200 events to bound memory if the consumer is slow.
    ///
    /// Cancelling the consuming `Task` (or letting the stream go out of
    /// scope) automatically detaches its continuation.
    ///
    /// ```swift
    /// Task {
    ///     for await result in controller.discoveries() {
    ///         analytics.track(result)
    ///     }
    /// }
    /// ```
    func discoveries() -> AsyncStream<GatewayScanResult> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(200)) { continuation in
            self.discoveryContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.discoveryContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    // MARK: - Scan listener bridge

    private func attachScanCollector() {
        guard scanCollector == nil else { return }
        let collector = ScanCollector { [weak self] result in
            Task { @MainActor in self?.ingest(result) }
        } onDiagnostics: { [weak self] diagnostics in
            Task { @MainActor in self?.lastDiagnostics = diagnostics }
        }
        HubbleGateway.shared.addScanListener(collector)
        scanCollector = collector
    }

    /// Called once per sighting the SDK's scanner emitted. An advertisement
    /// carrying service data for two of Hubble's own services still yields
    /// one callback, not two; a host scan-only service the same
    /// advertisement matched adds one on top. The SDK notifies
    /// listeners above its own dedup, and the foreground scan runs with
    /// duplicates allowed, so each nearby beacon lands several calls per
    /// second on the main actor and the total scales with how many beacons
    /// are in range.
    ///
    /// This method therefore does the cheap thing only: update the index and
    /// set `devicesNeedRepublish`. The observable `discoveredDevices` array
    /// is re-sorted and republished at most once per `republishInterval`
    /// from ``scheduleRepublish()``, so SwiftUI re-renders on a fixed budget
    /// instead of once per sighting.
    private func ingest(_ result: GatewayScanResult) {
        // Fan out to every active AsyncStream subscriber. Yields are
        // cheap; the bufferingPolicy on each stream drops oldest events
        // if a consumer is slow.
        for continuation in discoveryContinuations.values {
            continuation.yield(result)
        }

        // Key on serviceData: peripheralIdentifier rotates with the
        // beacon's advertised address, so it can't identify a device.
        let key = result.serviceData
        if var existing = deviceIndex[key] {
            existing.lastRSSI = result.rssi
            existing.lastSeen = result.timestamp
            existing.sightingCount += 1
            existing.lastServiceUUID = result.serviceUUID.uuidString
            existing.lastPeripheralId = result.peripheralIdentifier
            deviceIndex[key] = existing
        } else {
            deviceIndex[key] = DiscoveredDevice(
                serviceData: key,
                lastPeripheralId: result.peripheralIdentifier,
                lastServiceUUID: result.serviceUUID.uuidString,
                lastRSSI: result.rssi,
                firstSeen: result.timestamp,
                lastSeen: result.timestamp,
                sightingCount: 1
            )
        }
        devicesNeedRepublish = true
        scheduleRepublish()
    }

    /// Opens a fixed republish window, if one is not already open.
    ///
    /// This is a throttle, not a debounce: the window starts at the first
    /// sighting and later ones fold into it rather than pushing it back.
    /// Resetting the timer on every sighting — the usual debounce shape —
    /// would starve exactly when it matters, because a beacon in range never
    /// stops arriving and the list would never republish at all.
    ///
    /// So a busy room costs two re-renders per second whatever the beacon
    /// count, and a quiet room costs nothing: nothing is armed when no
    /// sighting arrives, which a free-running ticker could not say. The
    /// trade is that the first sighting after a lull waits the full window.
    private func scheduleRepublish() {
        guard republishTask == nil else { return }
        republishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.republishInterval)
            guard let self else { return }
            self.republishTask = nil
            self.republishDevicesIfNeeded()
        }
    }

    /// Publishes the accumulated index to the observable array if anything
    /// changed since the last republish. Called from ``scheduleRepublish()``.
    private func republishDevicesIfNeeded() {
        guard devicesNeedRepublish else { return }
        devicesNeedRepublish = false
        discoveredDevices = deviceIndex.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Polling + lifecycle

    /// How long the republish window stays open once a sighting opens it,
    /// before the list is re-sorted and republished. Anything in 0.5–1 s keeps the list feeling live
    /// while decoupling re-renders from the advertisement rate.
    private static let republishInterval: Duration = .milliseconds(500)
    /// How often the SDK state mirrors are refreshed. Independent of the
    /// republish above: this one polls state the SDK does not push.
    private static let refreshInterval: Duration = .seconds(5)

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard let self else { return }
                self.refresh()
            }
        }
    }

    private func installLifecycleObservers() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}

/// Bridge from `ScanListener` protocol to the @MainActor controller.
private final class ScanCollector: ScanListener {
    private let onResult: @Sendable (GatewayScanResult) -> Void
    private let onDiagnostics: @Sendable (UploadDiagnostics) -> Void

    init(
        onResult: @escaping @Sendable (GatewayScanResult) -> Void,
        onDiagnostics: @escaping @Sendable (UploadDiagnostics) -> Void
    ) {
        self.onResult = onResult
        self.onDiagnostics = onDiagnostics
    }

    func onScanResult(_ result: GatewayScanResult) { onResult(result) }
    func onUploadDiagnostics(_ diagnostics: UploadDiagnostics) { onDiagnostics(diagnostics) }
}
