# Bad Apple delta codec (contract v1)

Shared source of truth for the build-time **encoder** (`emit_delta.c`) and the
runtime **decoder** (`nix-badge/fixeval.zig` `decodeOled` + `nix-badge.zig` flush
seam + `oled.zig` `flushPageSpan`). They must invert each other byte-for-byte.

## Why

60 fps full-frame Bad Apple is blocked twice on a 128x64 panel:

- **I2C bandwidth**: the OLED bus is 400 kHz (`sg2000-milkv-duo-s-common.dtsi`).
  A full 1025-byte GDDRAM flush is ~23 ms -> a ~43 fps hard ceiling. (A separate
  DTS bump to 1 MHz fast-mode-plus lifts this to ~108 fps; that is orthogonal
  hardware work, bench-verified separately.)
- **Memory**: 60 fps * 219 s = ~13140 frames. Full frames at 256 ints each are
  ~27 MB of fix Value slots on a 351 MB badge.

Delta encoding kills both: push only the changed bytes over I2C (partial GDDRAM
window), and store per-frame only the changed (offset,byte) pairs.

## Playback model (decoder-driven, no wall-clock skips)

Deltas are **cumulative**: frame N is `apply(delta_N, frame N-1)`. A dropped
frame corrupts the picture until the next keyframe. So playback is **render-call
paced, not wall-clock paced**:

- Zig passes `scope.frameIndex` (a monotonic per-screen play counter). The screen
  returns `elemAt frames (mod frameIndex nframes)`. Never skips a frame.
- `nextMs = 16` **requests** 60 fps. If eval+flush can't keep up, playback slows
  but never corrupts (frame N always follows N-1).
- On **screen entry** (the active eval screen index changes), Zig resets
  `frameIndex = 0`. Frame 0 is always a keyframe, so re-entry starts clean.
  => Bad Apple **restarts from the beginning** each time you switch to it.
- Periodic keyframes (every `K = 60` frames, 1/s) self-heal any I2C glitch and
  enable future seeking. With no-skip playback only frame 0 is strictly required.

## Nix output shape (encoder -> fix)

```nix
scope:
let
  frames = [
    { k = true;  b = [ <fbLen/4 ints> ]; }          # keyframe: full frame
    { k = false; n = <count>; b = [ <ceil(count/2) ints> ]; }   # delta
    ...
  ];
  nframes = <N>;
  mod = a: b: a - (a / b) * b;
in
let fr = builtins.elemAt frames (mod scope.frameIndex nframes);
in {
  bitmap = fr.b;
  delta  = !fr.k;      # decoder reads this bool
  n      = fr.n or 0;  # delta entry count (0 for keyframes)
  nextMs = <1000/fps>; # 16 at 60 fps
}
```

## Packing

**Keyframe `b`** — the existing full-frame format, unchanged: `fbLen/4` ints, each
4 consecutive page-major GDDRAM bytes little-endian:
`int = b0 | b1<<8 | b2<<16 | b3<<24`. Decoder: existing `decodeOled` full path.

**Delta `b`** — a list of change entries, **2 entries per int** (both inline: max
value 2^36-1 < the 2^47 fix inline-int ceiling):

- One change entry: `E = offset * 256 + byte`
  - `offset` in `[0, fbLen-1]` (<= 1023 for 128x64 -> 10 bits)
  - `byte` in `[0, 255]` (8 bits)
  - so `E` in `[0, 262143]` — exactly 18 bits (`262144 == 2^18`).
- Two entries per int, first entry in the HIGH bits:
  `int = E0 * 262144 + E1`   (E0 = earlier change, E1 = later)
- `count` entries -> `ceil(count/2)` ints. If `count` is odd, the last int's low
  18 bits (`E1`) are 0 and MUST be ignored — the decoder bounds by `n`, never by
  the int count.

Decode (delta path), `width` = panel width (128), `n` = `fr.n`:

```
for i in 0..n:
    v = asInt(bitmap[i / 2])
    E = if (i & 1 == 0) (v >> 18) else (v & 0x3FFFF)   # 0x3FFFF = 2^18-1
    offset = E >> 8
    byte   = E & 0xFF
    fb[offset] = byte                      # fb persists across frames
    page = offset / width;  col = offset % width
    col_lo[page] = min(col_lo[page], col); col_hi[page] = max(col_hi[page], col)
```

Changes are emitted in ascending `offset` order (so `E0 < E1` within a pair;
not required for correctness, but keeps the stream tidy and dirty-span tight).

## Partial flush (decoder -> panel)

`fb` is page-major: byte at `(page p, column c)` is `fb[p*width + c]`, contiguous
within a page. So a per-page dirty span flushes with no gather:

```
Panel.flushPageSpan(page, c0, c1):
    sendCommands(column_addr, c0, c1,  page_addr, page, page)
    write([0x40] ++ fb[page*width + c0 .. page*width + c1 + 1])
```

Per frame the decoder returns `Dirty`:
- keyframe / full screen (any screen with no `delta=true`) -> `Dirty.full` ->
  `Panel.flush()` (whole panel, as today).
- delta -> for each page `p` with `col_lo[p] <= col_hi[p]`: `flushPageSpan(p, col_lo[p], col_hi[p])`.
  At most 8 small writes (128x64 = 8 pages) of only the changed columns.

## Backward compatibility

The info screens (battery/load/power/clock/currentsystem) return `{bitmap; nextMs}`
with no `delta`/`n`. `getAttr("delta")` is null -> `delta=false` -> the existing
full decode + full flush. Only Bad Apple emits deltas. `scope.frameIndex` is a new
field every screen may ignore.
