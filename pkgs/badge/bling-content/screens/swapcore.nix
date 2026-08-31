# The CORE SWAP hold indicator -- a contract-v2 TRANSIENT screen: `hidden` keeps
# it out of the long-press cycle (the bootswap daemon jumps here via the RT
# screen-control API when the BOOT hold starts), and `autoReturnMs` bounces back
# to whatever was showing once the moment passes. Shows the RUNNING arch and what
# the strap will boot NEXT, which is exactly the question mid-hold.
#
#   scope: { t; width; height; strap; ... } -> { bitmap; nextMs; hidden; autoReturnMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  sys = builtins.currentSystem;
  firstDash =
    s:
    let
      n = builtins.stringLength s;
      hit = builtins.filter (i: builtins.substring i 1 s == "-") (builtins.genList (i: i) n);
    in
    if hit == [ ] then n else builtins.head hit;
  arch = builtins.substring 0 (firstDash sys) sys;

  strapName =
    if (scope.strap or 0) == 1 then "ARM"
    else if (scope.strap or 0) == 2 then "RISCV"
    else "?";

  centreX = face: s: let x = (width - face.textWidth s) / 2; in if x < 0 then 0 else x;

  # Blink the hold prompt at ~2 Hz so the screen reads as "in progress".
  mod = a: b: a - (a / b) * b;
  blink = mod (scope.t / 250) 2 == 0;

  hero = "CORE SWAP";
  nowStr = "NOW ${arch}";
  nextStr = "NEXT ${strapName}";
  holdStr = "HOLD TO SWAP";

  # 64px: Gallant hero + a NOW/NEXT row + the blinking prompt. 32px: all-Spleen
  # compact (the hero cell alone is ~22px, no room for rows beneath it).
  layout64 =
    let
      s0 = d.drawText d.empty (centreX d.gallant hero) 0 hero;
      rowY = d.gallant.height + 4;
      s1 = sp.drawText s0 4 rowY nowStr;
      s2 = sp.drawText s1 (width - sp.textWidth nextStr - 4) rowY nextStr;
      s3 = if blink then sp.drawText s2 (centreX sp holdStr) (height - sp.height - 1) holdStr else s2;
    in
    d.pack s3;
  layout32 =
    let
      s0 = sp.drawText d.empty (centreX sp hero) 1 hero;
      s1 = sp.drawText s0 4 12 nowStr;
      s2 = sp.drawText s1 (width - sp.textWidth nextStr - 4) 12 nextStr;
      s3 = if blink then sp.drawText s2 (centreX sp holdStr) (height - sp.height - 1) holdStr else s2;
    in
    d.pack s3;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 100; # brisk: the blink + a live strap readout during the hold
  hidden = true;
  autoReturnMs = 5000;
}
