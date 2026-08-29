# The load info screen as a PURE-NIX per-frame pattern (fix applyValue). Pairs the
# two open faces from draw.nix: the 1-minute load average BIG in Sun Gallant (hero),
# a Spleen 5x8 "LOAD" label, and CPU%/MEM% gauges each tagged with a Spleen label +
# its percent. TWO hand-designed layouts, branched on the real panel height (draw.nix
# packs to scope.height, so the bitmap is 128 ints @32 / 256 @64):
#
#   32px (compact, unchanged):          64px (fuller):
#   0.42   CPU 12 [==cpu==]             0.42                <- Gallant load1 (hero)
#   LOAD   MEM 40 [==mem==]             1 MINUTE LOAD AVG   <- Spleen caption
#                                       CPU  12% [====cpu====]  <- full-width gauge
#                                       MEM  40% [====mem====]  <- full-width gauge
#
#   scope: { t; width; height; batteryMv; batteryPct; onUsb; load1; cpuPct; memPct; uptimeS }
#   -> { bitmap = [ width*height/8/4 ints ]; nextMs; }
scope:
let
  d = (import ./draw.nix) { inherit (scope) width height; };
  inherit (d) width height;
  sp = d.spleen5x8;

  # load1 is a float; render "X.XX" (truncated hundredths). floor truncates >=0.
  load1x100 = builtins.floor (scope.load1 * 100.0);
  ldWhole = load1x100 / 100;
  ldHund = d.mod load1x100 100;
  ldStr = "${toString ldWhole}.${d.pad2 ldHund}";

  cpu = if scope.cpuPct > 100 then 100 else scope.cpuPct;
  mem = if scope.memPct > 100 then 100 else scope.memPct;
  cpuFrac = cpu * 1.0 / 100.0;
  memFrac = mem * 1.0 / 100.0;

  # ---- 32-row layout (the shipping compact design, unchanged) ---------------
  layout32 =
    let
      # Hero load average, big Gallant, near the top (22px cell in the top ~22px).
      s0 = d.drawText d.empty 0 0 ldStr;
      # Spleen "LOAD" label tucked under the hero on the bottom row.
      s1 = sp.drawText s0 0 (height - sp.height) "LOAD";
      # Right block: two Spleen-tagged gauges.
      heroRight = d.textWidth ldStr; # Gallant hero pixel width
      tagX = if heroRight + 6 < 60 then 60 else heroRight + 6;
      cpuLabel = "CPU ${toString cpu}";
      memLabel = "MEM ${toString mem}";
      labelW = sp.textWidth "CPU 100"; # reserve for up to 3 digits
      barX = tagX + labelW + 3;
      barW = width - barX;
      # CPU on the top band (y 2..11), MEM on the bottom band (y 18..27).
      s2 = sp.drawText s1 tagX 3 cpuLabel;
      s3 = if barW >= 8 then d.drawBar s2 barX 2 barW 9 cpuFrac else s2;
      s4 = sp.drawText s3 tagX 19 memLabel;
      s5 = if barW >= 8 then d.drawBar s4 barX 18 barW 9 memFrac else s4;
    in
    d.pack s5;

  # ---- 64-row layout (fresh; uses the full panel) --------------------------
  # Hero load1 up top with a caption, then two full-width labelled CPU/MEM gauges
  # stacked below, each a Spleen tag + percent and a bar running to the right edge.
  layout64 =
    let
      # Hero load1, big Gallant, top-left.
      s0 = d.drawText d.empty 0 0 ldStr;
      # Caption to the right of the hero, vertically middled against it.
      capY = (d.gallant.height - sp.height) / 2;
      s1 = sp.drawText s0 (d.textWidth ldStr + 6) capY "1 MINUTE";
      s1b = sp.drawText s1 (d.textWidth ldStr + 6) (capY + sp.height + 1) "LOAD AVG";

      # Two full-width gauges below the hero. Each row: a "CPU nnn%" tag then a bar
      # filling to the right edge. Sized to fill the band from below the hero to the
      # bottom edge so the taller panel is used, not left half-blank.
      tag = t: v: "${t} ${d.padLeft 3 (toString v)}%";
      tagW = sp.textWidth "MEM 100%"; # 8 chars
      barX = tagW + 4;
      barW = width - barX;
      bandTop = d.gallant.height + 3; # first fillable row below the hero (~25)
      bandH = height - bandTop; # rows available for the two gauges (~39)
      gap = 4;
      barH = (bandH - gap) / 2; # split the band into two bars + one gap (~17 each)
      row0Y = bandTop;
      row1Y = bandTop + barH + gap;
      # Vertically centre each Spleen tag against its bar.
      tagOff = (barH - sp.height) / 2;

      c0 = sp.drawText s1b 0 (row0Y + tagOff) (tag "CPU" cpu);
      c1 = d.drawBar c0 barX row0Y barW barH cpuFrac;
      m0 = sp.drawText c1 0 (row1Y + tagOff) (tag "MEM" mem);
      m1 = d.drawBar m0 barX row1Y barW barH memFrac;
    in
    d.pack m1;
in
{
  bitmap = if height >= 64 then layout64 else layout32;
  nextMs = 500; # slow meter, matches the Zig load return
}
