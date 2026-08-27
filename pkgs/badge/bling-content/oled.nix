# Pure-Nix builder for the SSD1306 "BADA" 1-bit frame blob -- the exact format
# the Zig runtime's badapple screen mmaps and plays (see pkgs/badge/badapple and
# pkgs/badge/nix-badge/badapple.zig). "Author the screens in Nix" means: describe
# an animation as a function of frame index, evaluate it (with `fix`, or stock
# nix), and bake the result to this blob -- no runtime Nix on the badge.
#
# Only builtins are used (no nixpkgs lib), so `fix eval` evaluates it standalone.
# Nix has no shift/pow builtin and strings cannot hold NUL, so we pack to a byte
# list and emit lowercase hex (fix eval --raw | xxd -r -p -> binary), matching
# how nixboy hex-encodes its data.
#
# Blob layout (little-endian), identical to the ffmpeg-baked Bad Apple:
#   magic "BADA", u16 width, u16 height, u16 fps, u16 flags(0), u32 frame_count,
#   then frame_count frames of width*(height/8) bytes in SSD1306 page-major order:
#   byte[page*width + col], bit `row` = pixel (col, page*8+row) is lit.
rec {
  # [a, a+1, ..., a+n-1]
  range = a: n: builtins.genList (i: a + i) n;
  concatMap = f: xs: builtins.concatLists (map f xs);

  # 2^n by repeated doubling (no bit-shift builtin in Nix).
  p2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);
  # a mod b (no builtins.mod; Nix integer division floors for non-negatives).
  mod = a: b: a - (a / b) * b;

  # little-endian byte lists
  u16 = n: [ (mod n 256) (mod (n / 256) 256) ];
  u32 = n: [
    (mod n 256)
    (mod (n / 256) 256)
    (mod (n / 65536) 256)
    (mod (n / 16777216) 256)
  ];

  # Pack one frame into page-major bytes. `px` is `col: row: bool` (true = lit).
  packFrame =
    { width, height, px }:
    let
      pages = height / 8;
    in
    concatMap (
      page:
      map (
        col: builtins.foldl' (b: row: b + (if px col (page * 8 + row) then p2 row else 0)) 0 (range 0 8)
      ) (range 0 width)
    ) (range 0 pages);

  # Whole blob as a byte list. `frames` is a list of `col: row: bool` functions.
  badaBytes =
    {
      width,
      height,
      fps,
      frames,
    }:
    let
      count = builtins.length frames;
    in
    [ 66 65 68 65 ] # "BADA"
    ++ u16 width
    ++ u16 height
    ++ u16 fps
    ++ u16 0 # flags = 0 (uncompressed)
    ++ u32 count
    ++ concatMap (f: packFrame { inherit width height; px = f; }) frames;

  # Byte list -> lowercase hex string.
  hex =
    bytes:
    let
      d = "0123456789abcdef";
    in
    builtins.concatStringsSep "" (
      map (b: "${builtins.substring (b / 16) 1 d}${builtins.substring (mod b 16) 1 d}") bytes
    );

  # An animation spec -> hex blob string (the thing `fix eval --raw` prints).
  badaHex = spec: hex (badaBytes spec);
}
