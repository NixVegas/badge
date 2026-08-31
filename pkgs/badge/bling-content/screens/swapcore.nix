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

  # The swap TARGET is the OPPOSITE of what the strap currently reads: holding
  # the button latches the strap to the OTHER core. (An earlier cut showed the
  # current strap as "NEXT", which is only different from "NOW" while a prior
  # swap is still pending -- exactly the wrong moment to be wrong.)
  strapCode = scope.strap or 0;
  targetName =
    if strapCode == 1 then "RISCV"
    else if strapCode == 2 then "ARM"
    else "?";

  centreX = face: s: let x = (width - face.textWidth s) / 2; in if x < 0 then 0 else x;

  # Blink the hold prompt at ~2 Hz so the screen reads as "in progress".
  mod = a: b: a - (a / b) * b;
  blink = mod (scope.t / 250) 2 == 0;

  hero = "CORE SWAP";
  nowStr = "NOW ${arch}";
  nextStr = "NEXT ${targetName}";
  holdStr = "HOLD TO SWAP";

  # NOW/NEXT are STACKED rows: side by side they measure ~126px of 128 ("NOW
  # aarch64" + "NEXT RISCV") and collide.
  #
  #   64px:                            32px (no room for a hero cell):
  #   CORE SWAP     <- Gallant hero    CORE SWAP   HOLD  <- title + blink
  #   NOW aarch64                      NOW aarch64
  #   NEXT RISCV                       NEXT RISCV
  #   HOLD TO SWAP  <- blinking
  layout64 =
    let
      s0 = d.drawText d.empty (centreX d.gallant hero) 0 hero;
      rowY = d.gallant.height + 4;
      s1 = sp.drawText s0 4 rowY nowStr;
      s2 = sp.drawText s1 4 (rowY + sp.height + 2) nextStr;
      s3 = if blink then sp.drawText s2 (centreX sp holdStr) (height - sp.height - 1) holdStr else s2;
    in
    d.pack s3;
  layout32 =
    let
      s0 = sp.drawText d.empty 1 1 hero;
      s1 = if blink then sp.drawText s0 (width - sp.textWidth "HOLD" - 1) 1 "HOLD" else s0;
      s2 = sp.drawText s1 4 12 nowStr;
      s3 = sp.drawText s2 4 22 nextStr;
    in
    d.pack s3;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 100; # brisk: the blink + a live strap readout during the hold
  hidden = true;
  autoReturnMs = 5000;
}
