# Bad Apple!! -> packed 1-bit frame blob for the badge's 128x32 SSD1306 OLED.
#
# Produces $out/badapple.bin, the "BADA" blob the runtime mmaps and blits (see
# README.md for the byte format; it is exactly the nix-badge.c set_pixel /
# GDDRAM layout). Also emits $out/badapple.info (human-readable stats).
#
# The whole thing is reproducible: the video is a fixed-output fetch (pinned
# rev + sha256), and the transcode/pack is deterministic (ffmpeg gray8 ->
# a tiny C packer). Swap the `src` (see README) to use different footage.
#
# Build:
#   nix-build -E 'with import <nixpkgs> {}; import ./pkgs/badge/badapple { inherit pkgs; }'
#
# Assisted-by: Claude Opus 4.8 <noreply@anthropic.com>
{
  pkgs,

  # Panel geometry. Matches the runtime OLED (nix-badge.c: OLED_W/OLED_H).
  # height must be a multiple of 8 (SSD1306 pages are 8 rows tall).
  width ? 128,
  height ? 32,

  # Playback rate baked into the header. ~20 fps is a good balance of motion
  # and blob size for this panel; the runtime reads fps from the header.
  fps ? 20,

  # Luma threshold (0..255): a pixel is ON (white) iff gray >= threshold.
  # 128 is the natural midpoint for Bad Apple's high-contrast silhouettes.
  threshold ? 128,

  # Optional cap on duration in seconds (null = whole song, ~219 s). Lower this
  # to shrink the blob (e.g. 90 for ~1.6 MB). null keeps the full run.
  durationSeconds ? null,

  # Scaling strategy into width x height. Bad Apple is 4:3 (480x360); the panel
  # is 4:1, so aspect-preserving letterboxing wastes most of the panel on black
  # bars. "stretch" fills the panel and keeps the silhouette clearly readable
  # (the conventional choice for wide-short OLEDs). Alternatives:
  #   "fit"   - preserve aspect, letterbox with black bars (tiny centered figure)
  #   "crop"  - center-crop to the panel aspect, then scale (loses top/bottom)
  scale ? "stretch",

  # The source video. Pinned Internet Archive copy of "Bad Apple!!" at native
  # resolution and a TRUE 60 fps (bad_apple@60fps.mp4, h.264, ~219.5 s). The delta
  # codec runs at 60 fps, so the source must have real 60 fps motion -- the older
  # TouhouBadApple mp4 is only 30 fps, and baking that at 60 just duplicated every
  # frame (empty deltas, no extra motion). Override `src` to swap footage.
  src ?
    pkgs.fetchurl {
      # https://archive.org/details/bad-apple-resources  (file bad_apple@60fps.mp4)
      url = "https://archive.org/download/bad-apple-resources/bad_apple%4060fps.mp4";
      name = "bad-apple-60fps.mp4";
      sha256 = "94d47ffcb5b8b045e257a52afb931059095a1b1d87c0da84e9e2a25a2c373517";
    },
}:

let
  lib = pkgs.lib;

  # ffmpeg -vf scale filter for the chosen strategy.
  scaleFilter =
    let
      wh = "${toString width}:${toString height}";
    in
    {
      stretch = "scale=${wh}";
      fit = "scale=${wh}:force_original_aspect_ratio=decrease,pad=${wh}:(ow-iw)/2:(oh-ih)/2:color=black";
      crop = "crop=iw:iw*${toString height}/${toString width},scale=${wh}";
    }
    .${scale} or (throw "badapple: unknown scale strategy '${scale}' (use stretch|fit|crop)");

  durationArgs = lib.optionalString (durationSeconds != null) "-t ${toString durationSeconds}";

  fbLen = (width * height) / 8; # bytes per packed frame (512 for 128x32)
in

assert lib.assertMsg (height / 8 * 8 == height) "badapple: height must be a multiple of 8";

pkgs.stdenv.mkDerivation {
  pname = "badapple-blob";
  version = "1.0";

  inherit src;
  dontUnpack = true;

  nativeBuildInputs = [
    pkgs.ffmpeg
    pkgs.gcc
  ];

  # Deterministic: no timestamps or randomness enter the output.
  buildPhase = ''
    runHook preBuild

    # 1. Build the packer.
    gcc -O2 -Wall -Wextra -std=c11 -o pack ${./pack.c}

    # 2. Transcode to a stream of gray8 frames (row-major, top-left origin):
    #    - fps: resample to the target rate
    #    - scaleFilter: fit the panel per the chosen strategy
    #    - format=gray: one byte per pixel
    #    ffmpeg's own threshold isn't used; the packer thresholds so the bit
    #    layout stays in one place. Output goes to a pipe into the packer.
    echo "badapple: transcoding $src -> ${toString width}x${toString height} @ ${toString fps} fps (${scale})"
    ffmpeg -hide_banner -loglevel error -nostdin \
      ${durationArgs} -i "$src" \
      -vf "fps=${toString fps},${scaleFilter},format=gray" \
      -pix_fmt gray -f rawvideo - \
      | ./pack ${toString width} ${toString height} ${toString fps} ${toString threshold} \
        > badapple.bin

    runHook postBuild
  '';

  # 3. Self-test: the header must say BADA / correct geometry, and the file
  #    size must be exactly 16 + frame_count*fbLen. Fail the build otherwise.
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    size=$(stat -c%s badapple.bin)
    if [ "$size" -lt 16 ]; then
      echo "SELF-TEST FAIL: file smaller than header ($size bytes)" >&2
      exit 1
    fi

    read -r magic w h f flags fc < <(od -An -v -tx1 -N16 badapple.bin | tr -s ' ' | \
      awk '{
        # bytes: 0-3 magic, 4-5 w, 6-7 h, 8-9 fps, 10-11 flags, 12-15 count (LE)
        printf "%s%s%s%s ",$1,$2,$3,$4;                 # magic hex
        printf "%d ",   strtonum("0x"$6 $5);            # width
        printf "%d ",   strtonum("0x"$8 $7);            # height
        printf "%d ",   strtonum("0x"$10 $9);           # fps
        printf "%d ",   strtonum("0x"$12 $11);          # flags
        printf "%d\n",  strtonum("0x"$16 $15 $14 $13);  # frame_count
      }')

    echo "SELF-TEST: magic=$magic width=$w height=$h fps=$f flags=$flags frames=$fc size=$size"

    [ "$magic" = "42414441" ] || { echo "SELF-TEST FAIL: magic not 'BADA' (got $magic)" >&2; exit 1; }
    [ "$w" -eq ${toString width} ]   || { echo "SELF-TEST FAIL: width $w != ${toString width}" >&2; exit 1; }
    [ "$h" -eq ${toString height} ]  || { echo "SELF-TEST FAIL: height $h != ${toString height}" >&2; exit 1; }
    [ "$flags" -eq 0 ] || { echo "SELF-TEST FAIL: flags $flags != 0" >&2; exit 1; }
    [ "$fc" -gt 0 ]    || { echo "SELF-TEST FAIL: zero frames" >&2; exit 1; }

    expected=$(( 16 + fc * ${toString fbLen} ))
    [ "$size" -eq "$expected" ] || {
      echo "SELF-TEST FAIL: size $size != 16 + $fc*${toString fbLen} = $expected" >&2; exit 1; }

    echo "SELF-TEST PASS"

    # Stash the parsed numbers for installPhase's info file.
    echo "$fc $f $size" > .stats

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 badapple.bin "$out/badapple.bin"

    read -r fc f size < .stats
    {
      echo "badapple.bin -- packed 1-bit frame blob for a ${toString width}x${toString height} SSD1306 OLED"
      echo "format:       BADA (flags=0, uncompressed raw frames)"
      echo "width:        ${toString width}"
      echo "height:       ${toString height}"
      echo "fps:          $f"
      echo "frame_count:  $fc"
      echo "bytes/frame:  ${toString fbLen}"
      echo "total_bytes:  $size"
      echo "scale:        ${scale}"
      echo "threshold:    ${toString threshold}"
      echo "duration_cap: ${if durationSeconds == null then "none (full song)" else toString durationSeconds + " s"}"
    } > "$out/badapple.info"

    runHook postInstall
  '';

  meta = {
    description = "Bad Apple!! as a packed 1-bit frame blob for the badge's 128x32 SSD1306 OLED";
    longDescription = ''
      A single little-endian file (badapple.bin) with a 16-byte "BADA" header
      followed by frame_count 512-byte frames in SSD1306 page-major GDDRAM
      layout -- byte-identical to the runtime framebuffer (nix-badge.c). The
      runtime mmaps this and blits each frame to the panel.
    '';
    platforms = pkgs.lib.platforms.all; # build-host tool; output is arch-neutral data
  };
}
