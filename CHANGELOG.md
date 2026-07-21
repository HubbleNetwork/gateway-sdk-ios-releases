# Changelog

All notable changes to the Hubble Gateway SDK for iOS. This file ships with
each release to [gateway-sdk-ios-releases](https://github.com/HubbleNetwork/gateway-sdk-ios-releases).

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
