# The boot-info screen as a PURE-NIX per-frame pattern (fix applyValue) -- the
# initrd splash AND a rotation member. Renders the three things you want to see
# the moment the panel lights: the NixOS version, the kernel release, and the
# arch. fix is pure (no uname/readFile at eval), so the versions arrive as STRING
# scope inputs the gather side read once at startup (`scope.nixosVersion` from
# /etc/os-release or the cmdline init= store-path label, `scope.kernelVersion`
# from uname(2)); the arch is live `builtins.currentSystem`, which on this badge
# is the whole point of the core-swap party trick. Empty strings (a fallback that
# found nothing) render as "?". TWO hand-designed layouts, branched on the real
# panel height (draw.nix packs to scope.height, so the bitmap is 128 ints @32 /
# 256 @64):
#
#   32px (compact):                   64px (fuller):
#   NixOS 26.05      <- Spleen 8x16   NIXOS               <- Spleen caption (top)
#   6.18.44-xanmod1  <- Spleen 5x8    26.05               <- Gallant short-version hero
#   aarch64          <- Spleen 5x8    26.05.20260830.ab   <- Spleen full version
#                                     KERNEL 6.18.44-xan  <- Spleen kernel release
#                                     aarch64             <- Spleen arch (bottom)
#
#   scope: { t; width; height; nixosVersion; kernelVersion; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;
  sp16 = d.spleen8x16;

  orQ = s: if s == "" then "?" else s;
  ver = orQ (scope.nixosVersion or "");
  kern = orQ (scope.kernelVersion or "");

  # Arch = currentSystem up to the first "-" (the OS is always linux here).
  sys = builtins.currentSystem;
  firstIx =
    ch: s:
    let
      n = builtins.stringLength s;
      hit = builtins.filter (i: builtins.substring i 1 s == ch) (builtins.genList (i: i) n);
    in
    if hit == [ ] then n else builtins.head hit;
  arch = builtins.substring 0 (firstIx "-" sys) sys; # e.g. "aarch64"

  # Short version for the hero: up to the SECOND dot ("26.05.20260830.ab" ->
  # "26.05"; "26.05" and "?" pass through whole).
  verShort =
    let
      d1 = firstIx "." ver;
      rest = builtins.substring (d1 + 1) (builtins.stringLength ver) ver;
      d2 = d1 + 1 + firstIx "." rest;
    in
    builtins.substring 0 d2 ver;

  # The build tail after the "XX.YY." release prefix ("26.05.20260830.ab" ->
  # "20260830.ab"). The full version is too wide for the 400px detail row and
  # its leading XX.YY duplicates the hero, so the detail row shows only this.
  # Empty when ver has no tail (ver == verShort, e.g. a bare "26.05").
  verTail = builtins.substring (builtins.stringLength verShort + 1) (builtins.stringLength ver) ver;

  # Centre a string of a given face horizontally; clamp to the left edge on overflow.
  centreX = face: s: let x = (width - face.textWidth s) / 2; in if x < 0 then 0 else x;

  # ---- 32-row layout: 16px title + two 8px detail rows ----------------------
  layout32 =
    let
      title = "NixOS ${verShort}";
      s0 = sp16.drawText d.empty (centreX sp16 title) 0 title;
      s1 = sp.drawText s0 (centreX sp kern) 16 kern;
      s2 = sp.drawText s1 (centreX sp arch) 24 arch;
    in
    d.pack s2;

  # ---- 64-row layout: caption, version hero, full version, kernel, arch -----
  layout64 =
    let
      topCap = "NIXOS";
      s0 = sp.drawText d.empty (centreX sp topCap) 0 topCap;
      # Short version big in Gallant, centred, in the upper-middle band.
      s1 = d.drawText s0 (centreX d.gallant verShort) 10 verShort;
      # Dense detail rows: build tail (XX.YY stripped), kernel release, arch.
      # Skip the tail row when there is none (a bare "26.05" fallback).
      s2 = if verTail != "" then sp.drawText s1 (centreX sp verTail) 36 verTail else s1;
      s3 = sp.drawText s2 (centreX sp kern) 46 kern;
      s4 = sp.drawText s3 (centreX sp arch) 56 arch;
    in
    d.pack s4;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 5000; # static readout; nothing animates
}
