# SOLID with a slow global hue drift -- the whole ring is one colour, walking the
# wheel over ~34 s. Replaces the Zig `solid` pattern with something a touch more
# alive; a pure function of the live scope (see leds-live.nix for the contract).
#
#   scope: { bitmap = [ <0xRRGGBB int> ... ]; nextMs = <int>; }
scope:
let
  mod = a: b: a - (a / b) * b;

  # 0..255 hue -> packed 0xRRGGBB (three-phase colour wheel; == leds-live.nix).
  wheel =
    h:
    let
      p = mod h 256;
    in
    if p < 85 then
      (255 - p * 3) * 65536 + (p * 3) * 256
    else if p < 170 then
      let q = p - 85; in (255 - q * 3) * 256 + (q * 3)
    else
      let q = p - 170; in (q * 3) * 65536 + (255 - q * 3);

  c = wheel (mod (scope.t / 133) 256); # one full wheel in ~34 s
in
{
  bitmap = builtins.genList (i: c) scope.width;
  nextMs = 66; # a slow drift needs no 30 fps
}
