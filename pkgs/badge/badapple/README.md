# badapple

Bad Apple!! transcoded into a packed 1-bit frame blob for the badge's
**128x32 SSD1306 OLED**. The build fetches the video (pinned, reproducible),
transcodes it with ffmpeg, thresholds to 1-bit, and packs each frame into the
exact GDDRAM layout the runtime blits.

## Build

```sh
cd /path/to/badgeos
nix-build -E 'with import <nixpkgs> {}; import ./pkgs/badge/badapple { inherit pkgs; }'
```

Output:

- `result/badapple.bin` — the blob (see format below).
- `result/badapple.info` — human-readable stats (frame_count, fps, size, …).

With the default source (full song, 20 fps) this is **4379 frames, 20 fps,
2 242 064 bytes** (`16 + 4379 * 512`).

The build fails if the header is wrong or the file size is not
`16 + frame_count * 512` (self-test in `checkPhase`).

### Options

`import ./pkgs/badge/badapple { inherit pkgs; <opt> = <val>; }`:

| option            | default    | meaning                                                        |
|-------------------|------------|----------------------------------------------------------------|
| `fps`             | `20`       | playback rate baked into the header                            |
| `threshold`       | `128`      | luma cutoff; pixel ON iff `gray >= threshold`                  |
| `durationSeconds` | `null`     | cap length in seconds (`null` = whole ~219 s song)             |
| `scale`           | `"stretch"`| `stretch` (fill panel), `fit` (letterbox), `crop` (center-crop)|
| `width`/`height`  | `128`/`32` | panel geometry (`height` must be a multiple of 8)              |
| `src`             | archive.org mp4 | the source video (see "Swapping the source")             |

`scale = "stretch"` is the default because the panel is 4:1 while Bad Apple is
4:3; letterboxing (`fit`) leaves the figure tiny between big black bars.
Stretch fills the panel and keeps the silhouette clearly readable.

To shrink the blob, cap the duration, e.g. `durationSeconds = 90;`
→ ~1800 frames ≈ 0.9 MB.

## The output format (`badapple.bin`)

Single file, little-endian:

```
Header (16 bytes):
  [0:4]   magic = 'B','A','D','A'
  [4:6]   u16 width  = 128
  [6:8]   u16 height = 32
  [8:10]  u16 fps
  [10:12] u16 flags = 0        (0 = uncompressed raw frames; only value supported)
  [12:16] u32 frame_count
Then frame_count frames, each exactly 512 bytes, SSD1306 page-major GDDRAM:
  byte index = page*128 + col          (page 0..3, col 0..127)
  within the byte, bit `row` (0..7, LSB = row0) is SET iff pixel
    (x=col, y=page*8+row) is ON (white).
```

This is byte-identical to the runtime framebuffer
(`pkgs/badge/nix-badge/nix-badge.c`): `fb[(y/8)*128 + x]` with bit `(y%8)`
(see `set_pixel()`), so the player can `read()`/`memcpy()` a frame straight
into `oled_fb` and flush. A fully-white frame is 512 bytes of `0xFF`; blank is
512 zero bytes.

Only `flags = 0` (uncompressed) is emitted; the runtime understands nothing
else, so this package never compresses.

## Swapping the source

The build is a pure function of `src`. To use different footage, override it —
any format ffmpeg can decode works:

```nix
import ./pkgs/badge/badapple {
  inherit pkgs;
  src = pkgs.fetchurl {
    url    = "https://.../your-video.mp4";
    name   = "your-video.mp4";
    sha256 = "…";   # nix-prefetch-url <url>, or copy the hash from a failed build
  };
}
```

or a local file: `src = ./my-clip.mp4;`, or a `fetchFromGitHub` of a repo that
ships a video. Nothing else needs to change; the transcode/pack/self-test run
identically.

### Default source

Pinned Internet Archive copy of the original Touhou *Bad Apple!!* PV:

- item: <https://archive.org/details/TouhouBadApple>
- file: `Touhou - Bad Apple.mp4` (480x360 h.264, ~219.5 s)
- url:  `https://archive.org/download/TouhouBadApple/Touhou%20-%20Bad%20Apple.mp4`
- sha256: `0b5e74f6607ad1562bdabd8c95317685fa83b811716d1dba0dce3bf6719752d3`

If Internet Archive is ever unreachable at build time, point `src` at any other
copy (the sha256 pins the bytes, so a mirror with identical content Just Works;
a different encode needs its own hash).

## Files

- `default.nix`   — the derivation (`{ pkgs, … }: derivation` → `$out/badapple.bin`).
- `pack.c`        — reads gray8 frames on stdin, thresholds, packs the blob.
- `gen_sample.c`  — makes `sample.bin` (a network-free format fixture; see below).
- `sample.bin`    — a small, valid, checked-in `.bin` the runtime team can test
                    against **without any network fetch**. It is **not** Bad Apple
                    footage — it is a procedural animation (bouncing circle +
                    sweeping scan bar + border) in the *exact same format*, so a
                    player that renders it correctly will render the real blob
                    correctly. 240 frames, 20 fps, 122 896 bytes.

Regenerate the sample:

```sh
cc -O2 -std=c11 -o gen_sample gen_sample.c && ./gen_sample > sample.bin
```
