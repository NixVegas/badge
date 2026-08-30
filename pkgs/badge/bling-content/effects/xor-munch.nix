# XOR / "munching squares" -- the canonical demoscene one-liner, pure Nix.
#
#   pixel(x,y) lit  <=>  ((x ^ y) + t) & band  in  [lo, hi)
#
# This is the classic `x XOR y` interference pattern, animated by adding a
# time term and slicing a moving band out of it -- concentric diamond ripples
# that "munch" across the panel. Everything scope-independent is hoisted; per
# frame we only pick a phase from t and pack 256 ints.
#
# ---- GDDRAM packing (128x64 mono, page-major) ------------------------------
# The framebuffer is 8 pages of 128 columns. byte(page,col) = page*128+col, and
# bit r of that byte is pixel (col, page*8 + r). The runtime `bitmap` is that
# 1024-byte buffer folded 4 LE bytes/int -> 256 ints. Because 128 % 4 == 0, int
# i lives entirely in ONE page: page = i / 32, and it covers 4 columns
# c0 = (i % 32)*4 .. c0+3, each contributing an 8-bit vertical slice.
#
# ---- hoisting (rule 1) -----------------------------------------------------
# `colPage`  : for each of the 256 ints, its {page; col0} -- pure geometry, no t.
# Per frame we still must XOR with y, so the field itself is t-dependent and
# cannot be fully tabled; but the arithmetic per pixel is a handful of int ops
# (xor, add, band, compare) with NO allocation of tables, so nix stays cheap:
# 256 ints * 32 bits, each a few integer ops.
let
  # 2^n by doubling (Nix has bitAnd/bitOr/bitXor but no shift/pow builtin).
  p2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (i: i) n);
  pow = [ (p2 0) (p2 1) (p2 2) (p2 3) (p2 4) (p2 5) (p2 6) (p2 7) ];
  bit = r: builtins.elemAt pow r; # 2^r for r in 0..7

  width = 128;
  height = 64;
  pages = height / 8; # 8
  intsPerPage = width / 4; # 32
  nInts = pages * intsPerPage; # 256

  # Per-int geometry: which page + which starting column (hoisted, t-free).
  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  # The moving band we slice out of the (x^y) field. band = 32 -> the value is
  # taken mod 32 by masking low 5 bits; lit when that residue is < 16 gives a
  # 50% duty diamond ripple. Using masks (bitAnd) keeps it a pure int op.
  mask5 = 31; # value & 31  == value mod 32
in
scope:
let
  # One phase per frame. t is ms; /24 -> a brisk march of the diamonds. The XOR
  # field is symmetric so we don't need a big range; masking wraps it.
  phase = scope.t / 24;

  # Column byte at absolute column x for this frame: 8 vertical pixels (rows
  # page*8+0 .. +7) each lit iff ((x ^ y) + phase) & 31 < 16.
  colByte = x: page:
    let base = page * 8; in
    builtins.foldl' (acc: r:
      let
        y = base + r;
        v = builtins.bitAnd (builtins.bitXor x y + phase) mask5;
      in
      if v < 16 then acc + bit r else acc
    ) 0 (builtins.genList (i: i) 8);

  frame = builtins.genList (i:
    let
      cp = builtins.elemAt colPage i;
      c0 = cp.col0;
      pg = cp.page;
      b0 = colByte c0 pg;
      b1 = colByte (c0 + 1) pg;
      b2 = colByte (c0 + 2) pg;
      b3 = colByte (c0 + 3) pg;
    in
    b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
  ) nInts;
in
{
  bitmap = frame;
  nextMs = 33; # ~30 fps
}
