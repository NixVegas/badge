# The power info screen as a PURE-NIX per-frame pattern (fix applyValue). The HERO
# is the VSEL system rail (`scope.vselMv`, the TPS2116 output -- ~5 V on USB), which
# is what "rail voltage" means on this board; the 3x-lithium-AA pack rides below as
# a Spleen detail row + level bar. (An earlier cut rendered the BATTERY labeled
# "RAIL" because the scope didn't carry VSEL yet -- a ~4-5.5 V readout under a RAIL
# caption read as "my 5 V rail is wrong".) TWO hand-designed layouts, branched on
# the real panel height (draw.nix packs to scope.height, so the bitmap is 128 ints
# @32 / 256 @64):
#
#   32px (compact):                   64px (fuller):
#   5.01V   RAIL                      5.01V             <- Gallant VSEL rail (hero)
#           BAT 87%                   RAIL      VBUS    <- Spleen: caption + source
#   [======pack bar=====]             BAT 5.43V  87%    <- Spleen pack detail
#                                     [=====pack bar====]
#                                     3.00 V ...... 5.40 V  <- pack scale labels
#
#   scope: { t; width; height; vselMv; batteryMv; batteryPct; onUsb; ... }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  railMv = scope.vselMv or 0;
  railStr = if railMv > 0 then "${d.fixed2 railMv}V" else "--";

  batMv = scope.batteryMv;
  batStr = "${d.fixed2 batMv}V";

  # Pack level scaled 3.00..5.40 V (3x lithium AA window), clamped 0..1.
  frac =
    let
      x = (batMv - 3000) * 1.0 / 2400.0;
    in
    if x < 0.0 then 0.0 else if x > 1.0 then 1.0 else x;
  pct = builtins.floor (frac * 100.0 + 0.5);
  src = if scope.onUsb then "VBUS" else "BAT";

  # ---- 32-row layout: rail hero + pack detail beside it + pack bar ----------
  layout32 =
    let
      # Big Gallant rail volts, hero, top-left (rows 0..21 of the 32px panel).
      s0 = d.drawText d.empty 0 0 railStr;
      detailX = d.textWidth railStr + 6;
      s1 = sp.drawText s0 detailX 2 "RAIL";
      s2a = sp.drawText s1 detailX 12 "BAT ${toString pct}%";
      # Pack-level bar across the very bottom (6px).
      s2 = d.drawBar s2a 0 (height - 6) width 6 frac;
    in
    d.pack s2;

  # ---- 64-row layout: rail hero, source row, pack detail, bar + scale -------
  layout64 =
    let
      # Hero rail volts, big Gallant, top-left.
      s0 = d.drawText d.empty 0 0 railStr;
      # "RAIL" caption to the right of the hero, vertically middled against it.
      capY = (d.gallant.height - sp.height) / 2;
      s1 = sp.drawText s0 (d.textWidth railStr + 6) capY "RAIL";
      s1b = sp.drawText s1 (width - sp.textWidth src) capY src;

      # Pack detail row just below the hero: pack volts + percent.
      detY = d.gallant.height + 2; # ~24
      s2 = sp.drawText s1b 0 detY "BAT ${batStr}  ${d.padLeft 3 (toString pct)}%";

      # Pack-level bar filling the band between the detail row and the scale row.
      scaleY = height - sp.height; # bottom Spleen row
      barY = detY + sp.height + 3; # below the detail row
      barH = scaleY - barY - 2; # up to just above the scale labels
      s3 = d.drawBar s2 0 barY width barH frac;

      # Pack scale labels along the very bottom: left "3.00 V", right "5.40 V".
      loStr = "3.00 V";
      hiStr = "5.40 V";
      s4 = sp.drawText s3 0 scaleY loStr;
      s5 = sp.drawText s4 (width - sp.textWidth hiStr) scaleY hiStr;
    in
    d.pack s5;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 750; # rails move slowly; matches the old Zig power cadence
}
