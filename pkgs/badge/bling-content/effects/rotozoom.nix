# Rotozoomer -- the Second Reality staple: an infinite tiled texture spun and
# zoomed under the viewport. For each screen pixel (x,y) we rotate+scale into
# texture space and sample a hoisted 1-bit tile:
#
#   dx = x - CX ; dy = y - CY
#   u  = ( dx*cos + dy*sin ) * zoom >> SHIFT
#   v  = (-dx*sin + dy*cos ) * zoom >> SHIFT
#   lit = tex[(u + panX) & (TW-1)][(v + panY) & (TH-1)]
#
# cos/sin come from a hoisted integer sine table (fixed-point, scale 256); zoom
# breathes with t; the texture pans so it also drifts. The TEXTURE and the SINE
# table are hoisted constants (rule 1); per frame we read 3 scalars (cos, sin,
# zoom) + 2 pan offsets and sample per pixel with a handful of int ops.
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
in
scope:
let
  t = scope.t;
  ang = t / 24; # rotation angle index into the 256-turn
  co = cosAt ang; # scale 256
  si = sinAt ang;
  # zoom breathes 8..40 (scale 16 => 0.5x .. 2.5x). A slow sine on t.
  zoom = 24 + (sinAt (t / 60) * 16) / 256; # 8..40
  panX = t / 40;
  panY = t / 55;

  # Column byte at absolute column x on `page`.
  colByte = x: page:
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
