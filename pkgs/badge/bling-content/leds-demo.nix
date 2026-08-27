# A rotating rainbow across the 24-LED ring: proof that an LED pattern authored
# as `f(t) -> [rgb]` bakes to a BLED blob the ring plays. `fix eval --raw
# ./leds-demo.nix | xxd -r -p`.
let
  leds = import ./leds.nix;
  b = import ./oled.nix;
in
let
  nleds = 24;
  fps = 30;
  nframes = 64; # 64 frames * (t*4) = 256 = one full hue rotation -> seamless loop
  frame = t: builtins.genList (i: leds.wheel (b.mod (i * 256 / nleds + t * 4) 256)) nleds;
in
leds.bledHex {
  inherit nleds fps;
  frames = builtins.genList frame nframes;
}
