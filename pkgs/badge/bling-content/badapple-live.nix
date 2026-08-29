# Bad Apple!! as a PURE-NIX DELTA PATTERN FILE the badge's embedded fix evaluator
# applies once per frame (compile-once + native applyValue, the same path proven
# for LEDs -- see pkgs/badge/nix-badge/fixeval.zig decodeOled). Unlike the baked
# "BADA" blob (pkgs/badge/badapple, which the runtime mmaps), this emits a Nix
# FUNCTION whose per-frame `frames` list mixes KEYFRAMES and DELTAS:
#
#   scope:
#   let frames = [
#         { k = true;  b = [ <fbLen/4 ints> ]; }                  # keyframe
#         { k = false; n = <count>; b = [ <ceil(count/2) ints> ]; }  # delta
#         ... ]; nframes = N;
#       mod = a: b: a - (a / b) * b;
#   in let fr = builtins.elemAt frames (mod scope.frameIndex nframes);
#      in { bitmap = fr.b; delta = !fr.k; n = fr.n or 0; nextMs = <1000/fps>; }
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

  # Self-test: the emitted Nix must declare the frame count the blob's header
  # claims (one frame line per frame), and the keyframe lines must fall exactly
  # at indices 0, K, 2K, ... -> ceil(fc/K) of them. A mismatch (a dropped/short
  # frame, a geometry skew, a keyframe miscount) fails the build, not the badge.
  # The header's frame_count is the u32 at blob offset 12 (LE).
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    blob=${badapple}/badapple.bin
    fc=$(od -An -tu4 -j12 -N4 "$blob" | tr -d ' ')
    echo "badapple-live: blob declares $fc frames"

    # Count the emitted frame lines. Each frame -- keyframe or delta -- begins
    # with 4 spaces + '{ ' (keyframe: '{ k = true;', delta: '{ k = false;').
    lines=$(grep -c '^    { ' badapple-live.nix)
    [ "$lines" -eq "$fc" ] || {
      echo "SELF-TEST FAIL: $lines frame lines != $fc header frames" >&2; exit 1; }

    # Keyframes are exactly the frames at indices 0, K, 2K, ... -> ceil(fc/K).
    K=${toString keyframeInterval}
    want_keys=$(( ( fc + K - 1 ) / K ))
    got_keys=$(grep -c '^    { k = true;' badapple-live.nix)
    [ "$got_keys" -eq "$want_keys" ] || {
      echo "SELF-TEST FAIL: $got_keys keyframe lines != ceil($fc/$K) = $want_keys" >&2
      exit 1; }

    echo "SELF-TEST PASS: $fc frames ($got_keys keyframes @ K=$K, $(( fc - got_keys )) deltas)"

    echo "$fc" > .fc
    echo "$got_keys" > .keys

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
