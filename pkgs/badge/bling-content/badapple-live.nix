# Bad Apple!! as a PURE-NIX DELTA PATTERN FILE the badge's embedded fix evaluator
# applies once per frame (compile-once + native applyValue, the same path proven
# for LEDs -- see pkgs/badge/nix-badge/fixeval.zig decodeOled). Unlike the baked
# "BADA" blob (pkgs/badge/badapple, which the runtime mmaps), this emits a Nix
# FUNCTION that carries every frame's ints in ONE FLAT list, sliced per frame:
#
#   let data   = [ <all frames' ints concatenated> ];   # keyframe + delta ints
#       starts = [ <fc+1 offsets into data, trailing sentinel> ];
#       ns     = [ <fc delta-entry counts; 0 for keyframes> ];
#       nframes = N; keyint = K; mod = a: b: a - (a / b) * b;
#   in scope:
#      let i = mod scope.frameIndex nframes;
#          start = builtins.elemAt starts i;
#          len = (builtins.elemAt starts (i + 1)) - start;
#          b = builtins.genList (j: builtins.elemAt data (start + j)) len;   # YOUNG slice
#      in { bitmap = b; delta = (mod i keyint) != 0; n = builtins.elemAt ns i; nextMs = <1000/fps>; }
#
# FLAT so the fix Engine stays small: the old per-frame `frames = [ { k; n; b } ... ]`
# forced fix to materialise + PIN ~13140 attrset + list objects (~400 MB) as the clip
# played, which under the major-only GC made every allocating screen pay an O(heap)
# collection. Flat pins just a few lists (~10 MB) and each frame's `b` is a young,
# collectable slice, so the live heap stays flat.
#
# A KEYFRAME is the full frame packed like the old flat format: fbLen/4 ints, 4
# consecutive page-major GDDRAM bytes per int LITTLE-ENDIAN (int = b0 | b1<<8 |
# b2<<16 | b3<<24). A DELTA carries only the (offset,byte) changes vs the exactly
# reconstructed previous frame: 2 entries per int, E = offset*256+byte, packed
# int = E0*262144 + E1 (E0 = high 18 bits). Frame f is a keyframe iff f % K == 0
# (K = keyframeInterval), so frame 0 is always a keyframe. The exact byte/int
# contract -- and the runtime decode side -- live in badapple-delta.md.
#
# The frames come from the EXISTING Bad Apple pipeline: import ../badapple to get
# the ffmpeg-baked "BADA" blob (deterministic: pinned video, gray8 -> threshold
# -> page-major pack), then a tiny C program (emit_delta.c) reads the fbLen-byte
# frames past the 16-byte header and emits the delta Nix text.
#
# durationSeconds defaults SMALL (20 s ~= 400 frames) so the test build + the
# on-badge parse stay fast; set it to null for the whole song (~4379 frames).
{
  pkgs,

  # Panel geometry -- must match the runtime OLED (nix-badge oled default) and
  # the badapple blob's own header. 128x32 -> 512 bytes/frame -> 128 ints/frame.
  width ? 128,
  height ? 32,

  # Playback rate. ~20 fps balances motion and Nix-source size; baked into the
  # emitted `fps` so the pattern's frame index tracks scope.t.
  fps ? 20,

  # Cap on the clip length in seconds. SMALL by default so the generated .nix is
  # a few hundred KiB (fast host test + fast on-badge parse). null = full song
  # (~219 s, ~4379 frames, ~6 MB) -- valid but heavy.
  durationSeconds ? 20,

  # Keyframe interval K: frame f is a full keyframe iff f % K == 0 (so frame 0
  # always is). 60 -> a self-healing keyframe once per second at 60 fps. K=1
  # degenerates to an all-keyframe (flat full-frame) stream. See badapple-delta.md.
  keyframeInterval ? 60,

  # The badapple blob builder (ffmpeg + pack.c). Passed the geometry/fps/duration
  # so its frames are exactly what we re-encode as Nix ints.
  badapple ? import ../badapple {
    inherit pkgs width height fps durationSeconds;
  },

  name ? "badapple-live",
}:

let
  lib = pkgs.lib;
  fbLen = width * height / 8; # page-major bytes per frame (512 for 128x32)
  wordsPerFrame = fbLen / 4; # ints per frame (128 for 128x32)
in

assert lib.assertMsg (height / 8 * 8 == height) "badapple-live: height must be a multiple of 8";
assert lib.assertMsg (fbLen / 4 * 4 == fbLen) "badapple-live: frame byte count ${toString fbLen} must be a multiple of 4";

pkgs.stdenv.mkDerivation {
  pname = name;
  version = "1.0";

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.gcc ];

  buildPhase = ''
    runHook preBuild

    gcc -O2 -Wall -Wextra -std=c11 -o emit_delta ${./emit_delta.c}

    # Feed the baked BADA blob through the delta emitter -> the pure-Nix pattern.
    ./emit_delta ${toString keyframeInterval} < ${badapple}/badapple.bin > badapple-live.nix

    runHook postBuild
  '';

  # Self-test: the emitted Nix is now FLAT (see emit_delta.c) -- one `data` list of
  # every frame's ints concatenated, indexed by `starts` (fc+1 offsets, trailing
  # sentinel) and `ns` (fc delta-entry counts). The OLD per-frame attrset list
  # pinned ~13140 objects in the fix Engine (~400 MB, so any allocating screen then
  # paid an O(heap) major); flat pins only a few lists (~10 MB). Validate the shape:
  # nframes matches the header, and starts/ns have the right element counts. The
  # SEMANTIC check (frame 0 evals to a valid keyframe + HUD) lives in etc.nix.
  # The header's frame_count is the u32 at blob offset 12 (LE).
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    blob=${badapple}/badapple.bin
    fc=$(od -An -tu4 -j12 -N4 "$blob" | tr -d ' ')
    echo "badapple-live: blob declares $fc frames"

    grep -q "^  nframes = $fc;" badapple-live.nix || {
      echo "SELF-TEST FAIL: nframes != $fc header frames" >&2; exit 1; }

    # `starts` has fc+1 entries (trailing sentinel); `ns` has fc. Each list is one
    # line, so count its integer tokens. (`data` is skipped -- ~0.5M ints.)
    n_starts=$(grep '^  starts = ' badapple-live.nix | grep -oE '[0-9]+' | wc -l)
    [ "$n_starts" -eq "$(( fc + 1 ))" ] || {
      echo "SELF-TEST FAIL: starts has $n_starts entries != fc+1 = $(( fc + 1 ))" >&2; exit 1; }

    n_ns=$(grep '^  ns = ' badapple-live.nix | grep -oE '[0-9]+' | wc -l)
    [ "$n_ns" -eq "$fc" ] || {
      echo "SELF-TEST FAIL: ns has $n_ns entries != $fc" >&2; exit 1; }

    # Keyframes fall at indices 0, K, 2K, ... -> ceil(fc/K).
    K=${toString keyframeInterval}
    keys=$(( ( fc + K - 1 ) / K ))
    grep -q "^  keyint = $K;" badapple-live.nix || {
      echo "SELF-TEST FAIL: keyint != $K" >&2; exit 1; }

    echo "SELF-TEST PASS: $fc frames flat (starts=$n_starts, ns=$n_ns, $keys keyframes @ K=$K)"

    echo "$fc" > .fc
    echo "$keys" > .keys

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 badapple-live.nix "$out/badapple-live.nix"

    fc=$(cat .fc)
    keys=$(cat .keys)
    size=$(stat -c%s "$out/badapple-live.nix")
    {
      echo "badapple-live.nix -- pure-Nix Bad Apple DELTA pattern (fix applyValue per frame)"
      echo "format:       delta codec v1 (see badapple-delta.md)"
      echo "geometry:     ${toString width}x${toString height} (${toString fbLen} bytes/frame)"
      echo "keyframe:     ${toString wordsPerFrame} ints (4 page-bytes/int, LE)"
      echo "delta:        variable ints/frame (2 change entries/int, E = offset*256+byte)"
      echo "keyframe_K:   ${toString keyframeInterval} (frame f is a keyframe iff f % K == 0)"
      echo "keyframes:    $keys"
      echo "fps:          ${toString fps}"
      echo "frame_count:  $fc"
      echo "duration_cap: ${if durationSeconds == null then "none (full song)" else toString durationSeconds + " s"}"
      echo "nix_bytes:    $size"
    } > "$out/badapple-live.info"

    runHook postInstall
  '';

  meta = {
    description = "Bad Apple!! as a pure-Nix per-frame DELTA pattern for the badge OLED (fix applyValue)";
    longDescription = ''
      A single Nix function ($out/badapple-live.nix) the badge's embedded fix
      evaluator compiles once and applies every frame to a fresh scope. Each frame
      is either a keyframe (full SSD1306 page-major bytes, packed 4/int LE) or a
      delta carrying only the changed (offset,byte) pairs vs the previous frame
      (2 entries/int); decodeOled applies it and flushes just the dirty page spans.
      Keyframes recur every keyframeInterval frames. The frames are re-encoded from
      the deterministic ffmpeg-baked "BADA" blob; see badapple-delta.md for the
      exact byte/int contract.
    '';
    platforms = pkgs.lib.platforms.all; # build-host tool; output is arch-neutral Nix text
  };
}
