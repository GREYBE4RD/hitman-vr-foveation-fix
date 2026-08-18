# HitmanVRFoveationFix v1.5

## Fixed

- Patched the second VR view-count setup site. HITMAN configures the 1/2/4 logical-view count in two places; earlier versions patched only one. The second site caused a black oval at the edge of one eye and allowed Instinct outlines to smear into that area.
- The field of view is now filled correctly in both eyes on Oculus and SteamVR/OpenVR while preserving the four logical views required for geometry and visibility.
- Save-game load recovery is substantially faster. The renderer guard now performs validated Scale/Mask repairs directly on its worker thread instead of detecting the mismatch and then waiting for the WinForms/PowerShell callback path.

## Renderer guard

- Uses a Windows high-resolution waitable timer for the ~1 ms guard loop when available and records actual interval telemetry.
- Shares the same renderer-write lock as the normal 15 ms lifecycle path.
- Arms only after the normal validated transaction has established ownership of both renderer fields.
- Revalidates the current VR device, vtable, field of view, scale and mask before direct writes.
- Rechecks each target immediately before writing to reduce stale-sample races during renderer rebuilds.
- Reads back every write attempt and records a repair only when a field was actually changed and verified.
- Treats an unknown post-write state as fatal: the guard disarms and the normal renderer writer is blocked under the same lock.
- Samples the renderer transition at the time of the direct repair, avoiding delayed lifecycle classification from the UI callback.
- Drains guard repair/fault state from the normal lifecycle loop so bookkeeping does not depend on callback delivery.

## Preserved from v1.4

- Refraction-depth copies use the two physical eye views while geometry and visibility retain four logical views. This fixes the stereo mismatch affecting glass, water, bottles and some lights without reintroducing geometry pop-in.
- Oculus (LibOVR) and SteamVR/OpenVR use the same verified handling.
- Build 3.270.1 uses verified addresses and instruction contexts; other builds use conservative, fail-closed pattern matching.
- Live restore remains ownership-aware and closes safely when the current process state cannot be proven restorable.

## Linux

The Linux/Proton port remains based on v1.3 and does not yet include the Windows v1.4/v1.5 renderer changes.
