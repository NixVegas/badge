# Install the pure-Nix OLED info screens (battery/load/power/clock/currentsystem)
# as SELF-CONTAINED .nix files -- each screen's `import ./draw.nix` (and draw.nix's
# own `import ../oled.nix` + `import ./gallant-font-data.nix`) is INLINED at build
# time so the runtime file has NO imports at all.
#
# WHY self-contained (not runtime import): the badge's embedded fix Engine is stood
# up WITHOUT a file-I/O backend (worker_count=0, no std.Io wired), so a runtime
# `import ./draw.nix` faults with FileIoUnavailable when the lazy import is forced.
# The proven model (badapple-live.nix) is likewise self-contained -- one function,
# zero imports -- and that is what this reproduces for the info screens.
#
# The inlining is textual + regular because the import shape is fixed:
#   screen.nix         `import ./draw.nix`                    -> the draw let-binding
#   draw.nix           `import ../oled.nix`                   -> the oled let-binding
#   draw.nix           `import ./gallant-font-data.nix`       -> the Gallant font binding
#   draw.nix           `import ./spleen-5x8-font-data.nix`    -> the Spleen 5x8 binding
#   draw.nix           `import ./spleen-8x16-font-data.nix`   -> the Spleen 8x16 binding
# Each imported file is a single Nix expression, so wrapping it in `( ... )` and
# substituting it for the import keeps the value identical. The screen (a
# `scope: ...` function) is preserved as a function: the emitted file is
#   scope: let __oled=(..); __font=(..); __draw=(..); in ( <screen> ) scope
# i.e. the original screen body applied to the same `scope`, with its import
# rewritten to the inlined draw binding.
#
# A build-time `nix eval` (stock nix, --pure) proves each emitted self-contained
# screen still yields a { bitmap = [128 ints]; nextMs; } from a sample scope, so a
# broken inlining fails the build, not the badge.
{ pkgs }:
let
  # currentsystem.nix uses builtins.currentSystem, which is impure; the build-time
  # self-test must feed it a fixed system so the derivation stays pure/reproducible.
  # A tiny prelude prepended ONLY for that screen's check pins the system.
  screensList = [ "battery" "load" "power" "clock" "currentsystem" ];
in
pkgs.runCommand "bling-screens"
  {
    src = ./.;
    nativeBuildInputs = [ pkgs.buildPackages.nix ];
    passAsFile = [ ];
    inherit screensList;
  }
  ''
    mkdir -p "$out/screens"
    export NIX_STATE_DIR="$PWD/nix-state" NIX_STORE_DIR="$PWD/nix-store" HOME="$PWD"

    oled="$src/oled.nix"
    draw="$src/screens/draw.nix"
    font="$src/screens/gallant-font-data.nix"
    spleen5x8="$src/screens/spleen-5x8-font-data.nix"
    spleen8x16="$src/screens/spleen-8x16-font-data.nix"

    # Inline draw.nix's imports (oled + the three font tables) into a self-contained
    # draw expression once (reused by every screen). Each import is one expression, so
    # substitute `( <file> )` for it. Order does not matter (distinct markers).
    make_draw_inlined() {
      # Replace each `import <file>` with a distinct __*Dep marker in draw.nix, then
      # bind those markers to the inlined file bodies.
      local drawbody
      drawbody=$(sed \
        -e 's|import \.\./oled\.nix|__oledDep|g' \
        -e 's|import \./gallant-font-data\.nix|__fontDep|g' \
        -e 's|import \./spleen-5x8-font-data\.nix|__spleen5x8Dep|g' \
        -e 's|import \./spleen-8x16-font-data\.nix|__spleen8x16Dep|g' \
        "$draw")
      {
        printf 'let\n'
        printf '  __oledDep = (\n'; cat "$oled"; printf '\n  );\n'
        printf '  __fontDep = (\n'; cat "$font"; printf '\n  );\n'
        printf '  __spleen5x8Dep = (\n'; cat "$spleen5x8"; printf '\n  );\n'
        printf '  __spleen8x16Dep = (\n'; cat "$spleen8x16"; printf '\n  );\n'
        printf 'in (\n'; printf '%s\n' "$drawbody"; printf ')\n'
      }
    }

    draw_inlined=$(make_draw_inlined)

    for s in $screensList; do
      screenbody=$(sed -e 's|import \./draw\.nix|__drawDep|g' "$src/screens/$s.nix")
      {
        printf 'scope:\n'
        printf 'let\n'
        printf '  __drawDep = (\n'; printf '%s\n' "$draw_inlined"; printf '  );\n'
        printf 'in (\n'; printf '%s\n' "$screenbody"; printf ') scope\n'
      } > "$out/screens/$s.nix"
    done

    # Self-test: every emitted screen is self-contained (NO imports remain) and evals
    # to a valid frame from a sample scope on BOTH supported panels. The framebuffer
    # is height-parametric (draw.nix packs to scope.height), so the packed-int count
    # is width*height/8/4: 128 ints @ height=32, 256 ints @ height=64. Checking both
    # proves each screen's 32-row AND 64-row layout inlines and evals correctly.
    # --impure so no ambient state matters for the read; currentsystem also needs
    # builtins.currentSystem. Neither affects reproducibility (reads only the file).
    check_frame() {
      local s="$1" h="$2" want="$3"
      nix --extra-experimental-features nix-command eval --impure --raw --expr "
        let
          f = import $out/screens/$s.nix;
          r = f { t = 1234; width = 128; height = $h; batteryMv = 4100; batteryPct = 87;
                  onUsb = true; load1 = 0.42; cpuPct = 12; memPct = 40; uptimeS = 90061; };
        in if builtins.length r.bitmap == $want
              && builtins.all (x: builtins.isInt x) r.bitmap
              && builtins.any (x: x != 0) r.bitmap
              && builtins.isInt r.nextMs && r.nextMs > 0
           then \"ok\" else throw \"bad frame\"
      " >/dev/null || { echo "SELF-TEST FAIL: $s did not eval to a valid $want-int frame at height=$h" >&2; exit 1; }
    }
    for s in $screensList; do
      # No `import` may remain in a self-contained screen.
      if grep -q 'import ' "$out/screens/$s.nix"; then
        echo "SELF-TEST FAIL: $s still contains an import after inlining" >&2; exit 1
      fi
      check_frame "$s" 32 128   # 128x32 panel -> 128 packed ints
      check_frame "$s" 64 256   # 128x64 panel -> 256 packed ints
      echo "bling-screens: $s -> self-contained; 128 ints @32, 256 ints @64 OK"
    done

    echo "bling-screens: installed $(echo $screensList | wc -w) self-contained screen(s)"
  ''
