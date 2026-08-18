# Keeping this working after a game update

The tool has two ways of finding the code it needs.

**On build 3.270.1** it uses fixed addresses that were verified by hand. That path is
frozen and will not change.

**On any other build** it searches the `.text` section for byte patterns. Addresses
move every time IO Interactive rebuilds the game; the surrounding instructions usually
do not. So in most cases a game update will simply keep working, and the tool will
just say the build is untested.

If a pattern stops matching, the tool refuses and names the part it could not find.
This document is for whoever picks it up at that point — including anyone who forks
this repository.

---

## Base signatures

Six signatures identify patched base sites; one additional signature is used only to locate the VR device. `??` matches any byte.
The **hit offset** is how far into the match the patched instruction begins.

### 1. WNO writer A — hit offset 9

```
8B 97 D8 04 00 00 83 FA 01 0F 94 C1 88 8F 1B 03 00 00
```

`mov edx,[rdi+0x4D8]` / `cmp edx,1` / `sete cl` / `mov [rdi+0x31B],cl`
→ patch the `sete cl` (`0F 94 C1`) to `B1 00 90` = `mov cl,0` + `nop`.

### 2. WNO writer B — hit offset 9

```
8B 97 D8 04 00 00 83 FA 01 0F 94 C0 88 87 1B 03 00 00
```

Same shape with `al` instead of `cl`. Patch `0F 94 C0` to `B0 00 90`.

### 3. Field-of-view flag — hit offset 44

```
C0 08 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28
48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14
0F B6 87 1B 03 00 00
```

The pattern is long for a reason: the last eleven bytes appear **twice** in the
binary, at two call sites that are byte-identical for over forty bytes. They differ 44
bytes earlier, in a displacement — `+0x8C0` here versus `+0x950` at the twin. If you
shorten this pattern you will hit the wrong one.

Patch the `movzbl` to `B8 01 00 00 00 90 90` = `mov eax,1` + two `nop`.

### 3b. Field of view, OpenVR device — hit offset 44

```
50 09 00 00 45 33 C0 4C 8B 8E C8 7A 00 00 48 8B D3 48 89 6C 24 28
48 89 6C 24 20 48 8B 01 FF 50 28 48 8B CB E8 ?? ?? ?? ?? FF 4B 14
0F B6 87 1B 03 00 00
```

The twin of the pattern above, and the reason it needs those extra 44 bytes: this
is the same method implemented separately in `ZRenderVRDeviceOpenVR`. Only the
first four bytes differ — `+0x950` here against `+0x8C0` there. Same patch.

Both must be applied. Patch one only and the other backend keeps a narrow field of
view; the unused one never executes.

### 4. View count — hit offset 12

```
74 16 49 8B 85 A0 41 01 00 41 8B CF 80 B8 1B 03 00 00 00 0F 45 CF
```

Patch the `cmpb` to `48 85 E4 90 90 90 90` = `test rsp,rsp` + four `nop`. That clears
the zero flag without touching a register, so the following `cmovne` always fires and
the count is 4.

### 4b. View count, second site — hit offset 9

```
49 8B 8D A0 41 01 00 74 1A 80 B9 1B 03 00 00 00 BF 02 00 00
```

The same 1/2/4 count, set up a second time about 3.6 KB further on. Same patch. Note
the shared `A0 41 01 00` in both view-count patterns — that is the `+0x141A0` device
offset in the render manager, and it is the most stable part of either signature.

Patch one and not the other and the geometry is fine but one eye keeps a black oval
mask at the edge of its field of view. Both must be applied.

### 5. Device locator — not patched

```
48 8B 0D ?? ?? ?? ?? 8B D6 48 8B 01 44 38 B9 1B 03 00 00 0F 84
```

Two things are read out of this match rather than assumed:

- **bytes 3–6** are a RIP-relative displacement; the address of the VR device pointer
  is `match + 7 + displacement`
- **bytes 15–18** are the offset of the WNO flag inside the device (`0x31B` today)

---

## If a pattern no longer matches

### v1.4 refraction call patterns

v1.4 adds three strong patterns. The five-byte `E8` displacement is wildcarded,
decoded, and range-checked. The two inner patterns must resolve to the same target.

Outer owner scope, hit offset 0, replaced length 18:

```
48 8B 8C 24 C0 00 00 00 48 89 44 24 20 E8 ?? ?? ?? ??
48 8D 8C 24 60 02 00 00
```

First `CopyRefractionDepth` call, hit offset 18, replaced length 21:

```
48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28
4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ??
48 8B 9D D0 01 00 00 48 8B F8 48 8B 0D ?? ?? ?? ??
4C 8D 0D ?? ?? ?? ??
```

Second call, also hit offset 18 and length 21:

```
48 8B 8D B0 01 00 00 48 8D 95 D0 01 00 00 89 44 24 28
4D 8B C4 8B 41 04 44 8B 09 48 8B CE 89 44 24 20 E8 ?? ?? ?? ??
48 8B 9D D0 01 00 00 48 8B F8 48 8B 85 B0 01 00 00
4C 8B 40 60 4D 85 C0
```

Do not patch the shared fullscreen helper globally. The outer wrapper is an owner
marker only; it does not change the context count. Each inner wrapper changes the
current slot from 4 to 2 only for its direct call, then verifies and restores 4.

---

Work from what the code *does*, not from where it was.

**Writers A and B** are the only places that store to `device+WNO`. Find every
instruction writing a byte to that displacement; two of them sit right after a
comparison of `[reg+0x4D8]` against 1.

**The field-of-view flag and the view count** both read `device+WNO`. On 3.270.1 there
are 26 such reads in 25 functions. Search for `mod=10` memory operands with `disp32`
equal to the WNO offset — and decode the ModRM properly, because a naive byte search
also finds `rel32` jump displacements and will roughly triple your hit count.

Of those reads, the view count is the one that feeds a value of 1 / 2 / 4 onto a stack
in the render context. It is the interesting one; see `HOW-IT-WORKS.md` §3.

**The two device classes** sit at vtable slot `+0x208` each. If you need to find
the pair again, look for pointers to the containing functions in `.rdata` — they
land at `<device vtable> + 0x208` for `ZRenderVRDeviceOculus` and
`ZRenderVRDeviceOpenVR` respectively.

**The device fields** (`+0x319` active, `+0x420` field of view, `+0x490` scales,
`+0x4C0` mask, `+0x4D8` transition, `+0x510/+0x514` eye size, `+0x520` layers,
`+0x530` texture) are not located by pattern. If the class layout ever shifts, the
plausibility check on `+0x420` will fail — four floats that must land between 0.2 and
3.0 — and the tool stops rather than writing into the wrong place. Those offsets would
have to be re-derived from the builder function.

---

## Verifying a change

There is no substitute for putting the headset on. Three checks that matter:

1. **Sharpness** — the whole field of view should look like the centre used to. The
   status window should show two layers at the full per-eye size, not half.
2. **Geometry** — stand somewhere busy and move your head *and your position*. Nothing
   should pop in and out. If it does, the view count patch is not taking effect.
3. **Transparency and refraction** — check glass panes, NPC glasses, flowing water,
   bottles, emissive lights and at least one large panorama window while turning and
   leaning your head. Both eyes must agree, and affected objects must not pop in both
   eyes together or switch brightness with head angle.

The second and third checks are easy to skip and expensive to get wrong. They are
what took the longest to isolate in the first place.
