# HitmanVRFoveationFix v1.4

## Fixed

- Glass, flowing water, bottles and affected emissive/light materials no longer
  render different content in the left and right eye.
- Angle-dependent simultaneous pop-in of affected panes, NPC glasses and lights is
  removed by limiting only the two `CopyRefractionDepth` calls to the two physical
  eye views. Geometry and visibility retain the required four logical views.
- A separate sleeping renderer guard reduces the save-load observation window from
  up to 15 ms to approximately 1 ms. Its fast path reads only the 16-byte scale and
  8-byte mask fields and performs no writes while they match.
- Guard corrections reuse the full v1.3 validation, ownership, write, verification
  and rollback transaction. A transition-3 write is latched across the next normal
  lifecycle sample.

## Preserved

- The WinForms UI, device detection and lifecycle loop remain at 15 ms.
- Oculus and SteamVR/OpenVR use the same verified renderer-value handling.
- Build 3.270.1 uses exact verified addresses and contexts. Other builds retain a
  fail-closed pattern path, now including three strong refraction call patterns.
- Turning the tool off or closing it restores owned renderer values and code when a
  live restore can be proven safe. Closing HITMAN always discards all changes.

## Test basis

The refraction split is the former Transparency TestKit 7 **Test W**. It was reported
correct across the previously affected villa panes, NPC glasses, flowing water,
lights, panorama glass and aquarium scenes, with no remaining stereo mismatch,
simultaneous pop-in or angle-dependent brightness change. The W telemetry log showed
balanced owner and CopyRefractionDepth scopes with no rejected states.
