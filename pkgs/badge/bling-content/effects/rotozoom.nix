# Rotozoomer -- the Second Reality staple: an infinite tiled texture spun and
# zoomed under the viewport. For each screen pixel (x,y) we rotate+scale into
# texture space and sample a hoisted 1-bit tile:
#
#   dx = x - CX ; dy = y - CY
#   u  = ( dx*cos + dy*sin ) * zoom >> SHIFT
#   v  = (-dx*sin + dy*cos ) * zoom >> SHIFT
#   lit = tex[(u + panX) & (TW-1)][(v + panY) & (TH-1)]
#
# The TEXTURE and the SINE table are hoisted constants (rule 1) -- and, taken
# to its limit, so is every FRAME: angle/zoom/pan depend on t ONLY through a
# master phase p = (t/66) mod 32, i.e. 32 distinct frames, ever. Per phase:
# angle index = p*8 (exactly one full 256-entry turn per 32-frame loop, so the
# rotation wraps seamlessly), zoom = the same breathing sine evaluated at
# index p*8 (one full 8..40 breath per loop), and pan drifts at a p-derived
# time pt = p*160 through the original divisors. ALL 32 frames are precomputed
# in the outer let (32 x 256 ints). The table is forced LAZILY: the first loop
# through the phases pays the old per-frame cost once per new phase (a
# progressive warmup), after which a frame render is just an elemAt + a
# 256-int copy (~5 ms) instead of 8k per-pixel rotate+sample ops (~700 ms on
# the badge core).
#
# ---- fixed point -----------------------------------------------------------
# cos/sin are scaled by 256 (COSS). u,v accumulate dx*cos etc (scale 256) times
# zoom (scale 16) => scale 4096; we shift right by 12 (divide by 4096) to get
# integer texture coords. All via integer * and /, masking with bitAnd for the
# power-of-two texture wrap.
let
  p2 = n: builtins.foldl' (a: _: a * 2) 1 (builtins.genList (i: i) n);
  pow = builtins.genList (r: p2 r) 8;
  bit = r: builtins.elemAt pow r;

  width = 128;
  height = 64;
  pages = height / 8;
  intsPerPage = width / 4;
  nInts = pages * intsPerPage;
  cx = 64;
  cy = 32;

  # --- integer sine/cosine, scale 256 (so cos=256 means 1.0). 256-entry turn. --
  # Parabolic sine (see plasma.nix), amplitude +-256.
  sinRaw = i:
    let
      p = builtins.bitAnd i 255;
      neg = p >= 128;
      half = if neg then p - 128 else p;
      q = half - 64;
      parab = 64 * 64 - q * q; # 0..4096
      mag = (parab * 256) / 4096; # 0..256
    in
    if neg then 0 - mag else mag;
  SIN = builtins.genList sinRaw 256;
  sinAt = i: builtins.elemAt SIN (builtins.bitAnd i 255);
  cosAt = i: sinAt (i + 64); # cos = sin(+90 deg) = sin(+64 of 256)

  # --- the texture: a 32x32 1-bit tile, hoisted. A woven XOR/plaid pattern that
  # tiles seamlessly and stays legible under rotation. tex is a 32-list of 32-bit
  # row masks (bit c = column c lit), so sampling is one bitAnd.
  tw = 32;
  th = 32;
  twMask = 31;
  thMask = 31;
  # Power-of-two table for 0..31 texture columns (bit() only covers 0..7).
  p2big = builtins.genList (r: p2 r) tw; # 2^0 .. 2^31
  # Row mask for texture row v: pixel (u,v) lit iff pattern(u,v) is odd. We use
  # ((u & 8) xor (v & 8)) for a checkerboard of 8x8 cells, XOR'd with a thin
  # ripple ((u ^ v) & 6 == 0) for woven detail -- a classic plaid.
  texRowFull = v:
    builtins.foldl' (acc: u:
      let
        checker = builtins.bitXor (builtins.bitAnd u 8) (builtins.bitAnd v 8) != 0;
        weave = builtins.bitAnd (builtins.bitXor u v) 6 == 0;
        litp = if checker then !weave else weave;
      in
      if litp then acc + builtins.elemAt p2big u else acc
    ) 0 (builtins.genList (i: i) tw);
  TEX = builtins.genList texRowFull th; # 32 row masks
  # sample: is texture pixel (u,v) lit? mask to the tile then test the bit.
  texAt = u: v:
    let
      uu = builtins.bitAnd u twMask;
      vv = builtins.bitAnd v thMask;
      rowmask = builtins.elemAt TEX vv;
    in
    builtins.bitAnd (rowmask / (builtins.elemAt p2big uu)) 1 == 1;

  # Per-int geometry (page + start column), t-free.
  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  # --- the 32-frame phase table -----------------------------------------------
  # Column byte at absolute column x on `page`, given the frame's five scalars.
  # This is the old per-frame kernel, verbatim, with co/si/zoom/pan passed in
  # instead of derived from scope.t.
  colByte = co: si: zoom: panX: panY: x: page:
    let
      base = page * 8;
      dx = x - cx;
    in
    builtins.foldl' (acc: r:
      let
        y = base + r;
        dy = y - cy;
        # (dx*co + dy*si) scale 256, * zoom scale 16 => scale 4096, >>12.
        u = ((dx * co + dy * si) * zoom) / 4096 + panX;
        v = ((dy * co - dx * si) * zoom) / 4096 + panY;
      in
      if texAt u v then acc + bit r else acc
    ) 0 (builtins.genList (i: i) 8);

  # ALL 32 frames, precomputed (see the hoisting note above). Per master phase p:
  #   angle index = p*8  -> one full turn (256 sine entries) per 32-frame loop
  #   zoom        = the same breathing formula evaluated at index p*8 (i.e. the
  #                 old t := p*480, /60) -> one full 8..40 breath per loop
  #   pan         = the original divisors at pt = p*160 -> the texture drifts
  #                 ~4 cols / ~3 rows per phase across the loop
  frames = builtins.genList (p:
    let
      ang = p * 8; # rotation angle index into the 256-turn
      co = cosAt ang; # scale 256
      si = sinAt ang;
      # zoom breathes 8..40 (scale 16 => 0.5x .. 2.5x), one breath per loop.
      zoom = 24 + (sinAt (p * 8) * 16) / 256; # 8..40
      pt = p * 160; # the p-derived "time" driving the pan drift
      panX = pt / 40;
      panY = pt / 55;
      cb = colByte co si zoom panX panY;
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
in
scope:
let
  # One master phase per frame. t is ms; /66 -> a phase step every other ~30 fps
  # tick, a full spin in ~2 s. Only the residue mod 32 matters; the whole frame
  # for it is already tabled.
  phase = builtins.bitAnd (scope.t / 66) 31;
  f = builtins.elemAt frames phase;
in
{
  # A fresh (young, collectable) copy of the tabled frame, so the runtime's
  # bitmap force never pins per-frame garbage into the tabled constants.
  bitmap = builtins.genList (i: builtins.elemAt f i) nInts;
  nextMs = 33; # ~30 fps
}
