# Starfield / warp -- flying through space. A hoisted list of stars at fixed
# (sx, sy, z0) seeds; per frame each star's depth z sweeps toward the viewer
# (z decreasing with t, wrapping), and is perspective-projected to the screen:
#
#   z    = ((z0 - t*speed) mod ZRANGE) + ZNEAR      (depth, wraps -> respawn far)
#   col  = CX + sx * FOCAL / z
#   row  = CY + sy * FOCAL / z
#   near stars (small z) fly outward fast and are drawn as a 2px "warp streak".
#
# The star SEEDS (sx, sy, z0) are hoisted constants -- a deterministic pseudo
# scatter so no RNG is needed. Per frame we do ONE projection per star (a fixed
# count) and accumulate lit pixels into a per-column byte map, then read that map
# to pack the 256 ints. Sparse => cheap: a few hundred int ops per frame.
#
# ---- packing ---------------------------------------------------------------
# Same 128x64 page-major layout as the other effects. We build `colBytes`, a
# 128-entry list where colBytes[x] itself is an 8-entry list (one byte per page)
# of the lit-pixel bitmask for column x. Packing then reads colBytes[col0..+3].
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

  focal = 70; # projection focal length (smaller = wider FOV, more on-panel)
  znear = 6; # nearest depth before a star wraps
  zrange = 200; # depth span the field occupies
  nStars = 170; # star count (dense enough to read as a starfield, still cheap)

  # Deterministic pseudo-scatter: a linear-congruential-ish hash off the index
  # gives us (sx, sy, z0) seeds without any RNG builtin. sx,sy span the view
  # frustum; z0 is the star's phase into the depth sweep.
  hash = n: let h = (n * 2654435761 + 1013904223); in h - (h / 2147483647) * 2147483647;
  mod = a: b: a - (a / b) * b;
  seeds = builtins.genList (i:
    let
      h0 = hash (i + 1);
      h1 = hash (h0 + 7);
      h2 = hash (h1 + 13);
    in
    {
      # sx,sy in roughly -120..120 so projected spread fills the panel at mid depth.
      sx = mod h0 241 - 120;
      sy = mod h1 241 - 120;
      z0 = mod h2 zrange;
    }
  ) nStars;

  # Per-int geometry (page + start column), t-free.
  colPage = builtins.genList (i: {
    page = i / intsPerPage;
    col0 = (i - (i / intsPerPage) * intsPerPage) * 4;
  }) nInts;

  # A blank per-column byte map: 128 columns x 8 pages of 0.
  emptyRow = builtins.genList (_: 0) pages;
in
scope:
let
  # Depth sweep: everything marches toward the camera as t grows.
  speed = scope.t / 12;

  # Project all stars -> a list of {x; y; big} lit points (with clipping). `big`
  # marks a near star we thicken into a short warp streak.
  points = builtins.foldl' (acc: s:
    let
      z = mod (s.z0 + zrange - mod speed zrange) zrange + znear;
      x = cx + s.sx * focal / z;
      y = cy + s.sy * focal / z;
      big = z < znear + 26; # near stars streak
    in
    if x >= 0 && x < width && y >= 0 && y < height
    then acc ++ [ { inherit x y big; } ]
    else acc
  ) [ ] seeds;

  # Fold the points into a per-column byte map. `setPx m x y` ORs pixel (x,y) into
  # the column map `m`. A `big` (near) star gets a short vertical warp streak
  # (the pixel above + below) so fast foreground stars read as motion dashes.
  setPx = m: x: y:
    if x < 0 || x >= width || y < 0 || y >= height then m
    else
      let
        k = toString x;
        cur = if m ? ${k} then m.${k} else emptyRow;
        pg = y / 8;
        r = y - pg * 8;
        upd = builtins.genList (p: if p == pg then builtins.bitOr (builtins.elemAt cur p) (bit r) else builtins.elemAt cur p) pages;
      in
      m // { ${k} = upd; };

  litByCol = builtins.foldl' (m: pt:
    let
      m1 = setPx m pt.x pt.y;
    in
    if pt.big then setPx (setPx m1 pt.x (pt.y - 1)) pt.x (pt.y + 1) else m1
  ) { } points;

  colBytesAt = x: let k = toString x; in if litByCol ? ${k} then litByCol.${k} else emptyRow;

  frame = builtins.genList (i:
    let
      cp = builtins.elemAt colPage i;
      c0 = cp.col0;
      pg = cp.page;
      b0 = builtins.elemAt (colBytesAt c0) pg;
      b1 = builtins.elemAt (colBytesAt (c0 + 1)) pg;
      b2 = builtins.elemAt (colBytesAt (c0 + 2)) pg;
      b3 = builtins.elemAt (colBytesAt (c0 + 3)) pg;
    in
    b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
  ) nInts;
in
{
  bitmap = frame;
  nextMs = 33; # ~30 fps warp
}
