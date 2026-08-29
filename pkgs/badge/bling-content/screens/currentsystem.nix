# The builtins.currentSystem info screen as a PURE-NIX per-frame pattern (fix
# applyValue) -- an on-theme readout: the badge's ARM<->RISC-V core swap is literally
# which `builtins.currentSystem` the embedded fix reports, so this shows exactly that.
# On the ARM core the embedded evaluator reports "aarch64-linux"; on a riscv eval
# build it reads "riscv64-linux"; on the dev host `nix eval` renders whatever that
# host is (e.g. "x86_64-linux"). Packed byte-for-byte to the bitmap decodes.
#
# Pairs the two open draw.nix faces: the ARCH (before the first "-", the meaningful
# part -- "aarch64") goes BIG in Sun Gallant as the hero, and the FULL system string
# ("aarch64-linux") + OS row go in dense Spleen 5x8. TWO hand-designed layouts,
# branched on the real panel height (draw.nix packs to scope.height, so the bitmap is
# 128 ints @32 / 256 @64):
#
#   32px (compact, unchanged):        64px (fuller):
#   aarch64                           SYSTEM              <- Spleen caption (top)
#   aarch64-linux                     aarch64             <- Gallant arch hero, centred
#                                     aarch64-linux       <- Spleen full triple
#                                     OS LINUX            <- Spleen OS row, comfortably below
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
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
  # The OS part after the first "-" (e.g. "linux"); empty if there is no dash.
  os = builtins.substring (dash + 1) (builtins.stringLength sys) sys;
  # Uppercase the OS for the label row. builtins has no toupper, so map a-z -> A-Z.
  upperMap = {
    a = "A"; b = "B"; c = "C"; d = "D"; e = "E"; f = "F"; g = "G"; h = "H"; i = "I";
    j = "J"; k = "K"; l = "L"; m = "M"; n = "N"; o = "O"; p = "P"; q = "Q"; r = "R";
    s = "S"; t = "T"; u = "U"; v = "V"; w = "W"; x = "X"; y = "Y"; z = "Z";
  };
  upper =
    str:
    builtins.concatStringsSep "" (
      map (c: if upperMap ? ${c} then upperMap.${c} else c) (
        builtins.genList (i: builtins.substring i 1 str) (builtins.stringLength str)
      )
    );
  osUpper = upper os;

  # Centre a string of a given face horizontally; clamp to the left edge on overflow.
  centreX = face: s: let x = (width - face.textWidth s) / 2; in if x < 0 then 0 else x;

  # ---- 32-row layout (the shipping compact design, unchanged) ---------------
  layout32 =
    let
      # Arch big on the top as the Gallant hero (rows 0..21), centred.
      s0 = d.drawText d.empty (centreX d.gallant arch) 0 arch;
      # Full system triple in Spleen 5x8, centred on the bottom row (rows 24..31).
      s1 = sp.drawText s0 (centreX sp sys) (height - sp.height) sys;
    in
    d.pack s1;

  # ---- 64-row layout (fresh; uses the full panel) --------------------------
  # A "SYSTEM" caption up top, the arch hero centred in the middle band, the full
  # triple centred beneath it, and an OS label row comfortably below the arch.
  layout64 =
    let
      # Top caption, centred.
      topCap = "SYSTEM";
      s0 = sp.drawText d.empty (centreX sp topCap) 2 topCap;

      # Arch hero, big Gallant, centred horizontally, in the upper-middle band.
      heroY = 14;
      s1 = d.drawText s0 (centreX d.gallant arch) heroY arch;

      # Full triple in Spleen 5x8, centred just below the hero.
      triY = heroY + d.gallant.height + 3;
      s2 = sp.drawText s1 (centreX sp sys) triY sys;

      # OS label row on the very bottom, comfortably below the triple.
      osStr = "OS ${osUpper}";
      s3 = sp.drawText s2 (centreX sp osStr) (height - sp.height) osStr;
    in
    d.pack s3;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 1000; # static readout; 1 Hz is plenty (system only changes on a core swap + reboot)
}
