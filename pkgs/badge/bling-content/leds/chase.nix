# CHASE / comet -- a bright head sweeping the ring with a geometric fading tail.
# Replaces the Zig `chase` pattern. Contract: see leds-live.nix.
scope:
let
  mod = a: b: a - (a / b) * b;

  head = mod (scope.t / 40) scope.width; # one lap ~= width * 40 ms

  # Distance BEHIND the head, ring-wrapped; the tail fades over 6 LEDs.
  tail = i:
    let
      d = mod (head - i + scope.width) scope.width;
    in
    if d == 0 then 255
    else if d < 6 then 255 / (d * 2)
    else 0;

  # Warm comet: full red, half green -> orange head, ember tail.
  color = v: v * 65536 + (v / 2) * 256;
in
{
  bitmap = builtins.genList (i: color (tail i)) scope.width;
  nextMs = 33;
}
