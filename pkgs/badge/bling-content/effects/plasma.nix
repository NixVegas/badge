# Plasma -- the demoscene classic: a sum of a few sine fields sampled with an
# animated phase, thresholded to 1 bit with an ordered (Bayer 4x4) dither so the
# soft blobs read as stippled gradients on the mono OLED.
#
#   v(x,y,p) = sinX[x*sx + t1(p)]        (horizontal waves)
#            + sinY[y*sy + t2(p)]        (vertical waves)
#            + diag[(x+y) + t3(p)]       (diagonal waves)
#            + rad [dist(x,y) + t4(p)]   (concentric ripples from centre)
#   lit  <=>  ((v + 4*128) & 255) > bayer[x&3][y&3] scaled
#
# All sine/distance/geometry tables are HOISTED (rule 1) -- and, taken to its
# limit, so is every FRAME: the field depends on t ONLY through a master phase
# p = (t/33) mod 32, i.e. 32 distinct frames, ever. The four per-field phase
# offsets become p-derived (t1..t4 = p*8, p*13, p*5, p*21 -- mutually
# coprime-ish multipliers so the fields still drift apart and the 32-frame
# loop churns visibly), and ALL 32 frames are precomputed in the outer let
# (32 x 256 ints). The table is forced LAZILY: the first loop through the
# phases pays the old per-frame cost once per new phase (a progressive
# warmup), after which a frame render is just an elemAt + a 256-int copy
# (~5 ms) instead of 8k per-pixel 4-sine sums (~1-2 s on the badge core).
#
# ---- fixed point -----------------------------------------------------------
# No floats: SIN is a 256-entry integer table, one full turn, amplitude +-60.
# Indices are taken mod 256 by bitAnd 255 (pure int op). Distances are integer
# (a hoisted per-pixel table), so a "ripple" is just SIN[dist + phase].
let
  p2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (i: i) n);
  pow = builtins.genList (r: p2 r) 8;
  bit = r: builtins.elemAt pow r;

  width = 128;
  height = 64;
  pages = height / 8;
  intsPerPage = width / 4; # 32
  nInts = pages * intsPerPage; # 256

  # --- 256-entry integer sine table, amplitude +-60, one full period. ---------
  # sin(2*pi*i/256) approximated by a piecewise integer polynomial so we need NO
  # float builtin. We use the classic parabolic sine: for a phase p in [0,256),
  #   half = p < 128 ? p : p-128  (sign flips on the second half)
  #   q = half - 64                     (-64..63, 0 at the peak)
  #   parab = 64*64 - q*q               (0..4096, a parabola peaking at centre)
  # scale parab (0..4096) to 0..60 and apply the sign. Smooth enough for plasma.
  sinRaw = i:
    let
      p = builtins.bitAnd i 255;
      neg = p >= 128;
      half = if neg then p - 128 else p;
      q = half - 64;
      parab = 64 * 64 - q * q; # 0 .. 4096
      mag = (parab * 60) / 4096; # 0 .. 60
    in
    if neg then 0 - mag else mag;
  SIN = builtins.genList sinRaw 256;
  sinAt = i: builtins.elemAt SIN (builtins.bitAnd i 255);

  # --- per-pixel geometry, all t-free (hoisted) -------------------------------
  # For every (col,row) we precompute the spatial arguments so the per-frame path
  # is a pure table read + phase add. We store, per pixel:
  #   hx = col*3   (horizontal wave arg, before adding phase)
  #   vy = row*5   (vertical)
  #   dg = col+row (diagonal)
  #   rd = integer radius from panel centre (concentric ripples)
  cx = 64;
  cy = 32;
  # Integer sqrt (Newton), for the radial distance table.
  isqrt = n:
    if n <= 0 then 0
    else
      let
        step = g: (g + n / g) / 2;
        g0 = 1 + n / 2;
        g1 = step g0; g2 = step g1; g3 = step g2;
        g4 = step g3; g5 = step g4; g6 = step g5;
      in
      let g = g6; in if g * g > n then g - 1 else g;

  # Flattened per-pixel arg tables, indexed x*height + y is wasteful; instead we
  # index by column and row separately where the arg is separable, and only the
  # radius needs a full 2-D table. hArg depends only on col, vArg only on row.
  hArg = builtins.genList (col: col * 3) width; # 128 entries
  vArg = builtins.genList (row: row * 5) height; # 64 entries
  # Radius per (col,row): a width*height table (8192 entries) built ONCE.
  radTab = builtins.genList (col:
    builtins.genList (row:
      let dx = col - cx; dy = row - cy; in isqrt (dx * dx + dy * dy)
    ) height
  ) width;
  radAt = col: row: builtins.elemAt (builtins.elemAt radTab col) row;

  # --- Bayer 4x4 ordered dither, threshold levels 0..15 scaled to the sum range.
  # sum of 4 sines ranges roughly -240..240; we bias +240 -> 0..480 and compare
  # against a per-pixel Bayer threshold in the same range.
  bayer = [
    [  0  8  2 10 ]
    [ 12  4 14  6 ]
    [  3 11  1  9 ]
    [ 15  7 13  5 ]
  ];
  # Scale a 0..15 Bayer cell to the 0..480 sum range (step 30).
  bayerAt = col: row:
    let bx = builtins.bitAnd col 3; by = builtins.bitAnd row 3; in
    (builtins.elemAt (builtins.elemAt bayer by) bx) * 30;

  # Per-int geometry (page + start column), t-free.
  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  # --- the 32-frame phase table -----------------------------------------------
  # Column byte for absolute column x on `page` (rows page*8 .. +7), given the
  # four phase offsets of one master phase. This is the old per-frame kernel,
  # verbatim, with t1..t4 passed in instead of derived from scope.t.
  colByte = t1: t2: t3: t4: x: page:
    let
      base = page * 8;
      ha = builtins.elemAt hArg x; # horizontal arg (col only)
    in
    builtins.foldl' (acc: r:
      let
        y = base + r;
        va = builtins.elemAt vArg y;
        v = sinAt (ha + t1)
          + sinAt (va + t2)
          + sinAt (x + y + t3)
          + sinAt (radAt x y + t4);
        lvl = v + 240; # 0..480
      in
      if lvl > bayerAt x y then acc + bit r else acc
    ) 0 (builtins.genList (i: i) 8);

  # ALL 32 frames, precomputed (see the hoisting note above). Each entry is the
  # full 256-int packed frame for one master phase p. The four field phases run
  # at different p-multiples (coprime-ish: 8/13/5/21, taken mod 256 by sinAt's
  # masking) so the fields drift apart across the loop -- the classic churning
  # look, now periodic in 32 frames.
  frames = builtins.genList (p:
    let
      t1 = p * 8;  # horizontal
      t2 = p * 13; # vertical
      t3 = p * 5;  # diagonal
      t4 = p * 21; # radial
      cb = colByte t1 t2 t3 t4;
    in
    builtins.genList (i:
      let
        cp = builtins.elemAt colPage i;
        c0 = cp.col0;
        pg = cp.page;
        b0 = cb c0 pg;
        b1 = cb (c0 + 1) pg;
        b2 = cb (c0 + 2) pg;
        b3 = cb (c0 + 3) pg;
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
  # WARMUP, honestly on the badge: each table frame costs the full per-pixel
  # compute ONCE when first forced. scope.frameIndex resets on screen entry, so
  # the first 32 renders step the table in order -- one fresh frame per render,
  # shown as it lands, with a "WARM n/32" counter overlaid. Re-entry replays the
  # counter over already-forced frames (~a second). After warmup: phase follows
  # t (one step per ~30 fps tick), no overlay, ~5 ms/frame.
  warm = scope.frameIndex < 32;
  phase = if warm then scope.frameIndex else builtins.bitAnd (scope.t / 33) 31;
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
