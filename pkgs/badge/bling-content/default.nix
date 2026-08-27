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
    magic=$(head -c 4 "$out_bin")
    [ "$magic" = "BADA" ] || { echo "bad magic '$magic'"; exit 1; }
    w=$(od -An -tu2 -j4  -N2 "$out_bin" | tr -d ' ')
    h=$(od -An -tu2 -j6  -N2 "$out_bin" | tr -d ' ')
    fps=$(od -An -tu2 -j8  -N2 "$out_bin" | tr -d ' ')
    count=$(od -An -tu4 -j12 -N4 "$out_bin" | tr -d ' ')
    total=$(wc -c < "$out_bin")
    want=$(( 16 + count * w * (h / 8) ))
    [ "$total" -eq "$want" ] || { echo "size $total != $want (w=$w h=$h count=$count)"; exit 1; }
    echo "baked ${name}: ''${w}x''${h} ''${fps}fps ''${count} frames, $total bytes"
  ''
