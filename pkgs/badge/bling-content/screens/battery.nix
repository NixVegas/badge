# The battery info screen as a PURE-NIX per-frame pattern (fix applyValue). Pairs
# the two open faces from draw.nix: the charge percent BIG in Sun Gallant (hero),
# millivolts + power source (USB/battery) on Spleen 5x8 detail rows, and a level gauge
# pinned to the right edge. TWO hand-designed layouts, branched on the real panel
# height (draw.nix packs to scope.height, so the bitmap is 128 ints @32 / 256 @64):
#
#   32px (compact, unchanged):        64px (fuller):
#   87%          [#]                  87%              [##]   <- Gallant % + tall gauge
#   4.10V CHG    [#]                  (hero vertically centred in the left column)
#                                    4.100 V           [##]   <- Spleen: millivolts
#                                    CHARGING          [##]   <- Spleen: charge state
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  pct = if scope.batteryPct > 100 then 100 else scope.batteryPct;
  frac = pct * 1.0 / 100.0;

  # ---- 32-row layout (the shipping compact design, unchanged) ---------------
  layout32 =
    let
      # Vertical charge gauge on the right edge: a 10px-wide battery outline, filled
      # from the bottom by `frac`. Leaves the whole left 116px for the text.
      gaugeW = 10;
      gaugeX = width - gaugeW;
      g0 = d.fillRect d.empty (gaugeX + 3) 0 (gaugeW - 6) 2; # terminal nub
      g1 = d.rect g0 gaugeX 2 gaugeW (height - 2);
      fillH = builtins.floor ((height - 6) * frac + 0.5);
      gauge =
        if fillH <= 0 then g1
        else d.fillRect g1 (gaugeX + 2) (height - 2 - fillH) (gaugeW - 4) fillH;
      s0 = d.drawText gauge 0 0 "${toString pct}%";
      mvStr = "${d.fixed2 scope.batteryMv}V";
      state = if scope.onUsb then "USB" else "BAT";
      detail = "${mvStr}  ${state}";
      s1 = sp.drawText s0 0 (height - sp.height) detail;
    in
    d.pack s1;

  # ---- 64-row layout (fresh; uses the full panel) --------------------------
  layout64 =
    let
      # A wider battery gauge spanning the full height on the right edge.
      gaugeW = 14;
      gaugeX = width - gaugeW;
      nubH = 3;
      g0 = d.fillRect d.empty (gaugeX + 4) 0 (gaugeW - 8) nubH; # terminal nub
      g1 = d.rect g0 gaugeX nubH gaugeW (height - nubH); # hollow cell under the nub
      innerH = height - nubH - 4; # fillable interior (2px border top+bottom)
      fillH = builtins.floor (innerH * frac + 0.5);
      gauge =
        if fillH <= 0 then g1
        else d.fillRect g1 (gaugeX + 2) (height - 2 - fillH) (gaugeW - 4) fillH;

      # Two Spleen detail rows bottom-anchored in the left column; hero centred above.
      detailH = 2 * sp.height; # rows the detail block occupies at the bottom
      heroBandH = height - detailH; # rows above the detail block
      heroStr = "${toString pct}%";
      heroY = let y = (heroBandH - d.gallant.height) / 2; in if y < 0 then 0 else y;
      s0 = d.drawText gauge 0 heroY heroStr;

      mvStr = "${d.fixed2 scope.batteryMv} V";
      state = if scope.onUsb then "ON USB" else "ON BATTERY";
      row0 = sp.drawText s0 0 (height - 2 * sp.height) mvStr;
      s1 = sp.drawText row0 0 (height - sp.height) state;
    in
    d.pack s1;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 500; # a slow meter; 2 Hz is plenty (matches the Zig battery return)
}
