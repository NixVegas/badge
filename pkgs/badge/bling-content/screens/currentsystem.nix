# The builtins.currentSystem info screen as a PURE-NIX per-frame pattern (fix
# applyValue) -- an on-theme readout: the badge's ARM<->RISC-V core swap is literally
# which `builtins.currentSystem` the embedded fix reports, so this shows exactly that.
# On the ARM core the embedded evaluator reports "aarch64-linux"; on a riscv eval
# build it reads "riscv64-linux"; on the dev host `nix eval` renders whatever that
# host is (e.g. "x86_64-linux"). Packed byte-for-byte to the bitmap decodes.
#
# Shows the ARCH (before the first "-", the meaningful part -- the OS is always
# linux here, so the full triple was redundant) BIG in Sun Gallant as the hero, plus
# the one thing the triple can't tell you: what the boot-select STRAP currently
# reads (`scope.strap`: which core the NEXT boot picks). Running arch vs strap
# differ exactly when a core swap is pending. TWO hand-designed layouts, branched on
# the real panel height (draw.nix packs to scope.height, so the bitmap is 128 ints
# @32 / 256 @64):
#
#   32px (compact):                   64px (fuller):
#   aarch64                           SYSTEM              <- Spleen caption (top)
#   STRAP ARM                         aarch64             <- Gallant arch hero, centred
#                                     STRAP ARM           <- Spleen strap readout (bottom)
#
#   scope: { t; width; height; strap; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  sys = builtins.currentSystem;

  # Index of the first "-" in `s`, or the length when absent. builtins has no
  # indexOf, so scan char positions and take the first that matches.
  firstDash =
    s:
    let
      n = builtins.stringLength s;
      hit = builtins.filter (i: builtins.substring i 1 s == "-") (builtins.genList (i: i) n);
    in
    if hit == [ ] then n else builtins.head hit;

  dash = firstDash sys;
  arch = builtins.substring 0 dash sys; # e.g. "aarch64"

  # What the boot-select strap currently reads (which core the NEXT boot picks):
  # 0 unknown / 1 arm / 2 riscv, from the core-sel-strap gpio via scope.strap.
  strapCode = scope.strap or 0;
  strapName =
    if strapCode == 1 then
      "ARM"
    else if strapCode == 2 then
      "RISCV"
    else
      "?";
  strapStr = "STRAP ${strapName}";

  # Centre a string of a given face horizontally; clamp to the left edge on overflow.
  centreX = face: s: let x = (width - face.textWidth s) / 2; in if x < 0 then 0 else x;

  # ---- 32-row layout: arch hero + strap row ---------------------------------
  layout32 =
    let
      # Arch big on the top as the Gallant hero (rows 0..21), centred.
      s0 = d.drawText d.empty (centreX d.gallant arch) 0 arch;
      # Strap readout in Spleen 5x8, centred on the bottom row (rows 24..31).
      s1 = sp.drawText s0 (centreX sp strapStr) (height - sp.height) strapStr;
    in
    d.pack s1;

  # ---- 64-row layout: caption, arch hero, strap row -------------------------
  layout64 =
    let
      # Top caption, centred.
      topCap = "SYSTEM";
      s0 = sp.drawText d.empty (centreX sp topCap) 2 topCap;

      # Arch hero, big Gallant, centred horizontally, in the middle band.
      heroY = 18;
      s1 = d.drawText s0 (centreX d.gallant arch) heroY arch;

      # Strap readout on the very bottom.
      s2 = sp.drawText s1 (centreX sp strapStr) (height - sp.height - 2) strapStr;
    in
    d.pack s2;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 1000; # 1 Hz: the strap changes under swap-core, so keep the readout live-ish
}
