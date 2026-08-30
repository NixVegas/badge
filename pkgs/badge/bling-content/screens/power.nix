# The power info screen as a PURE-NIX per-frame pattern (fix applyValue). The Zig
# `screens.power` re-reads rails/faults from sysfs (VSEL volts, VBUS, fault lines) --
# none in the pure-Nix per-frame scope -- so this shows the rail the scope DOES
# carry: the battery millivolts as one big Gallant readout (hero), with a Spleen 5x8
# detail (pack % of the 3x-lithium-AA window + VBUS/BAT source) and a level bar. TWO
# hand-designed layouts, branched on the real panel height (draw.nix packs to
# scope.height, so the bitmap is 128 ints @32 / 256 @64):
#
#   32px (compact, unchanged):        64px (fuller):
#   4.10V   RAIL                      4.10V             <- Gallant rail volts (hero)
#           91%                       RAIL 91%  VBUS    <- Spleen: fill % + source
#   [=======bar========]              [======bar=======]  <- tall rail-level bar
#                                     3.00 V ...... 5.40 V  <- Spleen scale labels
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  mv = scope.batteryMv;
  vStr = "${d.fixed2 mv}V";

  # Pack level scaled 3.00..5.40 V (3x lithium AA window), clamped 0..1.
  frac =
    let
      x = (mv - 3000) * 1.0 / 2400.0;
    in
    if x < 0.0 then 0.0 else if x > 1.0 then 1.0 else x;
  pct = builtins.floor (frac * 100.0 + 0.5);
  src = if scope.onUsb then "VBUS" else "BAT";

  # ---- 32-row layout (the shipping compact design, unchanged) ---------------
  layout32 =
    let
      # Big Gallant volts, hero, top-left (rows 0..21 of the 32px panel).
      s0 = d.drawText d.empty 0 0 vStr;
      # Spleen 5x8 detail column to the RIGHT of the hero: a "RAIL" caption over the
      # fill % + source, two 8px rows stacked in the vertical space beside the hero.
      detailX = d.textWidth vStr + 6;
      s1 = sp.drawText s0 detailX 2 "RAIL";
      s2a = sp.drawText s1 detailX 12 "${toString pct}%  ${src}";
      # Rail-level bar across the very bottom (6px).
      s2 = d.drawBar s2a 0 (height - 6) width 6 frac;
    in
    d.pack s2;

  # ---- 64-row layout (fresh; uses the full panel) --------------------------
  # Hero volts up top, a Spleen detail row beneath it (rail % + source), a tall
  # pack-level bar across the middle, and a Spleen scale row (3.00 V .. 5.40 V)
  # labelling the bar ends along the bottom.
  layout64 =
    let
      # Hero volts, big Gallant, top-left.
      s0 = d.drawText d.empty 0 0 vStr;
      # "RAIL" caption to the right of the hero, vertically middled against it.
      capY = (d.gallant.height - sp.height) / 2;
      s1 = sp.drawText s0 (d.textWidth vStr + 6) capY "RAIL";

      # Spleen detail row just below the hero: fill % + source.
      detY = d.gallant.height + 2; # ~24
      s2 = sp.drawText s1 0 detY "RAIL ${d.padLeft 3 (toString pct)}%   SRC ${src}";

      # Tall rail-level bar filling the band between the detail row and the scale row.
      scaleY = height - sp.height; # bottom Spleen row
      barY = detY + sp.height + 3; # below the detail row
      barH = scaleY - barY - 2; # up to just above the scale labels
      s3 = d.drawBar s2 0 barY width barH frac;

      # Scale labels along the very bottom: left "3.00 V", right "5.40 V".
      loStr = "3.00 V";
      hiStr = "5.40 V";
      s4 = sp.drawText s3 0 scaleY loStr;
      s5 = sp.drawText s4 (width - sp.textWidth hiStr) scaleY hiStr;
    in
    d.pack s5;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 750; # rails move slowly; matches the Zig power return
}
