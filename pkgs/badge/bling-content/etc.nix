# Assemble the badge's runtime content tree for /etc/nixbadge:
#
#   lib/      shared modules, importable as <nixbadge/lib/...> (draw + oled + the three
#             font tables; the HUD font.nix is added by Phase C)
#   oled.d/   NN-*.nix OLED screens the runtime scans (`nix-badge oled --eval-dir`), in
#             filename order (the NN- prefix = cycle order)
#   bling.d/  NN-*.nix LED patterns
#
# Screens + draw.nix use `<nixbadge/lib/...>` search-path imports (rewritten from the
# relative source), resolved at RUNTIME by nix-badge's `nixbadge=/etc/nixbadge` search path
# (both the fix and nix backends set it) and at BUILD time by `NIX_PATH=nixbadge=$out` in the
# self-test. This REPLACES screens-install.nix's textual inlining: now that the embedded fix
# Engine has a file-IO backend (Engine `.io`) AND a search path, a screen imports the shared
# lib instead of carrying an inlined copy -- so the font/draw code lives in exactly one place.
#
# The screens are height-parametric (they pack to scope.height), so ONE file serves both the
# 32- and 64-row panels; the self-test checks both. Bad Apple leads (10-) as a delta clip;
# it is generated + self-tested by badapple-live.nix, so it is copied in verbatim.
{
  pkgs,

  # Panel geometry / clip params, threaded to the Bad Apple bake. Match the runtime OLED.
  width ? 128,
  height ? 64,
  fps ? 60,
  durationSeconds ? null,
  keyframeInterval ? 60,

  badappleLive ? import ./badapple-live.nix {
    pkgs = pkgs.buildPackages;
    inherit width height fps durationSeconds keyframeInterval;
  },
}:
let
  lib = pkgs.lib;

  # The cyclable info screens, in cycle order (10- is Bad Apple, added separately).
  screens = [
    { n = "20"; name = "battery"; src = ./screens/battery.nix; }
    { n = "30"; name = "load"; src = ./screens/load.nix; }
    { n = "40"; name = "power"; src = ./screens/power.nix; }
    { n = "50"; name = "clock"; src = ./screens/clock.nix; }
    { n = "60"; name = "currentsystem"; src = ./screens/currentsystem.nix; }
  ];

  # Demoscene eye-candy screens (128x64-native). Copied verbatim (their one import,
  # the warmup loader's <nixbadge/lib/font.nix>, is already in search-path form) and
  # self-tested at @64 (256 ints) only. The phase-table effects (xor/plasma/rotozoom)
  # warm up ON the badge: the first 32 renders force one table frame each (the
  # honest, on-device eval) under a "WARM n/32" overlay, then play at ~30 fps.
  effects = [
    { n = "70"; name = "xor";       src = ./effects/xor-munch.nix; }
    { n = "72"; name = "plasma";    src = ./effects/plasma.nix; }
    { n = "74"; name = "starfield"; src = ./effects/starfield.nix; }
    { n = "76"; name = "rotozoom";  src = ./effects/rotozoom.nix; }
  ];

  # `import ./draw.nix` -> `import <nixbadge/lib/draw.nix>` for each screen.
  screenCmds = lib.concatMapStringsSep "\n" (s: ''
    sed -E 's|import \./draw\.nix|import <nixbadge/lib/draw.nix>|g' ${s.src} > "$out/oled.d/${s.n}-${s.name}.nix"
  '') screens;

  # Verbatim copy (self-contained: no import rewrite).
  effectCmds = lib.concatMapStringsSep "\n" (e: ''
    cp ${e.src} "$out/oled.d/${e.n}-${e.name}.nix"
  '') effects;

  # Self-test each effect at @64 only (they always emit 256 ints).
  effectChecks = lib.concatMapStringsSep "\n" (e: ''
    checkFrame "$out/oled.d/${e.n}-${e.name}.nix" 64 256
    echo "nixbadge-content: effect ${e.name} -> valid 128x64 frame (256 ints)"
  '') effects;

  # Build-time eval check per info screen at both supported panel heights (128 ints @32,
  # 256 @64). --impure: <nixbadge> comes from NIX_PATH and currentsystem reads currentSystem.
  checkCmds = lib.concatMapStringsSep "\n" (s: ''
    checkFrame "$out/oled.d/${s.n}-${s.name}.nix" 32 128
    checkFrame "$out/oled.d/${s.n}-${s.name}.nix" 64 256
    echo "nixbadge-content: ${s.name} -> <nixbadge/lib> imports resolve; valid frame @32 and @64"
  '') screens;
in
pkgs.runCommand "nixbadge-content"
  {
    nativeBuildInputs = [ pkgs.buildPackages.nix ];
  }
  ''
    mkdir -p "$out/lib" "$out/oled.d" "$out/bling.d"

    # lib: the leaf modules verbatim; draw.nix's own imports rewritten to <nixbadge/lib/...>.
    cp ${./oled.nix} "$out/lib/oled.nix"
    cp ${./screens/gallant-font-data.nix} "$out/lib/gallant-font-data.nix"
    cp ${./screens/spleen-5x8-font-data.nix} "$out/lib/spleen-5x8-font-data.nix"
    cp ${./screens/spleen-8x16-font-data.nix} "$out/lib/spleen-8x16-font-data.nix"
    # The HUD font: renders "[backend] fps" text into overlay entries (imports the 5x8 table).
    cp ${./lib/font.nix} "$out/lib/font.nix"
    sed -E \
      -e 's|import \.\./oled\.nix|import <nixbadge/lib/oled.nix>|g' \
      -e 's|import \./gallant-font-data\.nix|import <nixbadge/lib/gallant-font-data.nix>|g' \
      -e 's|import \./spleen-5x8-font-data\.nix|import <nixbadge/lib/spleen-5x8-font-data.nix>|g' \
      -e 's|import \./spleen-8x16-font-data\.nix|import <nixbadge/lib/spleen-8x16-font-data.nix>|g' \
      ${./screens/draw.nix} > "$out/lib/draw.nix"

    # oled.d: Bad Apple lead (generated + already self-tested) + the info screens
    # + the demoscene effects (self-contained, copied verbatim).
    cp ${badappleLive}/badapple-live.nix "$out/oled.d/10-badapple.nix"
    ${screenCmds}
    ${effectCmds}

    # bling.d: the live LED pattern.
    cp ${./leds-live.nix} "$out/bling.d/10-leds-live.nix"

    # ---- self-test: <nixbadge> imports resolve + each info screen yields a valid frame ----
    export NIX_PATH="nixbadge=$out"
    export NIX_STATE_DIR="$PWD/nix-state" NIX_STORE_DIR="$PWD/nix-store" HOME="$PWD"
    checkFrame() {
      local f="$1" h="$2" want="$3"
      nix --extra-experimental-features nix-command eval --impure --raw --expr "
        let r = (import $f) {
          t = 1234; frameIndex = 0; width = 128; height = $h; batteryMv = 4100;
          batteryPct = 87; onUsb = true; load1 = 0.42; cpuPct = 12; memPct = 40;
          uptimeS = 90061; backend = 0; fps = 60; strap = 1;
        };
        in if builtins.length r.bitmap == $want
              && builtins.all (x: builtins.isInt x) r.bitmap
              && builtins.any (x: x != 0) r.bitmap
              && builtins.isInt r.nextMs && r.nextMs > 0
           then \"ok\" else throw \"bad frame\"
      " >/dev/null || { echo "SELFTEST FAIL: $f did not eval to a valid $want-int frame @h=$h" >&2; exit 1; }
    }
    ${checkCmds}
    ${effectChecks}

    # Bad Apple: frame 0 (a keyframe) must eval AND carry a HUD overlay -- validates the
    # emitted `import <nixbadge/lib/font.nix>` + font.nix end-to-end (backend 1 = nix).
    nix --extra-experimental-features nix-command eval --impure --raw --expr "
      let r = (import $out/oled.d/10-badapple.nix) {
        frameIndex = 0; width = 128; height = 64; backend = 1; fps = 60; strap = 1;
        t = 0; batteryMv = 0; batteryPct = 0; onUsb = false; load1 = 0.0;
        cpuPct = 0; memPct = 0; uptimeS = 0;
      };
      in if builtins.isList r.bitmap && builtins.isInt r.nextMs
            && r.overlayN > 0 && builtins.all (x: builtins.isInt x) r.overlay
         then \"ok\" else throw \"bad badapple HUD frame\"
    " >/dev/null || { echo "SELFTEST FAIL: 10-badapple.nix frame 0 / HUD overlay did not eval" >&2; exit 1; }
    echo "nixbadge-content: badapple frame 0 evals + carries a [nix] fps HUD overlay"

    # A screen with NO search path must FAIL (proves the imports really are <nixbadge>, not
    # inlined): eval battery with NIX_PATH empty -> the import cannot resolve.
    if NIX_PATH="" nix --extra-experimental-features nix-command eval --impure --raw --expr "
      (import $out/oled.d/20-battery.nix) { width = 128; height = 64; batteryPct = 50; batteryMv = 3900; onUsb = false; } " >/dev/null 2>&1; then
      echo "SELFTEST FAIL: 20-battery.nix resolved WITHOUT the <nixbadge> search path (still inlined?)" >&2
      exit 1
    fi
    echo "nixbadge-content: confirmed screens require the <nixbadge> search path"

    echo "nixbadge-content: assembled lib/ + oled.d/ (badapple + ${toString (builtins.length screens)} screens) + bling.d/"
  ''
