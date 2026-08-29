# Build-time generator: fetch the PINNED Spleen BDFs (Frederic Cambus, BSD-2-Clause;
# github fcambus/spleen) and convert them to the pure-Nix glyph tables draw.nix
# imports. This mirrors gallant-font.nix: a small derivation reads an open,
# redistributable font source and emits NUL-free Nix data (int lists), so no glyph
# bitmap is ever hand-typed.
#
# Two sizes are generated (both uniform fixed cells):
#   spleen-5x8-font-data.nix   -- dense; ~25 chars across a 128px line (detail rows)
#   spleen-8x16-font-data.nix  -- mid; a readable secondary size
# Each output is a pure-Nix attrset:
#   { width; height; glyphs = { "48" = [ <height row ints> ]; ... }; }
# with one int per row, bit (width-1) = leftmost column (see spleen-bdf-to-nix.awk).
# Both are checked in beside draw.nix (spleen-5x8-font-data.nix, spleen-8x16-font-data.nix)
# so the screens eval with plain stock `nix eval` -- no network at eval time.
#
# The fetch is light (fetch + awk text parse, NO compiler), so `nix build` on this
# is cheap -- run it to (re)materialise the glyph tables.
{ pkgs }:
let
  # PINNED to the Spleen 2.2.0 release commit. raw.githubusercontent serves the exact
  # blob at this commit, so the hash is stable and reproducible.
  rev = "0493c34e22791824767c618fed42c434b477662c"; # tag 2.2.0
  spleen5x8Bdf = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/fcambus/spleen/${rev}/spleen-5x8.bdf";
    sha256 = "sha256-QEiBhNB10MdSzdI5tEHF7OUeULNTFW8klsdWw4SrAcs=";
  };
  spleen8x16Bdf = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/fcambus/spleen/${rev}/spleen-8x16.bdf";
    sha256 = "sha256-Sj2X7mGoyGp1JdjHI8uKFAgfOVzS/rQie6XjuvBim64=";
  };
in
pkgs.runCommand "spleen-font-nix"
  {
    nativeBuildInputs = [ pkgs.gawk ];
    bdf5x8 = spleen5x8Bdf;
    bdf8x16 = spleen8x16Bdf;
    awkScript = ./spleen-bdf-to-nix.awk;
    licenseNote = ./LICENSE.spleen;
  }
  ''
    mkdir -p "$out"
    awk -v width=5 -v height=8  -f "$awkScript" "$bdf5x8"  > "$out/spleen-5x8-font-data.nix"
    awk -v width=8 -v height=16 -f "$awkScript" "$bdf8x16" > "$out/spleen-8x16-font-data.nix"
    cp "$licenseNote" "$out/LICENSE.spleen"

    # Self-test: the printable ASCII range 0x20..0x7e (95 codepoints) must all be
    # present, and every glyph must carry exactly `height` row ints. A short/dropped
    # glyph fails the build, not the badge.
    check() {
      local file="$1" rows="$2"
      n=$(grep -cE '^    "[0-9]+" = \[' "$file")
      echo "spleen-font: $file emitted $n glyphs (want 95 printable ASCII)"
      [ "$n" -eq 95 ] || { echo "SELF-TEST FAIL: $file $n glyphs != 95" >&2; exit 1; }
      bad=$(grep -oE "\[ ([0-9]+ ){$rows}\];" "$file" | wc -l)
      [ "$bad" -eq 95 ] || { echo "SELF-TEST FAIL: $file $bad glyphs with $rows rows != 95" >&2; exit 1; }
      echo "spleen-font: SELF-TEST PASS ($file: 95 glyphs x $rows rows)"
    }
    check "$out/spleen-5x8-font-data.nix" 8
    check "$out/spleen-8x16-font-data.nix" 16
  ''
