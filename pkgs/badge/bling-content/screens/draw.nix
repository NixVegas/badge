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
# ---------------------------------------------------------------------------------
# RENDERING MODEL (light, column-byte / page-major -- NOT the old per-pixel attrset).
# ---------------------------------------------------------------------------------
# The old library modelled a "surface" as `{ "x,y" = true; }` and every primitive did
# `surf // { ... }` per LIT PIXEL, then `pack` scanned all width*height/8 page bytes
# doing a per-pixel attrset lookup -- hundreds of merges + a 1024-cell scan PER FRAME,
# ~1s/frame on the badge, thrashing swap until it looked crashed.
#
# This library instead computes the SSD1306 GDDRAM bytes DIRECTLY. The framebuffer is
# the packed byte grid itself: byte index = page*width + col (page = y/8), and that
# byte's bit `r` (0=LSB) is pixel (col, page*8+r). A draw op contributes a set of
# `{ off; bit; }` entries (one per touched page-column cell, each an 8-pixel vertical
# strip), OR-accumulated into a sparse map `{ "<off>" = oredByte; }`. `pack` then folds
# 4 consecutive bytes into one LE int over the width*height/8/4 ints -- reading the map
# with default 0, no per-pixel work. Total per-frame cost ~ O(text columns + bar cells),
# a few hundred ops, not thousands of `//` + a 1024-cell scan.
#
# Fonts are transposed ONCE (at this file's top level, ABOVE the `{width,height}:`
# geometry lambda, so it is shared across every frame -- `import` memoises by path):
# each glyph column becomes vertical column BYTES, one per page-row the WxH cell spans
# (Gallant 22px -> 3 page slices; Spleen 8px -> 1). Drawing at a sub-page y just shifts
# each column byte by `y mod 8` into two adjacent pages (integer mul/div by 2^k, then
# mod 256 -- no floats, no bit-shift builtin needed beyond p2).
#
# Only builtins are used (no nixpkgs lib) so `fix eval` runs it standalone, and no
# string ever holds a NUL -- glyph data is int lists, byte offsets are decimal keys.
#
# The module is a FUNCTION of the real panel geometry: a screen applies this to
# `{ inherit (scope) width height; }`. `height` MUST be a multiple of 8 (SSD1306
# pages); 32 and 64 are the supported panels.
let
  oled = import ../oled.nix; # p2, mod, range
  inherit (oled) mod p2 range;

  # Font glyph tables, each { width; height; glyphs = { "<cp>" = [height row ints]; }; }
  # ROW-MAJOR: glyphs."<cp>" is `height` ints, one per row, bit (width-1) = leftmost
  # column (see the *-bdf-to-nix.awk generators).
  gallantFont = import ./gallant-font-data.nix; # 12x22 Sun Gallant (hero face)
  spleen5x8Font = import ./spleen-5x8-font-data.nix; # 5x8 Spleen (dense detail)
  spleen8x16Font = import ./spleen-8x16-font-data.nix; # 8x16 Spleen (mid)

  # bit `n` (from the LSB) of `v` set? (integer, no bitAnd needed for a single bit).
  bitSet = v: n: mod (v / (p2 n)) 2 == 1;

  # ---------------------------------------------------------- font transpose ---
  # Transpose ONE glyph (row-major `rows`, WxH) into a per-column list of `slices`
  # vertical BYTES, where slices = ceil(H/8) page-rows. slice s of column c is the byte
  # whose bit r (0..7) = pixel (col=c, row=s*8+r) of the glyph, i.e. row-int
  # rows[s*8+r], column bit (W-1-c). This is the exact row-major -> column-byte flip
  # lib/font.nix does, generalised to a cell taller than one page.
  #   result[c] = [ sliceByte0 sliceByte1 ... ]   (length = slices)
  glyphColumns =
    fW: fH: rows:
    let
      slices = (fH + 7) / 8; # page-rows the cell spans (Gallant 22 -> 3, Spleen 8 -> 1)
      colByte =
        c: s:
        # OR the 8 rows of page-slice s for column c into one byte.
        builtins.foldl' (
          acc: r:
          let
            row = s * 8 + r;
          in
          if row < fH && bitSet (builtins.elemAt rows row) (fW - 1 - c) then acc + p2 r else acc
        ) 0 (range 0 8);
    in
    builtins.genList (c: builtins.genList (s: colByte c s) slices) fW;

  # Precompute a whole font table into { width; height; slices; advance; blankCols;
  # cols = { "<cp>" = [ [sliceBytes] per column ]; }; }. Evaluated ONCE per font at this
  # file's top level (shared across every frame). `advance` = cell width + 1px gap.
  mkFontData =
    tbl:
    let
      fW = tbl.width;
      fH = tbl.height;
      slices = (fH + 7) / 8;
      blankCol = builtins.genList (_: 0) slices;
    in
    {
      width = fW;
      height = fH;
      inherit slices;
      advance = fW + 1;
      blankCols = builtins.genList (_: blankCol) fW; # a whole blank cell's columns
      cols = builtins.mapAttrs (_: rows: glyphColumns fW fH rows) tbl.glyphs;
    };

  gallantData = mkFontData gallantFont;
  spleen5x8Data = mkFontData spleen5x8Font;
  spleen8x16Data = mkFontData spleen8x16Font;

  # Codepoint of a single ASCII char string. builtins has no ord, so map the exact
  # printable chars the screens emit. Anything absent -> space (blank cell).
  codepointOf =
    c:
    let
      m = {
        " " = 32; "!" = 33; "\"" = 34; "#" = 35; "$" = 36; "%" = 37; "&" = 38;
        "'" = 39; "(" = 40; ")" = 41; "*" = 42; "+" = 43; "," = 44; "-" = 45;
        "." = 46; "/" = 47;
        "0" = 48; "1" = 49; "2" = 50; "3" = 51; "4" = 52; "5" = 53; "6" = 54;
        "7" = 55; "8" = 56; "9" = 57;
        ":" = 58; ";" = 59; "<" = 60; "=" = 61; ">" = 62; "?" = 63; "@" = 64;
        "A" = 65; "B" = 66; "C" = 67; "D" = 68; "E" = 69; "F" = 70; "G" = 71;
        "H" = 72; "I" = 73; "J" = 74; "K" = 75; "L" = 76; "M" = 77; "N" = 78;
        "O" = 79; "P" = 80; "Q" = 81; "R" = 82; "S" = 83; "T" = 84; "U" = 85;
        "V" = 86; "W" = 87; "X" = 88; "Y" = 89; "Z" = 90;
        "a" = 97; "b" = 98; "c" = 99; "d" = 100; "e" = 101; "f" = 102; "g" = 103;
        "h" = 104; "i" = 105; "j" = 106; "k" = 107; "l" = 108; "m" = 109; "n" = 110;
        "o" = 111; "p" = 112; "q" = 113; "r" = 114; "s" = 115; "t" = 116; "u" = 117;
        "v" = 118; "w" = 119; "x" = 120; "y" = 121; "z" = 122;
      };
    in
    if m ? ${c} then m.${c} else 32;

  # Explode a string into a list of single-char strings.
  chars = s: builtins.genList (i: builtins.substring i 1 s) (builtins.stringLength s);

  # The per-column slice bytes for a char in a given (precomputed) font (blank if the
  # codepoint isn't in the table).
  colsForChar =
    fontData: c:
    let
      cp = toString (codepointOf c);
    in
    if fontData.cols ? ${cp} then fontData.cols.${cp} else fontData.blankCols;
in
# --------------------------------------------------------------------------------
# The geometry-dependent surface below. Everything ABOVE (font transposes, codepoint
# map) is hoisted out of this lambda and shared across frames.
# --------------------------------------------------------------------------------
{
  width ? 128,
  height ? 32,
}:
let
  pages = height / 8;
  nBytes = width * height / 8;
  nInts = nBytes / 4;

  # ------------------------------------------------------------------ surface ---
  # A surface is an APPEND-ONLY LIST of `{ off; byte; }` byte contributions (off =
  # page*width + col). Composition is list concatenation -- O(1) amortised, NOT the old
  # `surf // {..}` which copies the whole growing attrset every pixel (O(n^2)). Overlaps
  # are resolved by an OR at `pack` time in ONE pass, so a primitive never merges.
  # Off-panel contributions are simply omitted (matching the Zig setPixel clip).
  empty = [ ];

  # OR-in `b` onto `a` (integer bitOr; keeps things one 8-bit byte).
  orI = a: b: builtins.bitOr a b;

  # Entries for a vertical run of pixels: column x, rows y0 .. y0+h-1, one { off; byte; }
  # per page the run covers (an 8-pixel strip masked to the run). Returns a LIST; the
  # caller concatenates it into the surface. Empty when off-panel.
  vrunEntries =
    x: y0: h:
    let
      y1 = y0 + h - 1; # last lit row (inclusive)
    in
    if h <= 0 || x < 0 || x >= width || y1 < 0 || y0 >= height then
      [ ] # fully off-panel (or empty) -> no entries (matches Zig setPixel clip)
    else
      let
        p0 = if y0 < 0 then 0 else y0 / 8;
        p1 = if y1 >= height then pages - 1 else y1 / 8;
      in
      builtins.genList (
        i:
        let
          page = p0 + i;
          base = page * 8;
          lo = if y0 > base then y0 - base else 0; # first lit row within page
          hi = if y1 < base + 7 then y1 - base else 7; # last lit row within page
          byte = (p2 (hi + 1) - 1) - (p2 lo - 1); # bits lo..hi set
        in
        {
          off = page * width + x;
          inherit byte;
        }
      ) (p1 - p0 + 1);

  # Append the entries of a vertical run to a surface.
  orVRun = surf: x: y0: h: surf ++ vrunEntries x y0 h;

  # Light one pixel (compat shim). Off-panel dropped.
  setPixel =
    surf: x: y:
    if x >= 0 && x < width && y >= 0 && y < height then orVRun surf x y 1 else surf;

  # ----------------------------------------------------------- rect / lines ---
  # Horizontal run of `w` pixels at row y from x: one single-bit byte per column.
  hline =
    surf: x: y: w:
    surf ++ builtins.concatMap (i: vrunEntries (x + i) y 1) (range 0 w);

  # Vertical run of `h` pixels at col x from y.
  vline = surf: x: y: h: orVRun surf x y h;

  # Filled w x h rectangle with top-left (x,y): one vertical run per column.
  fillRect =
    surf: x: y: w: h:
    surf ++ builtins.concatMap (i: vrunEntries (x + i) y h) (range 0 w);

  # Hollow w x h rectangle (border only).
  rect =
    surf: x: y: w: h:
    let
      top = hline surf x y w;
      bot = hline top x (y + h - 1) w;
      l = vline bot x y h;
    in
    vline l (x + w - 1) y h;

  # ---------------------------------------------------------- font-driven text ---
  # Byte-entry contribution of ONE cell byte `v` at (page, col) placed with sub-page
  # `off` = y mod 8: the byte splits into `page` (bits shifted up by off) and, if off>0,
  # `page+1` (bits that spilled past the top). Returns 0..2 { off; byte; } entries,
  # dropping off-panel/zero bytes. Pure integer mul/div/mod by powers of two.
  cellEntries =
    col: page: v: lowShift: hiShift: off:
    if v == 0 || col < 0 || col >= width then
      [ ]
    else
      let
        lowByte = mod (v * lowShift) 256; # bits landing in `page`
        hiByte = if off == 0 then 0 else v / hiShift; # bits spilling to page+1
        lo =
          if lowByte != 0 && page >= 0 && page < pages then
            [ { off = page * width + col; byte = lowByte; } ]
          else
            [ ];
        hi =
          if hiByte != 0 && page + 1 >= 0 && page + 1 < pages then
            [ { off = (page + 1) * width + col; byte = hiByte; } ]
          else
            [ ];
      in
      lo ++ hi;

  # Draw one glyph at (x,y) from its precomputed column slices. Each column c has
  # `slices` vertical bytes (page-rows of the CELL, top-aligned at y). Placed at panel
  # y: cell page-row s maps to absolute rows (y + s*8 .. y + s*8+7); a sub-page offset
  # `y mod 8` shifts each byte across two adjacent pages. Emits an entry LIST, concatenated
  # onto the surface (no per-pixel merge).
  glyphEntries =
    fontData: x: y: cols:
    let
      off = mod y 8; # sub-page shift 0..7
      basePage = (y - off) / 8; # NB: y may be negative; screens keep y>=0
      lowShift = p2 off; # multiply to move bits up within a page
      hiShift = p2 (8 - off); # divide to get the bits that spilled into next page
      nCols = builtins.length cols;
    in
    builtins.concatMap (
      c:
      let
        colBytes = builtins.elemAt cols c; # `slices` bytes for this column
        colX = x + c;
      in
      builtins.concatMap (
        sIdx:
        cellEntries colX (basePage + sIdx) (builtins.elemAt colBytes sIdx) lowShift hiShift off
      ) (range 0 fontData.slices)
    ) (range 0 nCols);

  drawGlyphCols = fontData: surf: x: y: cols: surf ++ glyphEntries fontData x y cols;

  # Draw a string left-to-right; stops at the right edge (oled.zig drawText). Collects
  # each visible glyph's entry-list and concatenates them onto the surface in ONE pass
  # (no repeated `++` of the growing surface).
  drawTextWith =
    fontData: surf: x: y: str:
    let
      adv = fontData.advance;
      cs = chars str;
      # x position of char i.
      perChar = builtins.genList (
        i:
        let
          cx = x + i * adv;
        in
        if cx >= width then [ ] else glyphEntries fontData cx y (colsForChar fontData (builtins.elemAt cs i))
      ) (builtins.length cs);
    in
    surf ++ builtins.concatLists perChar;

  # Build a face bound to one precomputed font: drawText/drawChar/textWidth + metrics.
  mkFace = fontData: {
    advance = fontData.advance;
    width = fontData.width;
    height = fontData.height;
    glyphW = fontData.advance; # advance width per char (alias, matches the old name)
    drawChar = surf: x: y: c: drawGlyphCols fontData surf x y (colsForChar fontData c);
    drawText = drawTextWith fontData;
    textWidth = s: builtins.stringLength s * fontData.advance;
  };

  gallant = mkFace gallantData; # 12x22 hero face
  spleen5x8 = mkFace spleen5x8Data; # 5x8 dense detail face
  spleen8x16 = mkFace spleen8x16Data; # 8x16 mid face

  # Backward-compatible bare helpers: the original module drew Gallant.
  inherit (gallant) drawChar drawText textWidth glyphW;
  gW = gallant.width; # 12
  gH = gallant.height; # 22

  # A hollow gauge (x,y,w,h) with the leftmost `frac` of the interior filled. Mirrors
  # oled.zig drawHbar EXACTLY: border, then `round(inner*frac)` filled interior columns,
  # inner = w-2, rounding = floor(inner*frac + 0.5).
  drawBar =
    surf: x: y: w: h: frac:
    if w < 2 || h < 2 then
      surf
    else
      let
        f = if frac < 0.0 then 0.0 else if frac > 1.0 then 1.0 else frac;
        inner = w - 2;
        # floor(inner*f + 0.5): Nix truncates float->int toward zero for >=0.
        fill = builtins.floor (inner * f + 0.5);
        # Border entries + filled interior columns x+1 .. x+fill (rows y+1 .. y+h-2),
        # all concatenated onto the surface in one pass.
        borderE =
          builtins.concatMap (i: vrunEntries (x + i) y 1) (range 0 w) # top row
          ++ builtins.concatMap (i: vrunEntries (x + i) (y + h - 1) 1) (range 0 w) # bottom row
          ++ vrunEntries x y h # left col
          ++ vrunEntries (x + w - 1) y h; # right col
        fillE = builtins.concatMap (i: vrunEntries (x + 1 + i) (y + 1) (h - 2)) (range 0 fill);
      in
      surf ++ borderE ++ fillE;

  # ---------------------------------------------------------------- packing ---
  # Surface (entry LIST) -> the flat nInts bitmap renderOled decodes. Overlapping
  # contributions at the SAME GDDRAM offset must OR (bits may collide); distinct offsets
  # in one int occupy disjoint LE lanes, so those combine by ADD (== OR). SORT by offset
  # (O(e log e)); since offsets are then monotonic, so are their int indices (off/4), so a
  # SINGLE LINEAR CURSOR walk accumulates the value of the current int and emits completed
  # ints (with 0-fill across any gap) -- NO attrset, NO `//`-in-a-loop, NO per-pixel scan.
  # The whole pack is O(e log e + nInts).
  pack =
    surf:
    let
      sorted = builtins.sort (a: b: a.off < b.off) surf;
      laneMul = off: let l = off - (off / 4) * 4; in if l == 0 then 1 else if l == 1 then 256 else if l == 2 then 65536 else 16777216;
      # Cursor fold over the offset-sorted entries. Invariant: `outRev` holds the ints
      # BEFORE `curI` (in reverse), `curI` is the int being accumulated, `curVal` its LE
      # value so far, `curOff`/`curByte` the OR-run for the current offset. When the
      # offset advances we flush the finished byte into `curVal`; when the int advances we
      # push `curVal` (and any skipped ints as 0) onto `outRev`.
      # Emit the finished byte at `off` into the running int state (advancing/0-filling
      # ints as needed). Returns the updated { outRev; curI; curVal; }.
      place = st: off: byte:
        if byte == 0 then st
        else
          let
            ti = off / 4;
            lv = byte * (laneMul off);
          in
          if ti == st.curI then
            { outRev = st.outRev; curI = st.curI; curVal = st.curVal + lv; }
          else
            # Close curI (curVal), 0-fill ints (curI+1 .. ti-1), open ti with lv.
            let
              gap = builtins.genList (g: 0) (ti - st.curI - 1);
            in
            { outRev = gap ++ [ st.curVal ] ++ st.outRev; curI = ti; curVal = lv; };
      # First OR-collapse equal offsets, then place. Done in one fold carrying both the
      # offset OR-run and the int cursor.
      st = builtins.foldl' (
        acc: e:
        if acc.curOff == e.off then
          acc // { curByte = orI acc.curByte e.byte; }
        else
          let placed = place acc.place acc.curOff acc.curByte;
          in { curOff = e.off; curByte = e.byte; place = placed; }
      ) { curOff = -1; curByte = 0; place = { outRev = [ ]; curI = 0; curVal = 0; }; } sorted;
      # Flush the final offset run and the final int.
      finalPlaced = place st.place st.curOff st.curByte;
      # outRev is reverse-ordered ints for indices 0 .. finalPlaced.curI-1; append the
      # final int and reverse, then 0-fill the tail up to nInts.
      headInts = builtins.genList (
        j: builtins.elemAt (finalPlaced.outRev) (builtins.length finalPlaced.outRev - 1 - j)
      ) (builtins.length finalPlaced.outRev);
      builtInts = headInts ++ [ finalPlaced.curVal ];
      nBuilt = builtins.length builtInts;
    in
    builtins.genList (i: if i < nBuilt then builtins.elemAt builtInts i else 0) nInts;

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
