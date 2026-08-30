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
# ---- hoisting (rule 1, taken to its limit) ---------------------------------
# The field depends on t ONLY through `phase mod 32` -- 32 distinct frames,
# ever. So ALL 32 frames are precomputed in the outer let (32 x 256 ints, forced
# lazily one frame at a time as playback first reaches each phase) and a frame
# render is just an elemAt + a 256-int slice: Bad-Apple-keyframe cheap (~5 ms)
# instead of 8k per-pixel int ops per frame (~300 ms on the badge core).
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

  # Column byte at absolute column x for phase p: 8 vertical pixels (rows
  # page*8+0 .. +7) each lit iff ((x ^ y) + p) & 31 < 16.
  colByte = p: x: page:
    let base = page * 8; in
    builtins.foldl' (acc: r:
      let
        y = base + r;
        v = builtins.bitAnd (builtins.bitXor x y + p) mask5;
      in
      if v < 16 then acc + bit r else acc
    ) 0 (builtins.genList (i: i) 8);

  # ALL 32 frames, precomputed (see the hoisting note above). Each entry is the
  # full 256-int packed frame for one phase residue.
  frames = builtins.genList (p:
    builtins.genList (i:
      let
        cp = builtins.elemAt colPage i;
        c0 = cp.col0;
        pg = cp.page;
        b0 = colByte p c0 pg;
        b1 = colByte p (c0 + 1) pg;
        b2 = colByte p (c0 + 2) pg;
        b3 = colByte p (c0 + 3) pg;
      in
      b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    ) nInts
  ) 32;
  # The warmup loader's text renderer (resolved via the runtime's <nixbadge>
  # search path; hoisted so it costs nothing after warmup).
  font = import <nixbadge/lib/font.nix>;
in
scope:
let
  # WARMUP, honestly on the badge: the table frames are forced lazily, and each
  # costs the full per-pixel compute ONCE. scope.frameIndex resets to 0 on screen
  # entry and counts rendered frames, so the first 32 renders step the table IN
  # ORDER -- one fresh frame forced per render, shown as it lands, with a
  # "WARM n/32" counter overlaid. Re-entry replays the counter but the frames are
  # already forced, so it zips by in ~a second. After warmup: phase follows t,
  # no overlay, ~5 ms/frame.
  warm = scope.frameIndex < 32;
  phase = if warm then scope.frameIndex else builtins.bitAnd (scope.t / 24) mask5;
  f = builtins.elemAt frames phase;
  hud = font.renderText {
    text = "WARM ${toString (phase + 1)}/32";
    x = 0;
    page = 0;
    width = 128;
  };
in
{
  # A fresh (young, collectable) copy of the tabled frame, so the runtime's
  # bitmap force never pins per-frame garbage into the tabled constants.
  bitmap = builtins.genList (i: builtins.elemAt f i) nInts;
  nextMs = if warm then 1 else 33; # warm as fast as compute allows; then ~30 fps
  overlay = if warm then hud.overlay else [ ];
  overlayN = if warm then hud.overlayN else 0;
}
