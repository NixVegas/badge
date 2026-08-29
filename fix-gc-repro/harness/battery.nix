scope:
let
  __drawDep = (
let
  __oledDep = (
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

  );
  __fontDep = (
# GENERATED from Gallant19.bdf (Sun Gallant 12x22, CDDL). Do not edit.
# See LICENSE.gallant. width=12 height=22, row-major (bit 11 = leftmost col).
{
  width = 12;
  height = 22;
  glyphs = {
    "32" = [ 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ];
    "33" = [ 0 0 96 96 96 96 96 96 96 96 96 96 96 0 0 96 96 0 0 0 0 0 ];
    "34" = [ 0 0 408 408 408 408 408 408 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ];
    "35" = [ 0 0 51 51 51 102 511 511 204 204 408 408 2044 2044 816 1632 1632 0 0 0 0 0 ];
    "36" = [ 0 0 96 504 1020 1646 1638 1632 992 504 124 102 102 1638 2044 1016 96 0 0 0 0 0 ];
    "37" = [ 0 0 0 908 1228 1112 1624 944 48 96 96 192 220 422 418 818 796 0 0 0 0 0 ];
    "38" = [ 0 0 112 248 396 396 396 248 480 992 1904 1590 1566 1564 1560 1022 486 0 0 0 0 0 ];
    "39" = [ 0 0 192 480 480 96 96 192 384 256 0 0 0 0 0 0 0 0 0 0 0 0 ];
    "40" = [ 0 0 24 48 96 96 192 192 192 192 192 192 192 96 96 48 24 0 0 0 0 0 ];
    "41" = [ 0 0 384 192 96 96 48 48 48 48 48 48 48 96 96 192 384 0 0 0 0 0 ];
    "42" = [ 0 0 0 0 0 0 240 96 1638 1902 408 0 408 1902 1638 96 240 0 0 0 0 0 ];
    "43" = [ 0 0 0 0 0 0 0 96 96 96 96 2046 2046 96 96 96 96 0 0 0 0 0 ];
    "44" = [ 0 0 0 0 0 0 0 0 0 0 0 0 0 0 192 480 480 96 96 192 384 256 ];
    "45" = [ 0 0 0 0 0 0 0 0 0 0 0 2046 2046 0 0 0 0 0 0 0 0 0 ];
    "46" = [ 0 0 0 0 0 0 0 0 0 0 0 0 0 192 480 480 192 0 0 0 0 0 ];
    "47" = [ 0 0 6 12 12 24 24 48 48 96 96 192 192 384 384 768 768 1536 0 0 0 0 ];
    "48" = [ 0 0 112 248 280 268 780 780 780 780 780 780 780 776 392 496 224 0 0 0 0 0 ];
    "49" = [ 0 0 32 96 224 480 864 96 96 96 96 96 96 96 96 96 1020 0 0 0 0 0 ];
    "50" = [ 0 0 496 1016 1564 1036 12 12 12 24 48 96 192 384 770 2046 2046 0 0 0 0 0 ];
    "51" = [ 0 0 248 508 526 1030 6 14 124 252 14 6 6 1030 1540 1016 496 0 0 0 0 0 ];
    "52" = [ 0 0 24 56 56 88 88 152 152 280 280 536 1022 2046 24 24 24 0 0 0 0 0 ];
    "53" = [ 0 0 252 252 256 256 512 1016 796 14 6 6 6 1030 1542 780 504 0 0 0 0 0 ];
    "54" = [ 0 0 112 192 384 768 768 1536 1656 1788 1806 1542 1542 1542 1796 1016 496 0 0 0 0 0 ];
    "55" = [ 0 0 510 1022 1540 4 12 8 8 24 16 16 48 32 32 96 64 0 0 0 0 0 ];
    "56" = [ 0 0 240 280 780 780 780 392 208 96 176 280 780 780 780 392 240 0 0 0 0 0 ];
    "57" = [ 0 0 248 284 526 1542 1542 1542 1806 1014 486 6 12 12 24 112 960 0 0 0 0 0 ];
    "58" = [ 0 0 0 0 0 0 0 192 480 480 192 0 0 192 480 480 192 0 0 0 0 0 ];
    "59" = [ 0 0 0 0 0 0 0 0 192 480 480 192 0 0 192 480 480 96 96 192 384 256 ];
    "60" = [ 0 0 0 0 0 0 0 6 28 112 448 1792 1792 448 112 28 6 0 0 0 0 0 ];
    "61" = [ 0 0 0 0 0 0 0 0 0 2046 2046 0 0 2046 2046 0 0 0 0 0 0 0 ];
    "62" = [ 0 0 0 0 0 0 0 1536 896 224 56 14 14 56 224 896 1536 0 0 0 0 0 ];
    "63" = [ 0 0 240 504 924 524 12 12 24 48 96 192 192 0 0 192 192 0 0 0 0 0 ];
    "64" = [ 0 0 0 0 0 248 1020 774 1542 1650 1786 1738 1738 1662 1536 768 1022 254 0 0 0 0 ];
    "65" = [ 0 0 0 96 96 176 176 144 280 280 264 1020 524 516 1030 1030 3599 0 0 0 0 0 ];
    "66" = [ 0 0 0 4080 1544 1548 1548 1548 1560 2040 1548 1542 1542 1542 1542 1548 4088 0 0 0 0 0 ];
    "67" = [ 0 0 0 252 262 514 512 1536 1536 1536 1536 1536 1536 512 770 388 248 0 0 0 0 0 ];
    "68" = [ 0 0 0 4080 1564 1548 1542 1542 1542 1542 1542 1542 1542 1542 1540 1560 4064 0 0 0 0 0 ];
    "69" = [ 0 0 0 2044 772 772 768 768 776 1016 776 768 768 768 770 770 2046 0 0 0 0 0 ];
    "70" = [ 0 0 0 2044 772 772 768 768 776 1016 776 768 768 768 768 768 1920 0 0 0 0 0 ];
    "71" = [ 0 0 0 252 262 514 512 1536 1536 1536 1536 1567 1542 518 774 390 248 0 0 0 0 0 ];
    "72" = [ 0 0 0 3855 1542 1542 1542 1542 1542 2046 1542 1542 1542 1542 1542 1542 3855 0 0 0 0 0 ];
    "73" = [ 0 0 0 504 96 96 96 96 96 96 96 96 96 96 96 96 504 0 0 0 0 0 ];
    "74" = [ 0 0 0 504 96 96 96 96 96 96 96 96 96 96 96 96 96 96 96 64 896 768 ];
    "75" = [ 0 0 0 3854 1560 1584 1632 1728 1920 1920 1984 1760 1648 1592 1564 1550 3847 0 0 0 0 0 ];
    "76" = [ 0 0 0 1920 768 768 768 768 768 768 768 768 768 768 770 770 2046 0 0 0 0 0 ];
    "77" = [ 0 0 0 3591 1550 1806 1806 1806 1430 1430 1430 1238 1254 1254 1094 1094 3663 0 0 0 0 0 ];
    "78" = [ 0 0 0 3079 1538 1794 1922 1410 1218 1122 1138 1074 1050 1038 1038 1030 3587 0 0 0 0 0 ];
    "79" = [ 0 0 0 240 284 524 518 1542 1542 1542 1542 1542 1542 516 772 392 240 0 0 0 0 0 ];
    "80" = [ 0 0 0 2040 780 774 774 774 780 888 768 768 768 768 768 768 1920 0 0 0 0 0 ];
    "81" = [ 0 0 0 240 284 524 518 1542 1542 1542 1542 1542 1542 772 900 504 224 496 569 30 0 0 ];
    "82" = [ 0 0 0 4080 1560 1548 1548 1548 1544 2032 1984 1760 1648 1592 1564 1550 3847 0 0 0 0 0 ];
    "83" = [ 0 0 0 510 774 1538 1538 1792 960 480 120 28 14 1030 1030 1548 2040 0 0 0 0 0 ];
    "84" = [ 0 0 0 2046 1122 96 96 96 96 96 96 96 96 96 96 96 504 0 0 0 0 0 ];
    "85" = [ 0 0 0 3847 1538 1538 1538 1538 1538 1538 1538 1538 1538 1538 1796 1020 504 0 0 0 0 0 ];
    "86" = [ 0 0 0 3598 1540 776 776 776 400 400 400 160 224 224 64 64 64 0 0 0 0 0 ];
    "87" = [ 0 0 0 4079 1634 1634 1634 1890 1908 820 884 956 952 408 408 408 408 0 0 0 0 0 ];
    "88" = [ 0 0 0 3847 1538 772 904 392 208 96 96 176 280 284 524 1030 3599 0 0 0 0 0 ];
    "89" = [ 0 0 0 3847 1538 772 392 392 208 96 96 96 96 96 96 96 240 0 0 0 0 0 ];
    "90" = [ 0 0 0 1022 524 12 24 24 48 48 96 96 192 192 384 386 1022 0 0 0 0 0 ];
    "91" = [ 0 0 248 248 192 192 192 192 192 192 192 192 192 192 192 248 248 0 0 0 0 0 ];
    "92" = [ 0 0 1536 768 768 384 384 192 192 96 96 48 48 24 24 12 12 6 0 0 0 0 ];
    "93" = [ 0 0 496 496 48 48 48 48 48 48 48 48 48 48 48 496 496 0 0 0 0 0 ];
    "94" = [ 0 0 64 224 432 792 1548 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ];
    "95" = [ 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 4095 4095 0 0 ];
    "96" = [ 0 0 16 48 96 96 120 120 48 0 0 0 0 0 0 0 0 0 0 0 0 0 ];
    "97" = [ 0 0 0 0 0 0 0 248 396 268 60 460 780 780 780 924 494 0 0 0 0 0 ];
    "98" = [ 0 0 512 1536 3584 1536 1536 1656 1788 1806 1542 1542 1542 1542 1798 1932 1272 0 0 0 0 0 ];
    "99" = [ 0 0 0 0 0 0 0 504 796 524 1536 1536 1536 1536 1796 780 504 0 0 0 0 0 ];
    "100" = [ 0 0 6 14 6 6 6 246 798 526 1542 1542 1542 1542 1806 918 487 0 0 0 0 0 ];
    "101" = [ 0 0 0 0 0 0 0 240 780 1542 1542 2046 1536 1536 768 390 248 0 0 0 0 0 ];
    "102" = [ 0 0 56 76 76 192 192 192 192 1016 192 192 192 192 192 192 480 0 0 0 0 0 ];
    "103" = [ 0 0 0 0 0 0 0 498 798 1548 1548 1548 792 1008 1536 2044 1022 518 1026 1026 2044 1016 ];
    "104" = [ 0 0 256 768 1792 768 768 888 924 780 780 780 780 780 780 780 1950 0 0 0 0 0 ];
    "105" = [ 0 0 0 96 96 0 0 480 96 96 96 96 96 96 96 96 504 0 0 0 0 0 ];
    "106" = [ 0 0 0 12 12 0 0 60 12 12 12 12 12 12 12 12 12 524 780 904 496 224 ];
    "107" = [ 0 0 1536 3584 1536 1536 1536 1564 1584 1632 1984 1920 1984 1760 1648 1592 3870 0 0 0 0 0 ];
    "108" = [ 0 0 480 96 96 96 96 96 96 96 96 96 96 96 96 96 504 0 0 0 0 0 ];
    "109" = [ 0 0 0 0 0 0 0 3548 1774 1638 1638 1638 1638 1638 1638 1638 3831 0 0 0 0 0 ];
    "110" = [ 0 0 0 0 0 0 0 632 1948 780 780 780 780 780 780 780 1950 0 0 0 0 0 ];
    "111" = [ 0 0 0 0 0 0 0 248 284 526 1542 1542 1542 1542 1796 904 496 0 0 0 0 0 ];
    "112" = [ 0 0 0 0 0 0 0 3832 1820 1550 1542 1542 1542 1542 1540 1800 2032 1536 1536 1536 1536 3840 ];
    "113" = [ 0 0 0 0 0 0 0 242 286 526 1542 1542 1542 1542 1798 910 510 6 6 6 6 15 ];
    "114" = [ 0 0 0 0 0 0 0 1848 844 908 768 768 768 768 768 768 1920 0 0 0 0 0 ];
    "115" = [ 0 0 0 0 0 0 0 508 780 772 896 480 120 28 524 780 1016 0 0 0 0 0 ];
    "116" = [ 0 0 0 0 64 64 192 2044 192 192 192 192 192 192 194 228 120 0 0 0 0 0 ];
    "117" = [ 0 0 0 0 0 0 0 1950 780 780 780 780 780 780 780 924 486 0 0 0 0 0 ];
    "118" = [ 0 0 0 0 0 0 0 3847 1538 772 772 392 392 208 208 96 96 0 0 0 0 0 ];
    "119" = [ 0 0 0 0 0 0 0 4087 1634 1634 1634 884 948 948 408 408 408 0 0 0 0 0 ];
    "120" = [ 0 0 0 0 0 0 0 3983 1796 904 464 224 112 184 284 526 3871 0 0 0 0 0 ];
    "121" = [ 0 0 0 0 0 0 0 3855 1538 772 772 392 392 208 208 96 96 64 192 128 1920 1792 ];
    "122" = [ 0 0 0 0 0 0 0 2046 1550 1052 56 112 224 448 898 1798 2046 0 0 0 0 0 ];
    "123" = [ 0 0 56 96 96 96 96 96 192 896 192 96 96 96 96 96 56 0 0 0 0 0 ];
    "124" = [ 0 0 96 96 96 96 96 96 96 96 96 96 96 96 96 96 96 96 96 96 96 96 ];
    "125" = [ 0 0 448 96 96 96 96 96 48 28 48 96 96 96 96 96 448 0 0 0 0 0 ];
    "126" = [ 0 0 0 0 450 998 1660 1080 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ];
  };
}

  );
in (
# A pure-Nix OLED drawing library on a 128x32 mono framebuffer, used by the info
# screens (battery/load/power/clock) that the badge's embedded fix evaluator
# applies once per frame. It mirrors the Zig oled.zig primitives (setPixel /
# drawHbar) but draws text in the SUN GALLANT 12x22 console font (the classic
# SunOS/OpenBoot/Solaris pixel face) instead of the small 5x7 -- the Sun aesthetic.
# At 12x22 only ~10 chars fit across 128px and the 22px cell nearly fills the 32px
# panel, so each screen is one bold Gallant readout (clock "12:34:56", battery "87%"
# + bar, etc). The glyph table is GENERATED from an open, redistributable Gallant
# BDF (illumos-gate, CDDL) by gallant-font.nix -> gallant-font-data.nix; NO glyph
# is hand-typed. See LICENSE.gallant.
#
# The framebuffer is immutable: there is no mutation in Nix, so a "surface" is just
# a SET of lit pixels -- an attrset keyed "x,y" -> true. Every primitive returns a
# NEW surface with more keys added (functional accumulate). At the end `pack surf`
# walks the SSD1306 page-major grid through oled.nix's packFrame (col:row:bool ->
# 512 page-bytes) and folds each 4 consecutive page-bytes into one LE int, giving
# the flat 128-int `bitmap` list. Decode check (renderOled): bitmap[i] = b0 | b1<<8
# | b2<<16 | b3<<24 where b0..b3 = packFrame bytes 4i..4i+3.
#
# Only builtins are used (no nixpkgs lib) so `fix eval` runs it standalone, and no
# string ever holds a NUL -- pixel/glyph data is int lists, coordinates are keys.
let
  oled = __oledDep; # packFrame, mod, p2, range
  inherit (oled) mod p2 range;

  font = __fontDep; # { width=12; height=22; glyphs = { "<cp>" = [22 row ints]; }; }

  # ----------------------------------------------------------------- surface ---
  # A surface is `{ "x,y" = true; ... }`. `empty` is the blank panel.
  empty = { };

  key = x: y: "${toString x},${toString y}";

  # Light one pixel. Off-panel coordinates are dropped (Zig setPixel clips), so a
  # caller never has to bound-check.
  setPixel =
    surf: x: y:
    if x >= 0 && x < width && y >= 0 && y < height then surf // { ${key x y} = true; } else surf;

  # Light a list of {x;y;} points onto a surface (fold helper the primitives use).
  setPoints =
    surf: pts:
    builtins.foldl' (s: p: setPixel s p.x p.y) surf pts;

  width = 128;
  height = 32;

  # ----------------------------------------------------------- rect / lines ---
  # Horizontal run of `w` pixels at row y from x.
  hline =
    surf: x: y: w:
    setPoints surf (map (i: {
      x = x + i;
      y = y;
    }) (range 0 w));

  # Vertical run of `h` pixels at col x from y.
  vline =
    surf: x: y: h:
    setPoints surf (map (j: {
      x = x;
      y = y + j;
    }) (range 0 h));

  # Filled w x h rectangle with top-left (x,y).
  fillRect =
    surf: x: y: w: h:
    builtins.foldl' (s: j: hline s x (y + j) w) surf (range 0 h);

  # Hollow w x h rectangle (border only).
  rect =
    surf: x: y: w: h:
    let
      a = hline surf x y w;
      b = hline a x (y + h - 1) w;
      c = vline b x y h;
    in
    vline c (x + w - 1) y h;

  # -------------------------------------------------------------- Gallant font ---
  # Gallant is a fixed 12x22 cell, ROW-MAJOR: glyphs."<cp>" is 22 ints, one per row,
  # bit 11 = leftmost column (see gallant-bdf-to-nix.awk). Pixel (col,row) of a glyph
  # is lit iff bit (11-col) of row int `r` is set, i.e. (r / 2^(11-col)) is odd.
  gW = font.width; # 12
  gH = font.height; # 22
  glyphW = gW + 1; # 13px advance (12px cell + 1px inter-char gap)

  # Codepoint of a single ASCII char string. builtins has no ord, so map the exact
  # printable chars the screens emit. Anything absent -> space (blank cell).
  codepointOf =
    c:
    let
      m = {
        " " = 32;
        "!" = 33;
        "\"" = 34;
        "#" = 35;
        "$" = 36;
        "%" = 37;
        "&" = 38;
        "'" = 39;
        "(" = 40;
        ")" = 41;
        "*" = 42;
        "+" = 43;
        "," = 44;
        "-" = 45;
        "." = 46;
        "/" = 47;
        "0" = 48;
        "1" = 49;
        "2" = 50;
        "3" = 51;
        "4" = 52;
        "5" = 53;
        "6" = 54;
        "7" = 55;
        "8" = 56;
        "9" = 57;
        ":" = 58;
        ";" = 59;
        "<" = 60;
        "=" = 61;
        ">" = 62;
        "?" = 63;
        "@" = 64;
        "A" = 65;
        "B" = 66;
        "C" = 67;
        "D" = 68;
        "E" = 69;
        "F" = 70;
        "G" = 71;
        "H" = 72;
        "I" = 73;
        "J" = 74;
        "K" = 75;
        "L" = 76;
        "M" = 77;
        "N" = 78;
        "O" = 79;
        "P" = 80;
        "Q" = 81;
        "R" = 82;
        "S" = 83;
        "T" = 84;
        "U" = 85;
        "V" = 86;
        "W" = 87;
        "X" = 88;
        "Y" = 89;
        "Z" = 90;
        "a" = 97;
        "b" = 98;
        "c" = 99;
        "d" = 100;
        "e" = 101;
        "f" = 102;
        "g" = 103;
        "h" = 104;
        "i" = 105;
        "j" = 106;
        "k" = 107;
        "l" = 108;
        "m" = 109;
        "n" = 110;
        "o" = 111;
        "p" = 112;
        "q" = 113;
        "r" = 114;
        "s" = 115;
        "t" = 116;
        "u" = 117;
        "v" = 118;
        "w" = 119;
        "x" = 120;
        "y" = 121;
        "z" = 122;
      };
    in
    if m ? ${c} then m.${c} else 32;

  # Explode a string into a list of single-char strings.
  chars = s: builtins.genList (i: builtins.substring i 1 s) (builtins.stringLength s);

  # The 22 row ints for a char (blank row list if the codepoint isn't in the table).
  blankRows = builtins.genList (_: 0) gH;
  glyphRows =
    c:
    let
      cp = toString (codepointOf c);
    in
    if font.glyphs ? ${cp} then font.glyphs.${cp} else blankRows;

  # bit `n` (from the LSB) of `v` set?
  bitSet = v: n: mod (v / (p2 n)) 2 == 1;

  # Draw one Gallant glyph at (x,y): 22 rows, 12 cols; light where the row bit is
  # set. Column c uses bit (gW-1-c) so bit 11 is the leftmost column.
  drawChar =
    surf: x: y: c:
    let
      rows = glyphRows c;
    in
    builtins.foldl' (
      s: row:
      let
        r = builtins.elemAt rows row;
      in
      builtins.foldl' (
        s2: col: if bitSet r (gW - 1 - col) then setPixel s2 (x + col) (y + row) else s2
      ) s (range 0 gW)
    ) surf (range 0 gH);

  # Draw a string left-to-right in Gallant; stops at the right edge (oled.zig drawText).
  drawText =
    surf: x: y: s:
    (builtins.foldl' (
      acc: c:
      if acc.x >= width then acc else { x = acc.x + glyphW; surf = drawChar acc.surf acc.x y c; }
    ) { x = x; surf = surf; } (chars s)).surf;

  # Rendered pixel width of a Gallant string (for right/centre alignment).
  textWidth = s: builtins.stringLength s * glyphW;

  # A hollow gauge (x,y,w,h) with the leftmost `frac` of the interior filled.
  # Mirrors oled.zig drawHbar EXACTLY: border, then `round(inner*frac)` filled
  # interior columns, inner = w-2, rounding = floor(inner*frac + 0.5).
  drawBar =
    surf: x: y: w: h: frac:
    if w < 2 || h < 2 then
      surf
    else
      let
        f = if frac < 0.0 then 0.0 else if frac > 1.0 then 1.0 else frac;
        r = rect surf x y w h;
        inner = w - 2;
        # floor(inner*f + 0.5): Nix truncates float->int toward zero for >=0.
        fill = let v = inner * f + 0.5; in builtins.floor v;
        fillPts = builtins.concatLists (
          map (i: map (j: { x = x + 1 + i; y = y + j; }) (range 1 (h - 2))) (range 0 fill)
        );
      in
      setPoints r fillPts;

  # ---------------------------------------------------------------- packing ---
  # Surface -> the flat 128-int bitmap renderOled decodes. First render the SSD1306
  # page-major 512 bytes via oled.nix's packFrame (col:row:bool), then fold each 4
  # consecutive bytes into one LE int (b0 | b1<<8 | b2<<16 | b3<<24).
  pack =
    surf:
    let
      bytes = oled.packFrame {
        inherit width height;
        px = col: row: surf ? ${key col row};
      };
      nInts = (builtins.length bytes) / 4;
    in
    builtins.genList (
      i:
      let
        b0 = builtins.elemAt bytes (i * 4 + 0);
        b1 = builtins.elemAt bytes (i * 4 + 1);
        b2 = builtins.elemAt bytes (i * 4 + 2);
        b3 = builtins.elemAt bytes (i * 4 + 3);
      in
      b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    ) nInts;

  # -------------------------------------------------------- number helpers ---
  # Right-justified integer to a fixed field of `n` chars, space-padded.
  padLeft =
    n: s:
    let
      d = n - builtins.stringLength s;
    in
    if d <= 0 then s else builtins.concatStringsSep "" (builtins.genList (_: " ") d) + s;

  # Zero-padded 2-digit int (00..99+; wider ints keep their digits).
  pad2 =
    n:
    let
      s = toString n;
    in
    if builtins.stringLength s < 2 then "0${s}" else s;

  # An int scaled by 1000 rendered "X.XX": e.g. mv 4100 -> "4.10". Truncates.
  fixed2 =
    milliInt:
    let
      whole = milliInt / 1000;
      frac = mod milliInt 1000; # 0..999
      hund = frac / 10; # 0..99, truncate to hundredths
    in
    "${toString whole}.${pad2 hund}";
in
{
  inherit
    empty
    setPixel
    setPoints
    hline
    vline
    fillRect
    rect
    drawChar
    drawText
    drawBar
    pack
    padLeft
    pad2
    fixed2
    glyphW
    textWidth
    width
    height
    ;
  fontWidth = gW;
  fontHeight = gH;
  inherit (oled) mod range;
}
)
  );
in (
# The battery info screen as a PURE-NIX per-frame pattern (fix applyValue), drawn
# in the Sun Gallant 12x22 font. Reproduces the Zig `screens.battery` info: the
# charge percent BIG (Gallant), a charge bar, the battery millivolts, and a charge
# mark when on USB. Packed byte-for-byte to the 128-int bitmap renderOled decodes.
#
#   [ NN% ]  [+]        <- Gallant percent (top), '+' charge mark when onUsb
#   [=======bar=======] <- charge bar across the bottom, frac = pct/100
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ 128 ints ]; nextMs; }
scope:
let
  d = __drawDep;
  inherit (d) width height glyphW;

  pct = if scope.batteryPct > 100 then 100 else scope.batteryPct;
  frac = pct * 1.0 / 100.0;

  pctStr = "${toString pct}%";

  # Big Gallant percent, top-left. A '+' charge mark to its right when on USB.
  s0 = d.drawText d.empty 0 0 pctStr;
  markX = d.textWidth pctStr + 2;
  s1 = if scope.onUsb then d.drawText s0 markX 0 "+" else s0;

  # Millivolts as a small tag, right-aligned on the top-right where the big text
  # ends (Gallant "X.XXV" would overflow, so show just the volts compactly).
  mvStr = "${d.fixed2 scope.batteryMv}V";
  mvX = let x = width - d.textWidth mvStr; in if x < markX + glyphW then markX + glyphW else x;
  # Only draw the mV tag if it fits without colliding with the percent/charge mark.
  s2 = if mvX + d.textWidth mvStr <= width && mvX > markX then d.drawText s1 mvX 0 mvStr else s1;

  # Charge bar across the bottom (frac of interior filled). height-6..height-1.
  s3 = d.drawBar s2 0 (height - 6) width 6 frac;
in
{
  bitmap = d.pack s3;
  nextMs = 500; # a slow meter; 2 Hz is plenty (matches the Zig battery return)
}
) scope
