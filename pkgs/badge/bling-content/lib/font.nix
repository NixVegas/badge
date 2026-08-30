# <nixbadge/lib/font.nix>: render short text into OVERLAY entries for the nix-badge overlay
# contract (eval.zig applyOverlay), so a delta screen (Bad Apple) can stamp a status line --
# e.g. "[nix] 60fps" -- over any frame from Nix. Text lands on PAGE 0 (the top 8 rows) as a
# clean box: each column is overwritten with the glyph's 8 vertical pixels (or 0), replacing
# whatever the main frame had there.
#
# Glyphs come from the shared Spleen 5x8 table (BSD-2-Clause; see LICENSE.spleen), which is
# row-major (8 rows, bit 4 = leftmost of 5 cols). The overlay wants COLUMN bytes (8 vertical
# pixels), so each glyph is transposed. An overlay entry is E = offset*256 + byte where
# offset = page*width + col = col on page 0; entries pack 2/int (int = E0*262144 + E1, E0
# high), exactly like a delta. renderText returns { overlay = [ints]; overlayN = count; }.
#
# Pure builtins only (no nixpkgs lib) so both evaluators run it standalone.
let
  data = import <nixbadge/lib/spleen-5x8-font-data.nix>; # { width=5; height=8; glyphs; }

  # Codepoints for the full printable-ASCII range (the Spleen table carries all of
  # them), built from a string laid out in codepoint order: char i is codepoint
  # 32+i. A hand-picked HUD-only subset lived here once and silently blanked every
  # other character (an effect's "WARM 3/32" overlay rendered as just the digits).
  # Anything outside the range still falls back to space, never an eval error.
  ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
  cp = builtins.listToAttrs (
    builtins.genList (i: {
      name = builtins.substring i 1 ascii;
      value = 32 + i;
    }) (builtins.stringLength ascii)
  );

  glyphRows = c: data.glyphs.${toString (cp.${c} or 32)} or data.glyphs."32";
  chars = s: builtins.genList (i: builtins.substring i 1 s) (builtins.stringLength s);

  pow2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (x: x) n);
  # Bit b (0 = LSB) of v.
  bit = v: b: let d = v / (pow2 b); in d - (d / 2) * 2;
  # Column c (0..4) of an 8-row glyph as a vertical byte: row r -> output bit r, reading the
  # (4-c)th bit of each row (bit 4 = leftmost column in the row-major table).
  colByte = rows: c: builtins.foldl' (acc: r: acc + (bit (builtins.elemAt rows r) (4 - c)) * (pow2 r)) 0 (builtins.genList (x: x) 8);

  # Precompute each glyph's 5 vertical column bytes ONCE (lazy per codepoint, memoized).
  # renderText then does a lookup instead of the pow2 bit-transpose every frame -- this is
  # what keeps the per-frame HUD cheap. Only correct/cheap when the caller HOISTS
  # `import <nixbadge/lib/font.nix>` out of the per-frame lambda so this attrset is stable
  # across frames (otherwise it is rebuilt every frame; see emit_delta.c / badapple-live).
  glyphColsByCp = builtins.mapAttrs (_: rows: builtins.genList (c: colByte rows c) 5) data.glyphs;
  colsOf = ch: glyphColsByCp.${toString (cp.${ch} or 32)} or glyphColsByCp."32";

  advance = 6; # 5px cell + 1px gap
in
{
  # renderText { text; x?; page?; width?; } -> { overlay = [packed ints]; overlayN = count; }
  # Draws `text` on `page` (0 = top 8 rows; height/8-1 = bottom) starting at column `x`,
  # clipped to `width`. The GDDRAM byte offset is page*width + column. The gap column after
  # each glyph is emitted as byte 0 so the box is clean.
  renderText =
    { text, x ? 0, page ? 0, width ? 128 }:
    let
      # For each character, its advance columns (5 glyph cols + 1 gap) as { col; byte; }.
      # `cols` is the precomputed 5 column bytes (a lookup, not a per-frame transpose).
      cells = builtins.concatMap (
        i:
        let
          ch = builtins.elemAt (chars text) i;
          cols = colsOf ch;
          base = x + i * advance;
        in
        builtins.genList (c: {
          col = base + c;
          byte = if c < 5 then builtins.elemAt cols c else 0; # col 5 = inter-char gap
        }) advance
      ) (builtins.genList (i: i) (builtins.stringLength text));

      # Clip on COLUMN (0..width), then place on `page`: offset = page*width + col.
      es = map (e: { off = page * width + e.col; inherit (e) byte; })
        (builtins.filter (e: e.col >= 0 && e.col < width) cells);
      n = builtins.length es;
      E = e: e.off * 256 + e.byte;
      npairs = (n + 1) / 2;
      packed = builtins.genList (
        p:
        let
          e0 = builtins.elemAt es (2 * p);
          e1i = 2 * p + 1;
        in
        (E e0) * 262144 + (if e1i < n then E (builtins.elemAt es e1i) else 0)
      ) npairs;
    in
    {
      overlay = packed;
      overlayN = n;
    };
}
