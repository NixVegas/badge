# The uptime clock info screen as a PURE-NIX per-frame pattern (fix applyValue) --
# the marquee use of the Sun face. Pairs the two open draw.nix faces: the uptime as
# HH:MM:SS (or "NdHH:MM" past a day) BIG and centred in Sun Gallant with the colon
# blinking at 1 Hz, a Spleen 5x8 caption (an "UP" tag + the raw uptime seconds), and
# a bottom bar for the seconds fraction of the minute. TWO hand-designed layouts,
# branched on the real panel height (draw.nix packs to scope.height, so the bitmap is
# 128 ints @32 / 256 @64):
#
#   32px (compact, unchanged):        64px (fuller):
#   12:34:56                          UPTIME              <- Spleen caption (top)
#   UP 90061s                         12:34:56            <- Gallant clock, centred
#   [===seconds bar===]               UP 90061s           <- Spleen raw seconds
#                                     [===seconds bar===]  <- tall seconds-of-minute bar
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  s = scope.uptimeS;
  days = let x = s / 86400; in if x > 999 then 999 else x;
  hh = d.mod (d.mod s 86400) 86400 / 3600;
  mm = d.mod (d.mod s 3600) 3600 / 60;
  ss = d.mod s 60;

  # 1 Hz square wave off the monotonic clock: colon shown in the first half-second.
  sep = if d.mod scope.t 1000 < 500 then ":" else " ";

  bigStr =
    if days > 0 then
      "${toString days}d${d.pad2 hh}${sep}${d.pad2 mm}"
    else
      "${d.pad2 hh}${sep}${d.pad2 mm}${sep}${d.pad2 ss}";

  # Centre the Gallant readout horizontally.
  tx = let x = (width - d.textWidth bigStr) / 2; in if x < 0 then 0 else x;

  secsFrac = (d.mod s 60) * 1.0 / 60.0;
  cap = "UP ${toString s}s";
  cx = let x = (width - sp.textWidth cap) / 2; in if x < 0 then 0 else x;

  # ---- 32-row layout (the shipping compact design, unchanged) ---------------
  layout32 =
    let
      s0 = d.drawText d.empty tx 0 bigStr;
      # Gallant digit content ends above the 22px cell bottom, so a Spleen caption at
      # rows 22..29 sits clear of the hero: the raw uptime seconds, centred.
      capY = height - 2 - sp.height; # rows 22..29 (8px), leaving 2px for the bar
      s1 = sp.drawText s0 cx capY cap;
      # A thin 2px seconds-of-minute bar hugging the very bottom (rows 30..31).
      s2 = d.drawBar s1 0 (height - 2) width 2 secsFrac;
    in
    d.pack s2;

  # ---- 64-row layout (fresh; uses the full panel) --------------------------
  # A centred "UPTIME" caption, the big Gallant clock centred vertically in the middle
  # band, the raw-seconds caption below it, and a tall seconds-of-minute bar across
  # the bottom.
  layout64 =
    let
      # Top caption, centred.
      topCap = "UPTIME";
      tcX = let x = (width - sp.textWidth topCap) / 2; in if x < 0 then 0 else x;
      s0 = sp.drawText d.empty tcX 2 topCap;

      # Big Gallant clock, centred horizontally, in the vertical middle of the panel.
      clockY = (height - d.gallant.height) / 2;
      s1 = d.drawText s0 tx clockY bigStr;

      # Raw-seconds caption centred just below the clock.
      capY = clockY + d.gallant.height + 2;
      s2 = sp.drawText s1 cx capY cap;

      # Tall seconds-of-minute bar across the bottom.
      barH = 8;
      s3 = d.drawBar s2 0 (height - barH) width barH secsFrac;
    in
    d.pack s3;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 250; # four blink samples a second so the colon visibly ticks
}
