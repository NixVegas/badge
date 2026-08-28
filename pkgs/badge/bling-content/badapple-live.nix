# Bad Apple!! as a PURE-NIX PATTERN FILE the badge's embedded fix evaluator
# applies once per frame (compile-once + native applyValue, the same path proven
# for LEDs -- see pkgs/badge/nix-badge/fixeval.zig). Unlike the baked "BADA" blob
# (pkgs/badge/badapple, which the runtime mmaps), this emits a Nix FUNCTION:
#
#   scope:
#   let frames = [ [ <128 ints> ] ... ]; nframes = N; fps = 20;
#       mod = a: b: a - (a / b) * b;
#   in { bitmap = builtins.elemAt frames (mod (scope.t * fps / 1000) nframes);
#        nextMs = 50; }
#
# Each frame is the 512 page-major GDDRAM bytes (128x32) packed into 128 ints, 4
# consecutive page-bytes per int LITTLE-ENDIAN (int = b0 | b1<<8 | b2<<16 |
# b3<<24). renderOled decodes each int back to those 4 bytes and blits.
#
# The frames come from the EXISTING Bad Apple pipeline: import ../badapple to get
# the ffmpeg-baked "BADA" blob (deterministic: pinned video, gray8 -> threshold
# -> page-major pack), then a tiny C program (emit_nix.c) reads the 512-byte
# frames past the 16-byte header and emits the Nix text.
#
# durationSeconds defaults SMALL (20 s ~= 400 frames) so the test build + the
# on-badge parse stay fast; set it to null for the whole song (~4379 frames,
# ~6 MB of Nix source).
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

    gcc -O2 -Wall -Wextra -std=c11 -o emit_nix ${./emit_nix.c}

    # Feed the baked BADA blob through the emitter -> the pure-Nix pattern.
    ./emit_nix < ${badapple}/badapple.bin > badapple-live.nix

    runHook postBuild
  '';

  # Self-test: the emitted Nix must declare the frame count the blob's header
  # claims, and every frame line must carry exactly wordsPerFrame ints. A
  # mismatch (a dropped/short frame, a geometry skew) fails the build, not the
  # badge. The header's frame_count is the u32 at blob offset 12 (LE).
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    blob=${badapple}/badapple.bin
    fc=$(od -An -tu4 -j12 -N4 "$blob" | tr -d ' ')
    echo "badapple-live: blob declares $fc frames"

    # Count the emitted frame lines (each begins with 4 spaces + '[').
    lines=$(grep -c '^    \[' badapple-live.nix)
    [ "$lines" -eq "$fc" ] || {
      echo "SELF-TEST FAIL: $lines frame lines != $fc header frames" >&2; exit 1; }

    # The total int count across all frame lines must equal fc*wordsPerFrame. The
    # ints are exactly the non-'[' / non-']' whitespace tokens on the frame lines,
    # so grep the frame lines, strip the brackets, and count words.
    want_ints=$(( fc * ${toString wordsPerFrame} ))
    got_ints=$(grep '^    \[' badapple-live.nix | tr -d '[]' | wc -w)
    [ "$got_ints" -eq "$want_ints" ] || {
      echo "SELF-TEST FAIL: $got_ints ints != $fc*${toString wordsPerFrame} = $want_ints" >&2
      exit 1; }

    echo "SELF-TEST PASS: $fc frames x ${toString wordsPerFrame} ints = $want_ints ints"

    echo "$fc" > .fc

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 badapple-live.nix "$out/badapple-live.nix"

    fc=$(cat .fc)
    size=$(stat -c%s "$out/badapple-live.nix")
    {
      echo "badapple-live.nix -- pure-Nix Bad Apple pattern (fix applyValue per frame)"
      echo "geometry:     ${toString width}x${toString height} (${toString fbLen} bytes/frame)"
      echo "ints/frame:   ${toString wordsPerFrame} (4 page-bytes/int, LE)"
      echo "fps:          ${toString fps}"
      echo "frame_count:  $fc"
      echo "duration_cap: ${if durationSeconds == null then "none (full song)" else toString durationSeconds + " s"}"
      echo "nix_bytes:    $size"
    } > "$out/badapple-live.info"

    runHook postInstall
  '';

  meta = {
    description = "Bad Apple!! as a pure-Nix per-frame pattern for the badge OLED (fix applyValue)";
    longDescription = ''
      A single Nix function ($out/badapple-live.nix) the badge's embedded fix
      evaluator compiles once and applies every frame to a fresh scope, decoding
      the returned flat int list into SSD1306 page-major bytes (renderOled). The
      frames are re-encoded from the deterministic ffmpeg-baked "BADA" blob.
    '';
    platforms = pkgs.lib.platforms.all; # build-host tool; output is arch-neutral Nix text
  };
}
