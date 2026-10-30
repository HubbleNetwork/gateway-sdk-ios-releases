# Background Execution, Release Prep & Troubleshooting

## How background operation works (mental model)

Two execution layers:

1. **In-process timers** — deterministic while the process is alive. Foreground/moving uploads ~every 60 s; background/stationary ~every 15 min. Active-scanning mode pins the fast cadence (60 s uploads, 30 s dedup, high-precision GPS) until `stopActiveScanning()`.
2. **OS-governed BGTasks** — when the process is suspended/dead. `com.hubble.gateway.refresh` (`BGAppRefreshTask`, ~5 min jittered), `com.hubble.gateway.processing` (`BGProcessingTask`, ~60 min jittered, prefers idle/charging, requires network), and on iOS 26+ `com.hubble.gateway.continued` (user-initiated backlog drain via `requestBacklogDrain(title:subtitle:)`). `earliestBeginDate` is a *hint* — iOS decides actual timing based on app usage patterns; on a dev device that's rarely used, BGTasks may fire seldom or never. This is expected, not a bug.

Survival paths after process death: BLE state restoration relaunches the app on a matching advertisement; BGTask fires relaunch it periodically. Both rely on the `configProvider` passed to `registerBackgroundTasks` — without it the SDK relaunches into a not-started state and does nothing.

Location authorization decides *where* the SDK works, not *whether* it works. With **When-In-Use** the SDK is fully functional while the app is foregrounded — it scans, pairs each sighting with a fresh fix and uploads exactly as it would with Always; what it loses is the background, where iOS stops delivering location to a When-In-Use app. **Always** is what buys background operation. So a foreground-only product is a supported mode, not a degraded one, and `startScanning()` says which you got: `.startedForegroundOnly` rather than `.started`.

Self-healing: on every foregrounding and every BGTask fire the SDK re-checks persisted scanning intent and restarts the scan if it died (`ensureScanningMatchesIntent`), re-arms the BGTask chain, and runs an upload cycle. Location authorization changes are handled event-driven: the SDK re-arms its location wake source immediately when a revoked authorization is re-granted (no waiting for the next foregrounding); other late permission grants are picked up on next foregrounding.

## Data volume & retention

- Dedup windows: 30 s moving / 5 min stationary, keyed on `(peripheral, serviceUUID, serviceData)`.
- Batching: 500 packets / 200 locations / 200 logs per upload.
- Retry: per-row exponential backoff 30 s → 30 min cap. A failed packet or location upload also backs off the whole cycle, with an exponential delay capped at 6 h; a server `Retry-After` (clamped to 6 h) acts as the floor on that delay and is honored from any request. A failing heartbeat or log upload never gates packet uploads.
- Retention: uploaded rows pruned after 7 days, un-uploaded after 14 days.
- `respectLowPowerMode` (default true) pauses uploads in Low Power Mode; `uploadOnCellular` (default true) is a host setting the SDK never loosens.

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
| Scans work in foreground, stop in background | Location is When-In-Use, not Always — `operatingMode == .foregroundOnly`, `isBackgroundCapable == false`. The foreground half is working as designed, so this is only a defect if the product needs background operation | Only if you need the background: `requestLocationAlways` (in-app prompt) while `isLocationAlwaysPromptAvailable`; otherwise a Settings round-trip via `openSettingsForLocationAlways` |
| Nothing resumes after force-quit / reboot | `registerBackgroundTasks` called without a `configProvider`, or provider returns nil (key not synchronously available) | Provide the closure; cache the key in Keychain |
| Background scanning worked for days, then stopped | iOS can grant *provisional* Always: the status reads `.authorizedAlways` immediately, and the system re-asks at first real background use. Declining there silently drops the app to When-In-Use | Re-check `operatingMode`; if it now reads `.foregroundOnly`, re-run the Always escalation |
| Scheduled background uploads never happen (foreground and BLE/location-driven uploads still work); `background … task not scheduled` errors at every launch, one per affected task, plus an `iOS declined BGTask registration` line when registration itself failed | The task identifier is missing from `BGTaskSchedulerPermittedIdentifiers`, or `registerBackgroundTasks()` did not run before launch finished. Only the affected task stops being scheduled. Nothing throws — `BGTaskScheduler.register` returns a `Bool` the host never sees — so these log lines are the only announcement | Read the line: it names the single fix that applies. `validateIntegration()` confirms missing Info.plist keys but cannot see whether `registerBackgroundTasks()` ran |
| `iOS declined BGTask registration` once at launch | iOS refused to register at least one handler — identifier not declared, or something else registered it first. Any identifier iOS did accept is still scheduled | Declare every identifier the SDK registers in `BGTaskSchedulerPermittedIdentifiers` — `refresh` and `processing` always, plus `continued` if the host calls `requestBacklogDrain()` on iOS 26+ — and make sure only the SDK registers them |
| One `background … task not scheduled — background scheduling is unavailable` notice, foreground uploads fine | Background App Refresh is off for the app, the device is restricted, or you are in the Simulator | Nothing to fix in code — enable Background App Refresh in Settings, or test on a real device |
| BGTasks never fire on test device | Normal — iOS schedules by usage pattern | Use the debugger trick: `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.hubble.gateway.refresh"]` — this is a **debug-only private LLDB SPI**, not App Store API; never ship it, and expect the private selector to change across Xcode versions |
| `isBluetoothPoweredOn` stays false | CBCentralManager is deferred until BT permission determined | Only check after the permission flow; use `waitForBluetoothPoweredOn` |
| Duplicate devices in UI | Deduping on `peripheralIdentifier` | Key on `serviceData` — beacon addresses rotate |
| Uploads stall, `lastUploadError` set, `skipUntil` in future | Cycle backoff after one or more failing upload cycles (capped at 6 h), or a server `Retry-After` (clamped ≤ 6 h) | Expected; resolves automatically — the first clean cycle clears it. Check `uploadDiagnostics()` for pending counts |
| `GatewayError.alreadyStarted` | Second `start(config:)` call | Guard on `initializationState != .ready`, or `stop()` first to reconfigure |
| Data uploads slow on cellular-poor networks in background | Background execution windows are short and iOS may suspend the process mid-transfer | Expected behavior — nothing is lost: rows stay persisted and the backlog drains on the next execution window (foregrounding drains it immediately) |
| Packets recorded with no location that never upload | Location authorization was revoked and re-granted while scanning kept running | Self-healing: the SDK re-arms location monitoring as soon as authorization is restored (plus configProvider auto-start and the BGTask health check on background wakes) |

## Diagnostics

`try await HubbleGateway.shared.uploadDiagnostics()` returns queue depths (`pendingPackets`, `failedLocations`, …), last upload timestamps, `lastUploadError`, `bytesUploadedLast24h`, and `skipUntil`. Surface it in a debug screen — it answers most "is it working?" questions without log spelunking. The `ScanListener.onUploadDiagnostics` callback pushes updates after each cycle.
