# A bouncing box: proof that a pure-Nix animation -- described as a function of
# frame index -- bakes to a BADA blob the runtime plays. 128x32, 20fps. Evaluate
# with `fix eval --raw ./demo.nix` (or stock nix) and pipe through `xxd -r -p`.
let
  oled = import ./oled.nix;
in
let
  width = 128;
  height = 32;
  fps = 20;
  box = 14;
  # p(t) reflecting in [0, max]: rises 0->max then falls, period 2*max.
  bounce = max: t: let m = oled.mod t (2 * max); in if m < max then m else 2 * max - m;
  frame =
    t:
    let
      bx = bounce (width - box) t;
      by = bounce (height - box) t; # smaller range -> bounces faster vertically
    in
    (col: row: col >= bx && col < bx + box && row >= by && row < by + box);
in
oled.badaHex {
  inherit width height fps;
  # One full horizontal reflect period, so the loop is seamless.
  frames = builtins.genList frame (2 * (width - box));
}
