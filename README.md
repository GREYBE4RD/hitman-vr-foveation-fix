# HitmanVRFoveationFix

**Edge-to-edge sharpness for HITMAN World of Assassination in PC VR.**

HITMAN's PC VR renderer uses fixed foveation: a small high-resolution area in the centre of the image and lower-resolution coverage around it. On modern pancake-lens headsets, that software blur remains visible far into the periphery.

HitmanVRFoveationFix changes the renderer to use two full-resolution eye layers across the full field of view while preserving the four logical views HITMAN still expects for geometry and visibility.

## What's new in v1.5

Windows v1.5 adds two important fixes on top of v1.4:

- **Full field of view in both eyes.** A second view-count setup site is now patched, removing the black oval at the edge of one eye and the associated Instinct-outline smearing.
- **Faster save-load recovery.** The renderer guard now repairs the scale and mask values directly from its worker thread on a high-resolution ~1 ms timer instead of waiting for the WinForms/PowerShell callback path.

The v1.4 transparency/refraction fix is preserved: glass, water, bottles and affected lights use the two physical eye views for refraction-depth copies while geometry and visibility keep the required four logical views.

## Compatibility

| Platform | Status |
|---|---|
| Windows / Oculus (LibOVR) | v1.5, supported |
| Windows / SteamVR (OpenVR) | v1.5, supported |
| Linux / Proton / SteamVR | Experimental v1.5 port |
| Standalone Quest | Not supported |

The Windows implementation is verified against HITMAN World of Assassination build **3.270.1**. Other builds use conservative byte-pattern matching and fail closed if the required code cannot be located uniquely.

The improvement is most visible on pancake-lens headsets such as Quest 3 and Quest Pro, but the fix also works with Fresnel headsets.

## Comparison

Both examples below are crops from the outer part of the view at original resolution.

![Before and after, left side of the view](https://raw.githubusercontent.com/RealChrizzl/hitman-vr-foveation-fix/main/screenshots/comparison-left.png)

![Before and after, right side of the view](https://raw.githubusercontent.com/RealChrizzl/hitman-vr-foveation-fix/main/screenshots/comparison-right.png)

## Windows installation

1. Download the latest release ZIP.
2. Extract `HitmanVRFoveationFix.ps1` and `HitmanVRFoveationFix.bat` into the same folder.
3. Double-click **`HitmanVRFoveationFix.bat`** and accept the administrator prompt.
4. Start HITMAN normally, including directly into VR.
5. Leave the fix window open while playing.

Status colours:

- **Grey** — waiting for HITMAN
- **Amber** — VR or the mission is still initializing
- **Green** — fix active
- **Red** — the tool stopped because a validation or write check failed

The tool writes `foveationfix.log` next to the script. If you report a problem, attach that log.

### Why PowerShell instead of an EXE?

The tool must read and write another process's memory. Packed PowerShell executables frequently trigger antivirus heuristics because the same techniques are also used by malware. The project therefore ships as a plain-text PowerShell script that can be inspected directly.

The `.bat` file only launches `HitmanVRFoveationFix.ps1` with the required privileges.

## Linux / Proton

The experimental Linux/Python port is currently based on **Windows v1.5** and includes the v1.4 transparency/refraction changes and the v1.5 second view-count fix. The ~1 ms renderer guard remains largely unchanged from the approach first introduced in the Linux v1.3 implementation, with v1.5 adding further validation and fail-safe handling around the same basic mechanism.

The Linux implementation uses the same underlying HITMAN renderer patches and values as the Windows version, with Linux-specific process-memory, thread-control and executable-memory handling for Proton. The Linux files remain available separately in the repository and are not bundled into the Windows release ZIP.

Development and testing of the Linux port were carried out by **GREYBE4RD**, with assistance from ChatGPT, on Arch Linux / SwayWM / Wayland, SteamVR and an AMD Radeon RX 9070 XT. While the port should be largely distro and hardware-agnostic, behaviour on other distributions, desktop environments, hardware configurations and VR setups may vary.

**To run it:**

1. Download the .sh and .py files to the same directory.
2. Start your terminal of choice and make the .sh file executable and run it:

```bash
chmod +x launch.linux.HitmanVRFoveationFix-v1.5.sh
./launch.linux.HitmanVRFoveationFix-v1.5.sh
```

3. Enter the `sudo` password when prompted.
4. Start HITMAN, and leave the terminal open while playing. Press `Ctrl+C` to stop the tool and restore live changes when safe.

## What the fix changes

HITMAN normally renders four foveated layers per frame:

- two wide layers covering the full field of view at lower resolution;
- two narrow high-resolution layers covering the centre.

HitmanVRFoveationFix instead uses **two full-resolution eye layers covering the full field of view**.

HITMAN still expects four logical views in parts of the renderer. The Windows fix therefore keeps the required four-view geometry/visibility behaviour and restricts the refraction-depth copies to the two physical eye views.

### Performance cost

The change roughly doubles the pixel work compared with the original foveated layout. Whether that affects frame rate depends on available GPU headroom.

For the verified setup:

| | Pixels across | Approx. span | Density |
|---|---:|---:|---:|
| Original sharp centre | 936 | ~49° | 19.1 px/° |
| Fixed full view | 1872 | 99° | 18.9 px/° |

The goal is therefore not to increase the original centre density, but to extend approximately that density across the full view.

## Safety and restore behaviour

The tool does **not** modify HITMAN files or settings. All changes are made in the memory of the running game process and disappear when HITMAN exits.

The Windows implementation is deliberately fail-closed:

- expected code must match before it is patched;
- renderer fields must pass plausibility checks before they are written;
- writes are read back and verified;
- the fast guard shares the same writer lock as the normal lifecycle path;
- device identity is revalidated before direct guard writes;
- an unknown or partially verified write state faults the guard and stops further renderer writes;
- live restore only touches bytes owned by the current tool instance when restoration can be proven safe.

This still is not a zero-risk tool: it writes to the memory of a game with online connectivity. Use it at your own discretion.

## Technical documentation

The repository contains additional material for maintenance and reverse engineering:

- [`docs/HOW-IT-WORKS.md`](https://github.com/RealChrizzl/hitman-vr-foveation-fix/blob/main/docs/HOW-IT-WORKS.md) — renderer architecture and patch rationale
- [`docs/UPDATING.md`](https://github.com/RealChrizzl/hitman-vr-foveation-fix/blob/main/docs/UPDATING.md) — signatures and update procedure
- [`tools/HitmanVRProbe.ps1`](https://github.com/RealChrizzl/hitman-vr-foveation-fix/blob/main/tools/HitmanVRProbe.ps1) — read-only diagnostic probe
- [`CHANGELOG-v1.5.md`](CHANGELOG-v1.5.md) — v1.5 changes

Detailed docs, screenshots, diagnostic tools and Linux-port files are intentionally **not** bundled into the Windows v1.5 release ZIP.

## Reporting problems

When opening an issue, include:

1. headset and VR runtime;
2. whether the problem occurs on a new mission, mission restart or save-game load;
3. `foveationfix.log`;
4. a fresh probe report from `tools/HitmanVRProbe.bat` if the game was updated or the tool refuses to patch.

## License

MIT. See [`LICENSE`](LICENSE).
