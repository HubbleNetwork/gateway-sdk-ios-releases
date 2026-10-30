# Changelog

All notable changes to the Hubble Gateway SDK for iOS. This file ships with
each release to [gateway-sdk-ios-releases](https://github.com/HubbleNetwork/gateway-sdk-ios-releases).

## 0.7.0 — 2026-10-30

### Added

- `HubbleGateway.operatingMode` and the `GatewayOperatingMode` enum
  (`.full` / `.foregroundOnly` / `.notOperational`) report what the SDK can
  do right now in one exhaustive value. With Location **When In Use** the
  SDK scans, pairs fixes and uploads exactly as in `.full` — it stops when
  the app is backgrounded — so that state is now nameable instead of
  collapsing into "not operational". `isFullyOperational` is unchanged in
  meaning and is now shorthand for `operatingMode == .full`.
- Location quality thresholds are now host-settable on the existing
  `HubbleGatewayConfig` initializer: `locationAccuracyFloorMeters`,
  `movingFreshnessSeconds` and `stationaryFreshnessSeconds`, defaulting to
  the previous internal values (50 m / 30 s / 30 min), which are exposed as
  `HubbleGatewayConfig.defaultLocationAccuracyFloorMeters` and friends. A
  non-finite or non-positive value is rejected, the default is used, and the
  rejection is logged once `start(config:)` has installed the log sinks.
  These three are host-owned — no server field overrides them.
- `additionalScanServiceUUIDs` on `HubbleGatewayConfig` lets a host widen
  the BLE scan filter. The added UUIDs are **scan-only**: matching
  advertisements reach `ScanListener` and nothing else — never stored, never
  uploaded, no location fix requested, no upload cycle nudged. Widening the
  scan filter therefore never widens the upload surface. 16-, 32- and
  128-bit forms are accepted, case-insensitive.
- `UploadDiagnostics` gained `lastHeartbeatAt`,
  `multiPayloadAdvertisements` and `strippedPayloadAdvertisements`. Decoding
  is backward compatible — a payload without these fields still decodes.
- `THIRD_PARTY_NOTICES.md` now ships with each release.

### Changed

- **Action may be required:** in `GatewayPermissions.requirementsGuide()`,
  the Location **Always** row is now `required: false`. It was `true`. The
  SDK does not need Always to function — Always buys background operation,
  which is a product decision — so a host checklist should no longer render
  it as a blocker. If your UI gates "ready to scan" on every `required` row
  being granted, that gate now opens one step earlier. Nothing about what
  the SDK does with either grant changed.
- An advertisement now produces **at most one payload sighting**. The
  uploaded service list is `FCA6` plus the server's per-SDK-key
  `payloadServiceUuids` (default `["FEED"]`, at most 8), in priority order;
  `FCA6` always wins. Advertisements carrying several payload services are
  counted in `UploadDiagnostics.multiPayloadAdvertisements`.
- The registration and heartbeat body follows the gateway metadata naming
  contract: `type` is `mobile` (was `ios`), `os` / `osVersion` carry the
  operating system and its version, `platformVersion` the host app version,
  and `hubbleSdkVersion` the SDK version. `firmwareVersion` is no longer
  sent — a phone has no firmware of its own. **Requires the matching
  server-side change**; the server makes `firmwareVersion` optional for
  `type=mobile`.
- The server config contract is now honored exactly: a response with no
  `config` key keeps the current overlay, `null` clears it, an object
  replaces it. Server values are clamped to the server's documented ranges.
  The upload batch cap drops from 10,000 to 500, and `scanIntervalMs` is
  gone from both the payload and the snapshot.
- Log entries at `Level.warning` now serialize as `"warn"`. The backend
  rejected any batch containing a `"warning"` entry with a 400 — the whole
  batch, not just that entry — so warning-level logs were being lost along
  with everything batched beside them.
- `LICENSE` now carries the Hubble IP partner license grant.

### Fixed

- A >2 s app hang on the discovery path. The `@MainActor` gateway could
  block on the serial SQLite queue through two independent paths —
  per-advertisement ingest, and the cached-location / fresh-fix reads that
  the public `lastLocation` also reaches. Ingest now runs on the BLE queue
  and the location reads no longer bounce off the database queue.
- A cycle whose packet or location upload failed got no backoff at all —
  `skipUntil` was only ever armed from a server `Retry-After` — so one
  device on a bad link produced four timeouts and four error events per
  nudge. A failing cycle now arms `min(60 s × 2^(n−1), 6 h)`.
- Background task submission is now preflighted against the host's
  `BGTaskSchedulerPermittedIdentifiers` and whether
  `registerBackgroundTasks()` actually ran in this process. A host that
  misses either used to get `notPermitted` errors reported on every
  activation, foreground edge and upload cycle; it is now one `notice` per
  identifier per launch, pointing at `validateIntegration()`.
- CoreLocation reports an unusable position as `horizontalAccuracy < 0`.
  Such fixes are now dropped at the source, so neither the location cache
  nor `/locations` ever sees the sentinel, and the pairing gate rejects
  non-positive accuracy as well, so a sighting is never stamped with a
  position the framework itself marked invalid.
- Sightings paired with stale fixes mid-drive. The stillness watchdog read a
  gap between Core Motion classifications as a stop and demoted to
  stationary after 120 s, shutting off the continuous location stream; on
  the moving-mode stream almost every fix arrives with `speed = -1`, so the
  CL-speed path rarely rescued it. While Core Motion's last classification
  is "moving" the watchdog now waits 15 minutes, and running that out
  re-arms activity updates rather than demoting outright.
- A sighting whose ingest-time location pairing failed the accuracy or
  staleness gate stayed unpaired forever and never uploaded. Each upload
  cycle now backfills still-pending rows from the full location history,
  choosing a fix by an explicit replacement policy.
- A one-shot location refresh that came back **coarser** than the fix
  already cached was reported as a success. No backoff armed and the cached
  fix kept its old timestamp, so a stationary foregrounded device re-armed a
  `Best`-accuracy `requestLocation()` on the very next advertisement, and
  kept doing so for as long as the cached fix stayed inside the keep window.
  A refused delivery is now paced like any other useless answer, so the
  device backs off for a cadence instead.
- Crash entries sent the whole stack inside `message`, so every crash was a
  unique string and any consumer grouping on message splintered one bug into
  thousands. `stackTrace` and `sessionId` are now their own fields, and the
  `crash_logs` table migrates on an existing install instead of silently
  keeping its old columns.

### Documentation

- The `ScanListener` contract is now documented as it actually behaves:
  listeners fire **per advertisement, above dedup**. The 30 s / 5 min dedup
  windows govern storage and upload only, never the callback stream. The
  docs also now state that a host which does not retain its listener gets no
  callbacks, silently — the listener is held weakly.

## 0.6.5 — 2026-07-27

- Fixed: while the device was moving, every delivered location fix ran its
  own upload cycle. With the default 50 m distance filter that is a fix
  every few seconds in a vehicle, so the SDK issued roughly 3,000 HTTPS
  requests per hour of driving instead of batching them — and kept the
  cellular radio from ever going idle. The CoreLocation upload nudge is now
  rate-limited to at most one cycle per upload interval; motion detection
  is unaffected. Packet and location data are unchanged, only their
  delivery is batched as originally intended.
- Changed: the per-advertisement `ingest svc=… loc=…` log line is now
  emitted at `.debug` instead of `.notice`. It is no longer written to the
  unified log's persistent store and no longer included in the SDK's
  diagnostics upload, so it will not appear in a `log collect` archive.
  If you installed a `GatewayLogSink` with the default `minLevel: .info`,
  you will stop receiving these lines — pass `minLevel: .debug` to keep
  them, or read them live with
  `log stream --predicate 'subsystem == "com.hubble.gateway"' --level debug`.
  Everything at `.notice` and above is unchanged.
- Performance: the SQLite statements on the per-advertisement path are now
  compiled once and reused rather than recompiled per advertisement, and
  hex encoding of the service-data payload no longer allocates per byte.
  No behavior or schema change.

## 0.6.4 — 2026-07-23

- New: releases now include the `skills/hubble-gateway-ios/` agent skill,
  which teaches AI coding assistants (e.g. Claude Code) the SDK's API,
  required project setup, permission flow, and troubleshooting. See the
  README's "AI-assisted integration" section for install instructions.
- Changed: `DeviceMotionState` and `UploadStatus` are now `internal`.
  They were unintentionally public with no public API entry point
  referencing them, so no integrator code can have depended on them.

## 0.6.3 — 2026-07-22

- New: `HubbleGateway.setLogSink(_:minLevel:)` redirects the SDK's log
  stream to a host-owned `GatewayLogSink` (file, vendor logger, in-app
  debug console) in addition to the always-on os.log output. Install it
  in `App.init()` before `registerBackgroundTasks` to also capture
  startup and background-relaunch logs; level filtering happens SDK-side
  (default `.info`).
- Fixed: location monitoring is re-armed immediately when a revoked
  location authorization is re-granted while the gateway is running.
  Previously scanning could continue with location monitoring down,
  producing sightings without a location fix that were never uploaded.

## 0.6.2 — 2026-07-22

- The published XCFramework now embeds dSYM debug symbols, so integrators'
  app archives symbolicate SDK frames and Xcode no longer warns about
  missing dSYM UUIDs when uploading to App Store Connect.

## 0.6.1 — 2026-07-21

- Releases now ship this `CHANGELOG.md` and carry real release notes
  (previously GitHub Releases were published with empty notes).
- Removed an internal comment from the `SDKOverrides.plist` resource
  bundled with the framework.
- Documentation fixes: corrected the `PermissionStatus.motion` doc
  comment (the SDK never presents permission prompts on its own) and a
  broken `registerBackgroundTasks(configProvider:)` symbol link.

## 0.6.0 — 2026-07-17

- Location **Always** permission can now be escalated via the in-app system
  prompt (`GatewayPermissions`), instead of always routing through Settings.
- Documented the Hubble and Tile BLE service UUIDs and added a log-message
  reference table to the README.
- Raised key operational log messages from `info` to `notice` so they are
  visible in Console.app without a debug configuration.
- Documentation: clarified that `peripheralIdentifier` is not a stable device
  key — deduplicate on service data instead.

## 0.5.0 — 2026-07-14

- **Breaking:** renamed the public façade class `HubbleGatewaySDK` →
  `HubbleGateway`.
- The SDK now ships as a prebuilt binary `HubbleGatewaySDK.xcframework`
  vended through Swift Package Manager; integration steps are unchanged
  (`.package(url: ..., from: "X.Y.Z")`).

## 0.4.0 — 2026-07-13

- Permission prompts are now fully host-driven: the SDK never presents a
  system permission prompt on its own. Drive prompts via
  `GatewayPermissions`.
- Fixed an unintended Motion & Fitness prompt at startup by creating the
  motion-activity manager lazily.
- Default heartbeat interval changed from 5 to 15 minutes.
- Throttled the per-discovery upload nudge to at most one cycle per upload
  interval.

## 0.3.0 — 2026-07-09

- Moved internal tuning knobs out of the public `HubbleGatewayConfig`
  surface (see `AdvancedTuning`).
- Upload rows are never permanently dropped after failed uploads;
  server-sent `Retry-After` values are clamped to a sane range.
- Added `SECURITY.md`, `CONTRIBUTING.md`, and `LICENSE`.

## 0.2.1 — 2026-07-06

- The gateway auto-restarts after a background relaunch; hardened the
  background-task chain (handlers complete exactly once, stalled drain loops
  stop, double registration no longer throws).
- Reliability fixes across the upload pipeline: retry idempotency via
  row-derived batch ids, backoff off-by-one, `deleteAllData` race, poisoned
  location rows, offline database pruning.
- Persisted a device-identity fallback so the device id doesn't churn when
  IDFV is unavailable.

## 0.2.0 — 2026-07-02

- First public release of the Hubble Gateway SDK for iOS.
- Background BLE scanning with motion-aware location gating, batched
  uploads, privacy controls (`setDataCollectionEnabled`, `deleteAllData`),
  and a privacy manifest (`PrivacyInfo.xcprivacy`).
- Removed `apiBaseURL` from the public config; the endpoint is baked in at
  SDK build time.
