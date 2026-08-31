# SPARKLE -- deterministic pseudo-random twinkles: each LED hashes (index, time
# bucket) and lights briefly when the hash clears a threshold, so the ring
# glitters without any RNG builtin. Contract: see leds-live.nix.
scope:
let
  mod = a: b: a - (a / b) * b;

  # Integer hash, OVERFLOW-SAFE: reduce to 16 bits BEFORE the multiply (Knuth
  # 40503). The first cut multiplied the raw input by 2654435761 -- with `t` in
  # monotonic ms since boot, the product blew past i64 within the hour and fix
  # (correctly) raised IntegerOverflow, killing the eval pattern until reload.
  hash = x: mod (mod x 65536 * 40503) 65536;

  bucket = mod (scope.t / 100) 65536; # twinkle lifetime 100 ms, bounded

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
