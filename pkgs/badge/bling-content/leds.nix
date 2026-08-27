# Pure-Nix builder for a "BLED" blob: a looping RGB-frame animation for the
# WS2812 ring. A pattern is exactly the user's framing -- `t: [ {r;g;b;} ... ]`,
# a function of the frame index returning a list of LED colours -- which we
# precompute over one loop and pack. The runtime's `leds run` blob mode mmaps
# this and plays frame = now_ms*fps/1000 % count, applying brightness.
#
# Reuses the generic byte helpers from oled.nix. Layout (little-endian):
#   magic "BLED", u16 nleds, u16 fps, u32 frame_count,
#   then frame_count frames of nleds*3 bytes (R,G,B per LED, in ring order).
let
  b = import ./oled.nix; # range/concatMap/u16/u32/mod/hex
in
rec {
  clamp8 = x: if x < 0 then 0 else if x > 255 then 255 else x;

  # A 0..255 hue position -> {r;g;b;} around the standard WS2812 colour wheel.
  wheel =
    pos:
    let
      p = b.mod pos 256;
    in
    if p < 85 then
      { r = 255 - p * 3; g = p * 3; b = 0; }
    else if p < 170 then
      let q = p - 85; in { r = 0; g = 255 - q * 3; b = q * 3; }
    else
      let q = p - 170; in { r = q * 3; g = 0; b = 255 - q * 3; };

  # Whole blob as a byte list. `frames` is a list of (list of {r;g;b;}), each
  # of length nleds.
  bledBytes =
    {
      nleds,
      fps,
      frames,
    }:
    let
      count = builtins.length frames;
      frameBytes = leds: b.concatMap (c: [ (clamp8 c.r) (clamp8 c.g) (clamp8 c.b) ]) leds;
    in
    [ 66 76 69 68 ] # "BLED"
    ++ b.u16 nleds
    ++ b.u16 fps
    ++ b.u32 count
    ++ b.concatMap frameBytes frames;

  bledHex = spec: b.hex (bledBytes spec);
}
