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
    private var deviceIndex: [Data: DiscoveredDevice] = [:]

    // MARK: - Internals

    private var pollTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var scanCollector: ScanCollector?
    /// One `AsyncStream.Continuation` per active subscriber to
    /// ``discoveries()``. Callers get an independent stream each — the
    /// SDK's `ScanListener` is a single-fan-in source, so this multiplex
    /// gives multiple SwiftUI views / analytics tasks independent views
    /// of the same event feed without stealing from each other.
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
        refresh()
    }

    /// Empties the local ``discoveredDevices`` list without touching the
    /// SDK's persistent scan buffer, tokens, or config. Purely a UI
    /// affordance — the next sighting the SDK ships to `ScanListener`
    /// repopulates the list.
    func clearDiscoveredDevices() {
        deviceIndex = [:]
        discoveredDevices = []
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
        discoveredDevices = deviceIndex.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Polling + lifecycle

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
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
