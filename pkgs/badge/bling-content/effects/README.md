# Demoscene OLED effects (128x64 mono)

Four classic demoscene effects, authored as pure-Nix per-frame OLED screens for
the NixVegas badge. Each file is a **function** `scope: { bitmap = [<256 ints>];
nextMs = <ms>; }` that the badge's embedded evaluator (`fix` fast VM, or upstream
`nix` C API) applies once per frame. They are the marquee "it's the Nix Badge"
eye-candy: table-driven, allocation-light, and safe on BOTH evaluators.

- `xor-munch.nix`  — XOR / munching squares (concentric diamond ripples)
- `plasma.nix`     — sum-of-sines plasma with a Bayer 4x4 ordered dither
- `starfield.nix`  — perspective warp starfield with near-star motion streaks
- `rotozoom.nix`   — rotating + zooming tiled-texture (Second Reality staple)

They pack the framebuffer directly (no `draw.nix` surface attrset), so the per-
frame cost is 256 ints computed from hoisted tables — never a giant attrset of
pixels. All are hard-coded to the 128x64 marquee panel and always emit 256 ints
regardless of `scope.height` (see "Panel size" below).

## The two hard rules (both honoured)

1. **Everything scope-independent is hoisted into an OUTER `let` BEFORE `scope:`.**
   The sine tables, the 8192-entry plasma radius table, the rotozoom texture, the
   star seeds, the per-int page/column geometry, the Bayer matrix — all live in the
   top `let`. Upstream nix does NOT hoist constants out of the per-frame lambda, so
   a table built *inside* the lambda would be rebuilt every frame and spiral the GC.
   Verified: evaluating 60 frames of the heaviest effect (plasma, 8192-entry radius
   table) in one process takes **0.17 s total** — the table is built once and shared.
2. **Per-frame work is cheap and allocation-light.** Per frame we read a few
   `scope.t`-derived scalars/phases and emit the 256 packed ints, each from a handful
   of integer ops (table lookups, `bitAnd`/`bitXor`/`bitOr`, add, compare). No
   per-frame table, no per-pixel attrset. Single-frame eval is well under the 1-2 s
   budget (~0.06 s/frame in stock nix here).

Pure `builtins` only (no nixpkgs lib), so both evaluators run them standalone. No
floats: sine is an integer table (parabolic approximation), distances are integer
(hoisted table), and all wraps use `bitAnd` with a power-of-two mask. No NUL bytes.

## The packing contract (shared by all four)

The panel is 8 pages x 128 columns. GDDRAM byte(page,col) = `page*128 + col`, and
bit `r` of that byte is pixel `(col, page*8 + r)`. The runtime `bitmap` folds those
1024 bytes 4-LE-bytes/int -> **256 ints**. Because `128 % 4 == 0`, int `i` lives in
ONE page: `page = i / 32`, covering columns `(i % 32)*4 .. +3`. Every effect hoists
`colPage[i] = { page; col0 }` and computes each int as
`b0 + b1*256 + b2*65536 + b3*16777216`, where `bK` is the 8-bit vertical slice of
column `col0+K` on that page.

---

## xor-munch.nix — munching squares

**Idea.** The canonical `x XOR y` interference pattern, animated by adding a time
term and slicing a moving band: `lit(x,y) <=> ((x^y) + t/24) & 31 < 16`. Produces
nested diamond ripples that "munch" across the panel. The cheapest effect here.

**Hoisted tables.** `pow`/`bit` (2^r for r in 0..7), `colPage` (per-int page/col
geometry), the mask constant. No spatial table needed — the field is a pure int op.

**Per-frame cost.** One phase `= t/24`; then 256 ints × 4 cols × 8 rows, each a
`bitXor` + add + `bitAnd` + compare. ~8k cheap int ops/frame, zero allocation of
tables. 60 frames in 0.17 s.

**Look (t=800, 2x2-downsampled preview):**

```
%%%%%%%=       =%%%%%%%=       =%%%%%%%=       =%%%%%%%=       =
%%%%%%=%      = %%%%%%=%      = %%%%%%=%      = %%%%%%=%      =
...
=       =%%%%%%%=       =%%%%%%%=       =%%%%%%%=       =%%%%%%%
[lit pixels: 4096/8192]   <- exact 50% duty diamond lattice
```

---

## plasma.nix — sum-of-sines plasma + ordered dither

**Idea.** Four sine fields summed and animated at different speeds, then thresholded
to 1 bit with a Bayer 4x4 ordered dither so the soft blobs read as stippled
gradients:
`v = sinX[col*3 + t1] + sinY[row*5 + t2] + sinDiag[col+row + t3] + sinRad[dist + t4]`,
`lit <=> (v + 240) > bayer4x4[x&3][y&3]*30`.

**Hoisted tables.** A 256-entry integer sine table (`SIN`, amplitude ±60, parabolic
approximation — no float builtin); per-column `hArg` and per-row `vArg` argument
tables; a **width×height = 8192-entry integer radius table** `radTab` (built once via
an integer-sqrt); the Bayer 4x4 matrix; `colPage` geometry.

**Per-frame cost.** Four phases from `t`; then per pixel 4 table lookups + 3 adds +
one dither compare. The 8192-entry radius table is the reason rule 1 matters most
here — it is built ONCE in the outer `let`. 60 frames in 0.17 s.

**Look (t=1234):** organic gradient blobs, density smoothly stippled from dense
`%*` cores to sparse `: :` edges by the ordered dither; ~4.7k/8192 lit, and the
field churns frame-to-frame (sums differ: `995696925764` @t500 vs `411148415120`
@t2000).

---

## starfield.nix — perspective warp starfield

**Idea.** A hoisted list of star seeds `(sx, sy, z0)`; per frame each star's depth
sweeps toward the camera (`z` decreasing with `t`, wrapping to respawn far), and is
perspective-projected: `col = 64 + sx*focal/z`, `row = 32 + sy*focal/z`. Near stars
(small `z`) fly outward fast and get a short vertical motion streak.

**Hoisted tables.** `seeds` — 170 deterministic pseudo-scattered stars from an
integer hash of the index (no RNG builtin); `colPage` geometry; `pow`/`bit`;
`emptyRow`. The scatter is a constant.

**Per-frame cost.** Sparse: one projection per star (170), each a divide + a couple
adds + a clip test; on-panel stars (~30) fold into a per-column byte map, then the
256 ints read that map. A few hundred int ops/frame — the cheapest by allocation.
60 frames in 0.19 s.

**Look (t=1500):** stars radiating from centre with `::` motion dashes on the fast
foreground stars; ~60 lit on-panel. It clearly warps — the star set advances every
frame (sums differ: `4696219196` @t500 vs `10814967453` @t2000).

---

## rotozoom.nix — rotating + zooming tiled texture

**Idea.** An infinite tiled 1-bit texture spun and zoomed under the viewport (the
Second Reality staple). Per pixel we rotate+scale into texture space and sample a
hoisted 32×32 tile:
`u = (dx*cos + dy*sin)*zoom >> 12 + panX`, `v = (dy*cos - dx*sin)*zoom >> 12 + panY`,
`lit = tex[(u)&31][(v)&31]`. The angle spins with `t`, `zoom` breathes on a slow
sine, and the texture pans — so it rotates, pulses, and drifts at once.

**Hoisted tables.** A 256-entry integer sine table (`SIN`, scale 256, so `cos=256`
== 1.0); `cosAt = sin(+64)`; a **32×32 1-bit woven-plaid texture** `TEX` (32 row
masks, a checkerboard XOR'd with a fine weave, built once); `p2big` (2^0..2^31 for
column bit extraction); `colPage` geometry.

**Per-frame cost.** Read `cos`, `sin`, `zoom`, `panX`, `panY` (5 scalars from `t`);
then per pixel 2 fixed-point transforms (a few mults + a `/4096`) + one texture bit
test. ~8k int ops/frame, no per-frame table. 60 frames in 0.19 s.

**Look (t=1234):** a rotated, sheared plaid — the diagonal tile-edge bands are the
signature rotozoom warp; ~4.1k/8192 lit, and it spins/zooms frame-to-frame (sums
differ: `545515649155` @t500 vs `562374675286` @t2000).

---

## Verification (REQUIRED — run + recorded)

Exact spec contract (256 ints, all ints, valid nextMs), per effect:

```
$ for e in xor-munch plasma starfield rotozoom; do
    systemd-run --user --scope -p MemoryMax=4G nix --extra-experimental-features nix-command eval --impure --expr "
      let f = import ./$e.nix;
          r = f { t = 1234; frameIndex = 37; width = 128; height = 64; backend = 0; fps = 30;
                  batteryMv = 4100; batteryPct = 87; onUsb = true; load1 = 0.42; cpuPct = 12; memPct = 40; uptimeS = 90061; };
      in builtins.length r.bitmap == 256 && builtins.all builtins.isInt r.bitmap && builtins.isInt r.nextMs"
  done
xor-munch:  true
plasma:     true
starfield:  true
rotozoom:   true
```

Animation + non-zero at multiple `t` (500 / 2000 / 8000), and `nextMs`:

```
xor-munch:  { animates = true; nextMs = 33; nonzero500 = true; nonzero2000 = true; nonzero8000 = true; }
plasma:     { animates = true; nextMs = 33; nonzero500 = true; nonzero2000 = true; nonzero8000 = true; }
starfield:  { animates = true; nextMs = 33; nonzero500 = true; nonzero2000 = true; nonzero8000 = true; }
rotozoom:   { animates = true; nextMs = 33; nonzero500 = true; nonzero2000 = true; nonzero8000 = true; }
```

Sample **changed** frames (bitmap sums at two times — for xor-munch the sum is
conserved by the 50% duty but the frames still differ, confirmed `a != b`):

```
xor-munch:  differ(t=500, t=2000) = true   (sums equal @ 50% duty; pattern shifts)
plasma:     sum@t500 = 995696925764   sum@t2000 = 411148415120     (a != b)
starfield:  sum@t500 = 4696219196     sum@t2000 = 10814967453       (a != b)
rotozoom:   sum@t500 = 545515649155   sum@t2000 = 562374675286      (a != b)
```

Hoist / performance (rule 1) — 60 frames of each in ONE process, all valid + first
!= last, total wall time:

```
xor-munch  x60: { allValid = true; distinct = true; }   real 0.17 s
plasma     x60: { allValid = true; distinct = true; }   real 0.17 s   (8192-entry radius table shared, not rebuilt)
starfield  x60: { allValid = true; distinct = true; }   real 0.19 s
rotozoom   x60: { allValid = true; distinct = true; }   real 0.19 s
```

Single-frame eval time is ~0.06 s in stock nix — well under the 1-2 s ceiling.

## Panel size

These effects are 128x64-native: `width`/`height` are fixed in the outer `let` and
the output is ALWAYS 256 ints regardless of `scope.height`. Unlike the info screens
(battery/load/…) which are height-parametric and self-test at both 32 and 64 rows,
these self-test at **@64 (256 ints) only**. Wire the etc.nix self-test accordingly
(the snippet below does exactly that).

---

## Wiring into `pkgs/badge/bling-content/etc.nix` (for the human — do NOT let the agent edit etc.nix)

These become `oled.d/NN-<name>.nix` screens the runtime cycles. They are
self-contained (no `<nixbadge/lib/...>` imports), so unlike the info screens they
are copied **verbatim** — no `sed` import-rewrite — and self-tested at @64 only.

### 1. Add an `effects` list next to the existing `screens` list (in the top `let`):

```nix
  # Demoscene eye-candy screens (self-contained, 128x64-native). Copied verbatim
  # (no <nixbadge/lib> import to rewrite) and self-tested at @64 (256 ints) only.
  effects = [
    { n = "70"; name = "xor";       src = ./effects/xor-munch.nix; }
    { n = "72"; name = "plasma";    src = ./effects/plasma.nix; }
    { n = "74"; name = "starfield"; src = ./effects/starfield.nix; }
    { n = "76"; name = "rotozoom";  src = ./effects/rotozoom.nix; }
  ];

  # Verbatim copy (self-contained: no import rewrite).
  effectCmds = lib.concatMapStringsSep "\n" (e: ''
    cp ${e.src} "$out/oled.d/${e.n}-${e.name}.nix"
  '') effects;

  # Self-test each effect at @64 only (they always emit 256 ints).
  effectChecks = lib.concatMapStringsSep "\n" (e: ''
    checkFrame "$out/oled.d/${e.n}-${e.name}.nix" 64 256
    echo "nixbadge-content: effect ${e.name} -> valid 128x64 frame (256 ints)"
  '') effects;
```

### 2. In the `runCommand` script body, after the `${screenCmds}` line, add:

```nix
    ${effectCmds}
```

### 3. In the self-test section, after the `${checkCmds}` line, add:

```nix
    ${effectChecks}
```

(`checkFrame` already asserts: 256 ints, all ints, at least one non-zero, and
`nextMs > 0` — exactly what these effects satisfy.)
```
