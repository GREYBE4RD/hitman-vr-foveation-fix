# How it works

Everything below refers to HITMAN 3 / World of Assassination build **3.270.1**,
Windows, D3D11. Both VR backends the game has are covered: Oculus (LibOVR) and
SteamVR (OpenVR). It has no OpenXR backend at all.

---

## 1. What the game does

HITMAN's VR renderer uses **fixed foveation**, called *Wide/Narrow Overlay* (WNO) in
the code. A single `Texture2DArray` holds four slices:

| Slice | Role | Size | Covers |
|---|---|---|---|
| 0, 1 | wide, one per eye | provider ÷ 2 | the whole field of view |
| 2, 3 | narrow, one per eye | provider ÷ 2 | a small circle in the centre |

Both pairs are rendered at the same pixel count, but the narrow pair spends it on a
much smaller angle — so inside the circle you get roughly full resolution, and outside
it you get half, upscaled.

A pixel shader composites the two. The circle's radius comes from a geometry block at
`device+0x430`; the blend ring runs from `r0 = r1 − blend` to `r1`, where `r1` is half
the smaller of the two field-of-view spans.

The circle is **fixed to the centre of the image**. There is no gaze input anywhere in
the block — this is not eye-tracked foveated rendering, and a headset with eye
tracking gains nothing here.

**The consequence:** on a Fresnel headset the lens blurs the periphery anyway and the
software blur hides in it. On a pancake headset the lens is sharp to the edge, so the
software blur is the only thing left — and it is very visible.

---

## 2. What the fix does

Switch the renderer to **two slices at full resolution**, covering the whole field of
view. v1.5 patches six instructions and maintains the renderer Scale/Mask fields
while VR is active.

Note on cost, since this is easy to get wrong: it is **twice** the pixel work, not
the same. Each slice doubles in both dimensions while the slice count halves — four
quarters against two wholes. What stays equal is the *density*: 936 px across the old
~49° narrow zone is 19.1 px/°, and 1872 px across the full 99° is 18.9 px/°. About a
percent apart. The old sweet-spot sharpness, everywhere.

### Before VR initialises

| Address | Original | Patched | Effect |
|---|---|---|---|
| `0x011D8B9E` | `0F 94 C1` | `B1 00 90` | WNO flag writer A → 0 |
| `0x011D8BC1` | `0F 94 C0` | `B0 00 90` | WNO flag writer B → 0 |
| `0x012C1EAC` | `0F B6 87 1B 03 00 00` | `B8 01 00 00 00 90 90` | constant-buffer flag = 1, raises the shader's radius limit so the image fills the field of view instead of leaving a black border — **Oculus device** |
| `0x012499CC` | `0F B6 87 1B 03 00 00` | `B8 01 00 00 00 90 90` | the same thing again for the **OpenVR device** |
| `0x01161FE9` | `80 B8 1B 03 00 00 00` | `48 85 E4 90 90 90 90` | **view count 4** — see below |
| `0x01162E3C` | `80 B9 1B 03 00 00 00` | `48 85 E4 90 90 90 90` | **second view count 4** — fills both eyes correctly |

`48 85 E4` is `test %rsp,%rsp`. It clears the zero flag without touching any register,
so the `cmovne` that follows always fires.

The two field-of-view flag patches are the same method in two different classes. Both
device classes carry it at vtable slot `+0x208`:

```
ZRenderVRDeviceOculus  vtable RVA 0x1F016C0  +0x208 -> 0x12C1CB0  (0x12C1EAC)
ZRenderVRDeviceOpenVR  vtable RVA 0x1EFE020  +0x208 -> 0x12497D0  (0x12499CC)
```

Patch only one and the other backend keeps its narrow field of view. Everything
else — the device layout, the field offsets, the other four base patches — is shared
between them, which was confirmed by comparing probe reports from both runtimes on
the same machine.

### While VR and a mission initialise

| Field | Value | Effect |
|---|---|---|
| `device+0x490 … +0x49C` | `1.0` ×4 | small/large scale ratios neutralised |
| `device+0x4C0` | `0` | overlay pass off — removes the ghost images |
| `device+0x4C4` | `0` | removes the black circle in the centre |

OpenVR rebuilds the render state during mission, scene, and save-game loads. These
fields must therefore be neutralised before that state reaches transition 3, not
merely after a new texture pointer appears. The normal lifecycle still watches the
transition at 15 ms, writes as soon as the device geometry is plausible (including
before `active=1`), reads the values back, and requires multiple samples plus a
250 ms monotonic stable window before showing green.

Windows v1.5 starts a separate renderer guard after the normal validated transaction has
claimed and verified both Scale and Mask for the current device. The guard watches only
`device+0x490` (16 bytes) and `device+0x4C0` (8 bytes) on a high-resolution ~1 ms
waitable timer when the OS provides one. Matching values cause no write.

A mismatch is only a trigger. Before writing, the guard takes the same writer lock as
the 15 ms PowerShell lifecycle and revalidates the current device pointer, device vtable,
field-of-view block, Scale and Mask. It then re-reads each target immediately before the
write, writes only the already-owned fix bytes, and verifies the result. The guard never
captures stock values and never performs restore work.

If a write leaves a target in a state that is neither the requested fix nor the exact
pre-write value, or if a post-write verification cannot establish the result, the guard
faults and disarms. The normal renderer transaction checks that fault while holding the
same lock, so it cannot write over an unknown state afterwards.

Direct repairs are recorded on the guard thread together with the renderer transition
visible at the time of the write. The 15 ms lifecycle drains those counters and latches
independently of WinForms callback delivery. The callback remains useful for prompt
full-path synchronization, but it is not part of the time-critical direct-write path.

This lifecycle has been visually verified in the headset across new missions,
mission restarts, save-game loads, scene changes and Freelancer mode.

Stock values for reference: `+0x490…` = `3EDF2BF0 3ECE8B44 4012D426 401EA625`,
`+0x4C0/+0x4C4` = `3D 2D 66 3F  DA B9 4D 3E`.

---

## 3. The interesting one: the view count

Turning off WNO gets you two full-resolution layers immediately. It also breaks the
game: geometry disappears and reappears as you move — a car's front wheel, a door, a
person's torso, a whole building façade. Not at the edges; anywhere, including dead
centre.

The cause is a single value:

```
0x1161FC9  mov    $0x2,%r15d          ; 2
0x1161FD6  lea    0x2(%r15),%edi      ; 4
0x1161FDA  lea    -0x3(%rdi),%ebx     ; 1
0x1161FDF  mov    0x141A0(%r13),%rax  ; VR device
0x1161FE6  mov    %r15d,%ecx          ; default 2
0x1161FE9  cmpb   $0, 0x31B(%rax)     ; WNO flag
0x1161FF0  cmovne %edi,%ecx           ; WNO on -> 4
0x1161FF5  mov    %ebx,%ecx           ; no VR   -> 1
0x1162015  incl   0x14(%rdx)          ; stack counter
0x116201B  mov    %ecx,(%rdx,%rax,4)  ; push the count
```

A **count**, pushed onto a stack in the render context: 1 without VR, 2 with WNO off,
4 with WNO on. Whatever consumes it does not cope with 2. Force it to 4 and the
geometry stays put.

This is correct for geometry even though only two physical eye views exist: the
central view-matrix accessor at `0x1306EFC` masks requested indices with `& 1` when
WNO is off, so view 2 maps to eye 0 and view 3 maps to eye 1. v1.4 documents and
handles the important exception: `CopyRefractionDepth` consumes the numeric context
count through a fullscreen instance multiplier and therefore must see 2, not 4.

### There are two of them

The same count is set up a second time, about 3.6 KB further on, and v1.3 only found
the first:

```
0x1162E33  mov    0x141A0(%r13),%rcx  ; VR device
0x1162E3A  je     0x1162E56           ; no VR -> 1
0x1162E3C  cmpb   $0, 0x31B(%rcx)     ; WNO flag
0x1162E43  mov    $0x2,%edi           ; default 2
0x1162E48  mov    $0x4,%eax
0x1162E4D  cmovne %eax,%edi           ; WNO on -> 4
0x1162E50  mov    %edi,0x78(%rsp)     ; the count
```

Instruction for instruction the same shape as `0x1161FE9`, and it takes the same fix.
The symptom it caused is different and much easier to miss: **one eye keeps a black
oval mask around the edge of its field of view**, while the other eye fills the frame.
Instinct outlines smear into the black band, because that pass draws without the same
limit. Which eye is affected is not fixed — it depends on which eye the single stored
per-eye FovPort belongs to, so different headsets and runtimes lose different eyes.

It was found by sweeping. There are 30 places that read the WNO flag; v1.3 patched
three. Forcing the remaining 27 back to "foveation is on", one group at a time, and
looking for the mask to disappear, took two rounds: nine groups, then three single
instructions.

The lesson from section 5 held again. Three static hypotheses were tested first — the
composite constant buffer, the FovPort pair at `+0x410`/`+0x420`, and the second
unpatched reader in the same function — and all three were wrong. The sweep found it
in two attempts.

---

## 4. Why glass and water need two physical views

v1.3 deliberately keeps the render-context count at four because geometry and
visibility break at two. Most of the renderer can map logical views 2 and 3 back to
physical eyes 0 and 1, but the refraction-depth copy multiplies its fullscreen draw
range by the current context count. That caused the narrow foveal views to leak into
glass, flowing water, bottles and some emissive/light materials.

v1.4 leaves the outer `DrawRefractiveAndTransparent` pass at four. A small owner
scope identifies that exact pass, and only its two direct calls to
`CopyRefractionDepth` temporarily replace the current count 4 with 2. Each wrapper
restores 4 before returning. The changed call blocks on build 3.270.1 are:

| Address | Role |
|---|---|
| `0x011B892A` | owner scope around `DrawRefractiveAndTransparent` |
| `0x01290BA2` | first `CopyRefractionDepth` call, local 4 -> 2 -> 4 |
| `0x01291386` | second `CopyRefractionDepth` call, local 4 -> 2 -> 4 |

The wrappers gate on thread ID, render-context pointer and the expected current count.
Their counters are monitored by the normal 15 ms loop. Installation and live removal
suspend the game threads, reject any thread whose instruction pointer lies in a
changed block or wrapper, and publish inner calls before the outer owner gate. Removal
uses the reverse order.

This exact split was selected by the Test W result: stereo glass and water became
correct, the simultaneous pop-in disappeared, affected lights became stable, and no
new global image problem was observed across the reported scenes.

Implementation note: these are private executable wrappers allocated by the external
PowerShell tool. They use normal Windows x64 calling convention and balanced
CALL/RET control flow, but an external tool cannot register process-local dynamic
unwind metadata without executing a registration call inside HITMAN. The normal path
has been exercised extensively; an actual exception unwinding out of one of the
wrapped render functions remains a rare release limitation. The cave is never freed
while the process is alive, and live removal is allowed only after active counters and
all suspended thread instruction pointers prove it is quiescent.

---

## 5. How it was found

Six hypotheses were tested and all six were wrong: the skipped halving of the render
target, the Hi-Z buffer (which turned out to belong to screen-space reflections, not
occlusion culling), the frustum and view matrices, LOD via entity properties, a buffer
size, and a wrong projection scale.

Two things actually worked.

**A precise observation.** "A house façade in the centre of the image, missing at
00:11, back at 00:13 after tilting my head down — and the hillside behind it renders
fine." That one sentence ruled out object size, edge culling, draw-call budgets and
depth-buffer corruption in a single stroke, because a façade is the largest possible
object, it was in the centre, and something further away was still being drawn.

**A backwards sweep.** The WNO flag is read at 26 places. Rather than guess which one
mattered, the game was left running normally in four-layer mode — a state known to be
correct — and individual read sites were forced to take the two-layer branch, one
group at a time. Backwards, because with four views all matrix slots are populated, so
a patch can only make the code read *less*, never something uninitialised.

Four rounds of bisection later, 24 of 25 sites were eliminated and one instruction was
left.

The lesson, for anyone doing this on another game: **observation before hypothesis.**
Measuring which change causes a symptom is slower to set up and enormously faster than
being clever about where the bug ought to be.
