# Plasma -- the demoscene classic: a sum of a few sine fields sampled with an
# animated phase, thresholded to 1 bit with an ordered (Bayer 4x4) dither so the
# soft blobs read as stippled gradients on the mono OLED.
#
#   v(x,y,t) = sinX[x*sx + t1]           (horizontal waves)
#            + sinY[y*sy + t2]           (vertical waves)
#            + diag[(x+y) + t3]          (diagonal waves)
#            + rad [dist(x,y) + t4]      (concentric ripples from centre)
#   lit  <=>  ((v + 4*128) & 255) > bayer[x&3][y&3] scaled
#
# All sine/distance/geometry tables are HOISTED (rule 1); per frame we only read
# four phase offsets from t and, for each of the 256 packed ints, sum 4 table
# lookups per pixel + one dither compare. No per-frame table is built.
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
in
scope:
let
  # Four independent phase offsets from wall time -> the fields drift apart and
  # the plasma churns. Different divisors = different speeds (classic look).
  t = scope.t;
  ph1 = t / 20;
  ph2 = t / 27;
  ph3 = t / 35;
  ph4 = t / 15;

  # Column byte for absolute column x on `page` (rows page*8 .. +7).
  colByte = x: page:
    let
      base = page * 8;
      ha = builtins.elemAt hArg x; # horizontal arg (col only)
    in
    builtins.foldl' (acc: r:
      let
        y = base + r;
        va = builtins.elemAt vArg y;
        v = sinAt (ha + ph1)
          + sinAt (va + ph2)
          + sinAt (x + y + ph3)
          + sinAt (radAt x y + ph4);
        lvl = v + 240; # 0..480
      in
      if lvl > bayerAt x y then acc + bit r else acc
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
