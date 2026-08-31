# SPARKLE -- deterministic pseudo-random twinkles: each LED hashes (index, time
# bucket) and lights briefly when the hash clears a threshold, so the ring
# glitters without any RNG builtin. Contract: see leds-live.nix.
scope:
let
  mod = a: b: a - (a / b) * b;

  # Integer hash (xorshift-ish via mul/mod; Nix ints are 64-bit so no overflow
  # worries at these magnitudes).
  hash = x: mod (x * 2654435761) 65536;

  bucket = scope.t / 100; # twinkle lifetime 100 ms

  led = i:
    let
      h = hash (i * 7919 + bucket * 104729);
    in
    # ~1 LED in 6 lit per bucket; brightness from the hash's low bits so
    # concurrent sparkles differ.
    if mod h 6 == 0 then
      let v = 128 + mod h 128; in v * 65536 + v * 256 + v # white-ish
    else
      0;
in
{
  bitmap = builtins.genList led scope.width;
  nextMs = 50;
}
