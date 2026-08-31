# PULSE / breathe -- the whole ring inhales and exhales one hue on a triangle
# wave (integer-only; a sine adds nothing at LED resolution). Replaces the Zig
# `pulse` pattern. Contract: see leds-live.nix.
scope:
let
  mod = a: b: a - (a / b) * b;

  # Triangle 0..255..0 over a ~2.7 s period.
  ph = mod (scope.t / 6) 512;
  level = if ph < 256 then ph else 511 - ph;

  # Badge blue-cyan, scaled by the breathe level (integer scale x/255).
  r = 0 * level / 255;
  g = 96 * level / 255;
  b = 255 * level / 255;
  c = r * 65536 + g * 256 + b;
in
{
  bitmap = builtins.genList (i: c) scope.width;
  nextMs = 33;
}
