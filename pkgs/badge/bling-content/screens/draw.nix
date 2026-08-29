# A pure-Nix OLED drawing library on a 128xH mono framebuffer (H = the real panel
# height, 32 or 64), used by the info screens (battery/load/power/clock) that the
# badge's embedded fix evaluator applies once per frame. It mirrors the Zig oled.zig
# primitives (setPixel / drawHbar) and draws text in TWO open bitmap faces so a
# screen can pair a bold hero readout with dense detail rows:
#   * SUN GALLANT 12x22 -- the classic SunOS/OpenBoot/Solaris console face; ~10
#     chars across 128px and 22px tall of the 32px panel. Used for the big
#     hero/header value on each screen (clock "12:34:56", battery "87%").
#   * SPLEEN 5x8 (and 8x16) -- Frederic Cambus' clean fixed bitmap font; at 5x8 a
#     detail row fits ~21 chars across 128px, so it carries the secondary rows
#     (millivolts, a label, the full currentSystem string, etc).
# Both glyph tables are GENERATED from open, redistributable BDFs -- Gallant from
# illumos-gate (CDDL) by gallant-font.nix, Spleen (BSD-2-Clause) by spleen-font.nix
# -- into *-font-data.nix; NO glyph is hand-typed. See LICENSE.gallant / LICENSE.spleen.
#
# Text is drawn through a FONT-DRIVEN core: `mkFont <table>` yields a face with its
# own `drawText` / `drawChar` / `textWidth` / `glyphW`, so a screen renders a row in
# Gallant or Spleen by picking the face. The bare `drawText` / `textWidth` / `glyphW`
# on this module stay bound to Gallant (the original default), so nothing breaks.
#
# The framebuffer is immutable: there is no mutation in Nix, so a "surface" is just
# a SET of lit pixels -- an attrset keyed "x,y" -> true. Every primitive returns a
# NEW surface with more keys added (functional accumulate). At the end `pack surf`
# walks the SSD1306 page-major grid through oled.nix's packFrame (col:row:bool ->
# width*height/8 page-bytes) and folds each 4 consecutive page-bytes into one LE
# int, giving the flat `width*height/8/4`-int `bitmap` list (128 ints at 128x32,
# 256 ints at 128x64). Decode check (renderOled): bitmap[i] = b0 | b1<<8 | b2<<16
# | b3<<24 where b0..b3 = packFrame bytes 4i..4i+3.
#
# The module is a FUNCTION of the real panel geometry: a screen applies this to
# `{ inherit (scope) width height; }` -- so every screen packs to the panel it is
# actually drawn on (nix-badge passes the true height as scope.height). `height`
# MUST be a multiple of 8 (SSD1306 pages); 32 and 64 are the supported panels.
#
# Only builtins are used (no nixpkgs lib) so `fix eval` runs it standalone, and no
# string ever holds a NUL -- pixel/glyph data is int lists, coordinates are keys.
{
  width ? 128,
  height ? 32,
}:
let
  oled = import ../oled.nix; # packFrame, mod, p2, range
  inherit (oled) mod p2 range;

  # Font glyph tables, each { width; height; glyphs = { "<cp>" = [height row ints]; }; }
  # with bit (width-1) = leftmost column (see the *-bdf-to-nix.awk generators).
  gallantFont = import ./gallant-font-data.nix; # 12x22 Sun Gallant (hero face)
  spleen5x8Font = import ./spleen-5x8-font-data.nix; # 5x8 Spleen (dense detail)
  spleen8x16Font = import ./spleen-8x16-font-data.nix; # 8x16 Spleen (mid)

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

  # `width` / `height` are function args (the real panel geometry). `pages` and the
  # packed-int count both derive from them, so a screen packs to the panel it is on.

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

  # ---------------------------------------------------------- font-driven text ---
  # Each font table is a fixed WxH cell, ROW-MAJOR: glyphs."<cp>" is H ints, one per
  # row, bit (W-1) = leftmost column (see the *-bdf-to-nix.awk generators). Pixel
  # (col,row) of a glyph is lit iff bit (W-1-col) of row int `r` is set, i.e.
  # (r / 2^(W-1-col)) is odd. `mkFont` closes a face's draw helpers over one table.

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

  # bit `n` (from the LSB) of `v` set?
  bitSet = v: n: mod (v / (p2 n)) 2 == 1;

  # Build a face from a font table: its own drawChar/drawText/textWidth + metrics.
  # `advance` is the per-glyph x-step (cell width + 1px inter-char gap). Everything
  # closes over the given table, so Gallant and Spleen share one code path.
  mkFont =
    tbl:
    let
      fW = tbl.width;
      fH = tbl.height;
      advance = fW + 1; # cell width + 1px gap
      blank = builtins.genList (_: 0) fH;
      # The fH row ints for a char (blank if the codepoint isn't in this table).
      rowsFor =
        c:
        let
          cp = toString (codepointOf c);
        in
        if tbl.glyphs ? ${cp} then tbl.glyphs.${cp} else blank;
      # Draw one glyph at (x,y): fH rows, fW cols; column c uses bit (fW-1-c) so the
      # leftmost column is the high bit.
      drawCharF =
        surf: x: y: c:
        let
          rows = rowsFor c;
        in
        builtins.foldl' (
          s: row:
          let
            r = builtins.elemAt rows row;
          in
          builtins.foldl' (
            s2: col: if bitSet r (fW - 1 - col) then setPixel s2 (x + col) (y + row) else s2
          ) s (range 0 fW)
        ) surf (range 0 fH);
      # Draw a string left-to-right; stops at the right edge (oled.zig drawText).
      drawTextF =
        surf: x: y: s:
        (builtins.foldl' (
          acc: c:
          if acc.x >= width then acc else { x = acc.x + advance; surf = drawCharF acc.surf acc.x y c; }
        ) { x = x; surf = surf; } (chars s)).surf;
    in
    {
      inherit advance;
      width = fW;
      height = fH;
      glyphW = advance; # advance width per char (alias, matches the old name)
      drawChar = drawCharF;
      drawText = drawTextF;
      # Rendered pixel width of a string in this face (for right/centre alignment).
      textWidth = s: builtins.stringLength s * advance;
    };

  gallant = mkFont gallantFont; # 12x22 hero face
  spleen5x8 = mkFont spleen5x8Font; # 5x8 dense detail face
  spleen8x16 = mkFont spleen8x16Font; # 8x16 mid face

  # Backward-compatible bare helpers: the original module drew Gallant, so the bare
  # names stay bound to it (existing callers keep working unchanged).
  inherit (gallant) drawChar drawText textWidth glyphW;
  gW = gallant.width; # 12
  gH = gallant.height; # 22

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
  # Bare font metrics stay Gallant's (backward-compatible).
  fontWidth = gW;
  fontHeight = gH;
  # The three faces: each is { drawText; drawChar; textWidth; glyphW; width; height; }.
  # Screens pick `gallant` for the hero readout and `spleen5x8` for detail rows.
  inherit gallant spleen5x8 spleen8x16;
  inherit (oled) mod range;
}
