# A LIVE rotating-rainbow LED pattern, evaluated per frame by the embedded fix
# evaluator (see pkgs/badge/nix-badge/fixeval.zig). Unlike the baked BLED blobs
# (leds.nix), this is a pure function of the live scope -- the runtime applies it
# every frame with a fresh { t; width; ...; } and no recompile.
#
# Contract (the unified content shape):
#   scope: { bitmap = [ <0xRRGGBB int> ... ]; nextMs = <int>; }
# `bitmap` is a flat list of packed 24-bit colours, one per LED (width*height =
# width, since the ring is Nx1). `nextMs` is the frame-rate hint in ms.
scope:
let
  mod = a: b: a - (a / b) * b;

  # A 0..255 hue -> packed 0xRRGGBB int (the standard three-phase colour wheel).
  wheel =
    h:
    let
      p = mod h 256;
    in
    if p < 85 then
      (255 - p * 3) * 65536 + (p * 3) * 256 + 0
    else if p < 170 then
      let
        q = p - 85;
      in
      0 * 65536 + (255 - q * 3) * 256 + (q * 3)
    else
      let
        q = p - 170;
      in
      (q * 3) * 65536 + 0 * 256 + (255 - q * 3);
in
{
  # Spread one hue rotation around the ring, advanced by the live clock. t/8 keeps
  # the spin gentle; each LED is offset by its position for the rainbow sweep.
  bitmap = builtins.genList (
    i: wheel (mod (i * 256 / scope.width + scope.t / 8) 256)
  ) scope.width;
  # ~30 fps. The runtime paces on this, decoupled from the sensor-read rate.
  nextMs = 33;
}
