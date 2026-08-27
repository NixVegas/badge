# Bake a pure-Nix animation (oled.nix + an entry like demo.nix) into the BADA
# blob the runtime plays, using the `fix` evaluator (psyclyx/fix: a fast,
# parallel Nix-language evaluator in Zig). `fix eval --raw` prints the hex string
# the animation returns; xxd decodes it to the binary blob. Using fix, not stock
# nix, keeps the heavy per-frame precompute fast -- the point of authoring the
# screens in Nix on the Nix Badge.
#
# The whole content dir is the src so the entry's `import ./oled.nix` resolves in
# the sandbox. A build-time assert checks the BADA magic + that the size matches
# 16 + frame_count*width*(height/8).
{
  pkgs,
  fix,
  # Entry .nix (relative to this dir) that returns the hex blob string.
  entry ? "demo.nix",
  name ? "bling-anim",
}:
pkgs.runCommand "${name}.bin"
  {
    nativeBuildInputs = [
      fix
      pkgs.xxd
    ];
    src = ./.;
  }
  ''
    mkdir -p "$out"
    out_bin="$out/${name}.bin"
    fix eval --raw "$src/${entry}" | xxd -r -p > "$out_bin"

    # Validate the blob so a broken animation fails the build, not the badge.
    # Two formats: BADA (OLED, 16B header, page-major 1-bit frames) and BLED
    # (LED ring, 12B header, nleds*3 RGB frames). Field at offset 4 is the width
    # (BADA) or nleds (BLED).
    magic=$(head -c 4 "$out_bin")
    a=$(od -An -tu2 -j4 -N2 "$out_bin" | tr -d ' ')  # width | nleds
    total=$(wc -c < "$out_bin")
    case "$magic" in
      BADA)
        h=$(od -An -tu2 -j6 -N2 "$out_bin" | tr -d ' ')
        count=$(od -An -tu4 -j12 -N4 "$out_bin" | tr -d ' ')
        want=$(( 16 + count * a * (h / 8) )) ;;
      BLED)
        count=$(od -An -tu4 -j8 -N4 "$out_bin" | tr -d ' ')
        want=$(( 12 + count * a * 3 )) ;;
      *) echo "bad magic '$magic'"; exit 1 ;;
    esac
    [ "$total" -eq "$want" ] || { echo "size $total != $want ($magic a=$a count=$count)"; exit 1; }
    echo "baked ${name}: $magic, $count frames, $total bytes"
  ''
