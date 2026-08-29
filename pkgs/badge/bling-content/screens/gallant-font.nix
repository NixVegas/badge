# Build-time generator: fetch the PINNED Sun Gallant 12x22 BDF from illumos-gate
# (CDDL / Copyright 2006 Sun Microsystems, Inc.) and convert it to the pure-Nix
# glyph table draw.nix imports. This mirrors emit_nix.c for Bad Apple: a small
# derivation reads an open, redistributable font source and emits NUL-free Nix
# data (int lists), so no glyph bitmap is ever hand-typed.
#
# The output ($out/gallant-font-data.nix) is a pure-Nix attrset:
#   { width = 12; height = 22; glyphs = { "48" = [ <22 row ints> ]; ... }; }
# with one int per row, bit 11 = leftmost column (see gallant-bdf-to-nix.awk).
# That file is checked in beside draw.nix (as gallant-font-data.nix) so the screens
# eval with plain stock `nix eval` -- no network at eval time.
#
# The fetch is light (fetch + awk text parse, NO compiler), so `nix build` on this
# is cheap -- run it to (re)materialise the glyph table.
{ pkgs }:
let
  # PINNED to the illumos-gate commit that last touched the BDF. raw.githubusercontent
  # serves the exact blob at this commit, so the hash is stable and reproducible.
  gallantBdf = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/illumos/illumos-gate/4b529e40b9b8c5bcd0a4bc923a168c7988b72748/usr/src/data/consfonts/Gallant19.bdf";
    sha256 = "sha256-SkAjTLzO+UY8Gb+W7wShLSVC7VEQONpIAwqqU3IGZSY=";
  };
in
pkgs.runCommand "gallant-font-nix"
  {
    nativeBuildInputs = [ pkgs.gawk ];
    bdf = gallantBdf;
    awkScript = ./gallant-bdf-to-nix.awk;
    licenseNote = ./LICENSE.gallant;
  }
  ''
    mkdir -p "$out"
    awk -f "$awkScript" "$bdf" > "$out/gallant-font-data.nix"
    cp "$licenseNote" "$out/LICENSE.gallant"

    # Self-test: the printable ASCII range 0x20..0x7e (95 codepoints) must all be
    # present, and every glyph must carry exactly 22 row ints. A short/dropped glyph
    # fails the build, not the badge.
    n=$(grep -cE '^    "[0-9]+" = \[' "$out/gallant-font-data.nix")
    echo "gallant-font: emitted $n glyphs (want 95 printable ASCII)"
    [ "$n" -eq 95 ] || { echo "SELF-TEST FAIL: $n glyphs != 95" >&2; exit 1; }

    bad=$(grep -oE '\[ ([0-9]+ ){22}\];' "$out/gallant-font-data.nix" | wc -l)
    [ "$bad" -eq 95 ] || { echo "SELF-TEST FAIL: $bad glyphs with 22 rows != 95" >&2; exit 1; }
    echo "gallant-font: SELF-TEST PASS (95 glyphs x 22 rows)"
  ''
