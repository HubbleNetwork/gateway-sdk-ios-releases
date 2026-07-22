# Background Execution, Release Prep & Troubleshooting

## How background operation works (mental model)

Two execution layers:

1. **In-process timers** — deterministic while the process is alive. Foreground/moving uploads ~every 60 s; background/stationary ~every 15 min. Active-scanning mode pins the fast cadence (60 s uploads, 30 s dedup, high-precision GPS) until `stopActiveScanning()`.
2. **OS-governed BGTasks** — when the process is suspended/dead. `com.hubble.gateway.refresh` (`BGAppRefreshTask`, ~5 min jittered), `com.hubble.gateway.processing` (`BGProcessingTask`, ~60 min jittered, prefers idle/charging, requires network), and on iOS 26+ `com.hubble.gateway.continued` (user-initiated backlog drain via `requestBacklogDrain(title:subtitle:)`). `earliestBeginDate` is a *hint* — iOS decides actual timing based on app usage patterns; on a dev device that's rarely used, BGTasks may fire seldom or never. This is expected, not a bug.

Survival paths after process death: BLE state restoration relaunches the app on a matching advertisement; BGTask fires relaunch it periodically. Both rely on the `configProvider` passed to `registerBackgroundTasks` — without it the SDK relaunches into a not-started state and does nothing.

Self-healing: on every foregrounding and every BGTask fire the SDK re-checks persisted scanning intent and restarts the scan if it died (`ensureScanningMatchesIntent`), re-arms the BGTask chain, and runs an upload cycle. Location authorization changes are handled event-driven: the SDK re-arms its location wake source immediately when a revoked authorization is re-granted (no waiting for the next foregrounding); other late permission grants are picked up on next foregrounding.

## Data volume & retention

- Dedup windows: 30 s moving / 5 min stationary, keyed on `(peripheral, serviceUUID, serviceData)`.
- Batching: 500 packets / 200 locations / 200 logs per upload.
- Retry: exponential backoff 30 s → 30 min cap; server `Retry-After` honored, clamped to 6 h.
- Retention: uploaded rows pruned after 7 days, un-uploaded after 14 days.
- `respectLowPowerMode` (default true) pauses uploads in Low Power Mode; `uploadOnCellular` (default true) can be tightened server-side but not loosened.

## App Store submission checklist

- Privacy nutrition labels: declare **Precise Location**, **Coarse Location**, **Device ID**, **Crash Data**, **Other Diagnostic Data**. Motion data is NOT declared (stays on-device).
- No ATT prompt needed — the SDK's privacy manifest sets `NSPrivacyTracking = false`.
- No special entitlements; only the Info.plist keys/modes from SKILL.md.
- Expect App Review to ask why location "Always" is needed — the usage strings should explain the gateway/relay function clearly.
- If the app has a privacy settings screen, wire both `setDataCollectionEnabled(_:)` (opt-out) and `deleteAllData()` (erasure). They are independent: erasure does not flip the opt-out.

## Troubleshooting table

| Symptom | Likely cause | Fix |
|---|---|---|
| `validateIntegration()` fails at launch | Missing Info.plist keys, background modes, or BGTask IDs | Compare against SKILL.md §1; the result's `issues` name the exact keys |
| No scan results at all | Running in Simulator; or `ScanListener` deallocated (SDK holds it weakly); or permission flow never ran | Real device; retain the listener; drive `GatewayPermissions.request` |
| `startScanning()` returns `didStart == false` | Inspect `failureReason`: `.notReady` (start not called / init failed), `.dataCollectionDisabled` (user opt-out persisted), `.missingPermissions` | Handle each; `missingPermissions` lists exactly what to request |
| Scans work in foreground, stop in background | Location is When-In-Use, not Always (`isBackgroundCapable == false`) | `requestLocationAlways` (in-app prompt) while `isLocationAlwaysPromptAvailable`; otherwise Settings round-trip via `openSettingsForLocationAlways` |
| Nothing resumes after force-quit / reboot | `registerBackgroundTasks` called without a `configProvider`, or provider returns nil (key not synchronously available) | Provide the closure; cache the key in Keychain |
| BGTasks never fire on test device | Normal — iOS schedules by usage pattern | Use the debugger trick: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.hubble.gateway.refresh"]` |
| `isBluetoothPoweredOn` stays false | CBCentralManager is deferred until BT permission determined | Only check after the permission flow; use `waitForBluetoothPoweredOn` |
| Duplicate devices in UI | Deduping on `peripheralIdentifier` | Key on `serviceData` — beacon addresses rotate |
| Uploads stall, `lastUploadError` set, `skipUntil` in future | Server pushed `Retry-After` (clamped ≤ 6 h) or backoff after failures | Expected; resolves automatically. Check `uploadDiagnostics()` for pending counts |
| `GatewayError.alreadyStarted` | Second `start(config:)` call | Guard on `initializationState != .ready`, or `stop()` first to reconfigure |
| Data uploads slow on cellular-poor networks in background | Background execution windows are short and iOS may suspend the process mid-transfer | Expected behavior — nothing is lost: rows stay persisted and the backlog drains on the next execution window (foregrounding drains it immediately) |
| Packets recorded with no location that never upload | Location authorization was revoked and re-granted while scanning kept running | Self-healing: the SDK re-arms location monitoring as soon as authorization is restored (plus configProvider auto-start and the BGTask health check on background wakes) |

## Diagnostics

`try await HubbleGateway.shared.uploadDiagnostics()` returns queue depths (`pendingPackets`, `failedLocations`, …), last upload timestamps, `lastUploadError`, `bytesUploadedLast24h`, and `skipUntil`. Surface it in a debug screen — it answers most "is it working?" questions without log spelunking. The `ScanListener.onUploadDiagnostics` callback pushes updates after each cycle.
