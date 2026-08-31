# OLED engine: the nix-badge `oled` daemon drives the SAO OLED with
# Bad Apple (the default wake screen) plus battery/load/power/clock screens, and
# cycles LED patterns on the USER button / SIGUSR1, OLED screens on a long press /
# SIGUSR2.
#
# It owns the OLED + USER button + signals. The WS2812 ring stays with the
# leds.nix painter (which starts in the initrd and survives switch_root, the
# flicker-free early-boot path) -- the oled daemon only rewrites
# /etc/nixbadge/leds.conf to change the ring's pattern, and the painter
# hot-reloads it. So this service does NOT touch spidev and cannot disturb the
# ring's boot animation.
#
# The panel is an OPTIONAL component with a configurable size (see the options
# below): nixbadge.oled.enable gates the whole daemon (off = no OLED, no Bad
# Apple blob in the closure; the ring still animates from leds.nix), and
# width/height are passed to the runtime so a differently-sized 1-bit panel (a
# Sharp Memory display, a 128x64 OLED) works without a code change.
{ pkgs, lib, config, badgeFixSrc, ... }:
let
  cfg = config.nixbadge.oled;
  nixBadge = import ../../pkgs/badge/nix-badge.nix {
    inherit pkgs;
    fixSrc = badgeFixSrc;
    # The oled service is stage-2 only (never in the initrd), so it can link the
    # Nix C API dynamically: the shared-.so link takes seconds where the static
    # archive link took ~15 minutes, which is the whole edit-build-deploy loop
    # for runtime work. See nixbadge.oled.dynamicNix.
    nixDynamic = cfg.dynamicNix;
  };
  # The Bad Apple blob is arch-independent DATA (a packed 1-bit frame file), but
  # producing it runs ffmpeg + a tiny C packer. Build those on the build host
  # (buildPackages), not the target -- with target pkgs a cross build would try
  # to run aarch64 ffmpeg under emulation to transcode 3.5 min of video, which is
  # absurdly slow / breaks the build. The output bytes are identical either way.
  badApple = import ../../pkgs/badge/badapple { pkgs = pkgs.buildPackages; };
in
{
  options.nixbadge.oled = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the oled engine on the optional SAO OLED. When false the daemon is
        not started and the Bad Apple frame blob is not built into the closure
        (a badge assembled without the panel); the WS2812 ring still animates
        from the leds.nix painter.
      '';
    };
    width = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = "OLED width in pixels (128 for the SSD1306).";
    };
    height = lib.mkOption {
      # The SSD1306 driver's init parameterises multiplex + COM-pins for 32 or
      # 64 rows only; a Sharp/other panel would extend this.
      type = lib.types.enum [ 32 64 ];
      default = 32;
      description = "OLED height in pixels (32 or 64 rows).";
    };
    button = lib.mkOption {
      type = lib.types.str;
      default = "user-btn";
      description = ''
        Device-tree gpio-line-name of the USER button: a short press cycles the
        LED ring pattern, a long press cycles the OLED screen. Defaults to the
        dedicated USER button (PWR_GPIO1); btn-boot-n is intentionally NOT used
        so the bootswap daemon owns it. Until the DT names a line by this value
        the daemon runs on SIGUSR1/2 alone (the button is optional).
      '';
    };
    backend = lib.mkOption {
      type = lib.types.enum [ "fix" "nix" ];
      default = "fix";
      description = ''
        Which per-frame evaluator backend the eval screens use: "fix" (psyclyx
        fix's embedded `expr`) or "nix" (the upstream Nix C API, aarch64 only).
        This is only the STARTING choice -- a >5 s USER-button hold flips the
        backend live and persists the new choice to /etc/nixbadge/oled.backend,
        which is then honoured over this default on the next start (like the screen
        index + LED pattern already persist). On riscv (or a build with nixEval
        off) "nix" transparently falls back to fix at open().
      '';
    };
    blingDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixbadge/bling.d";
      description = ''
        Directory the USER short-press scans for pure-Nix LED patterns (*.nix,
        sorted; NN- prefix = cycle order). The press writes the next file's path
        as `eval = ` into leds.conf and the running painter hot-reloads it.
        Passed as `--bling-dir`.
      '';
    };
    dynamicNix = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Link the oled daemon's Nix C API backend DYNAMICALLY (shared nixComponents
        .so's, patchelf'd NixOS glibc interpreter + rpath) instead of the
        static-musl archive link. The static LLD crunch is the build's ~15-minute
        long pole; dynamic links in seconds, so every runtime iteration stops
        paying it. Costs closure size (the shared nix/boost/curl libs enter the
        closure) -- see the commit for the measured numbers. The initrd/bling
        binary is unaffected (always static; a dynamic binary cannot survive
        switch_root). Set false to ship the fully-static oled daemon again.
      '';
    };
    controller = lib.mkOption {
      type = lib.types.enum [ "auto" "ssd1306" "sh1106" ];
      default = "auto";
      description = ''
        Which controller drives the panel. "auto" probes at open: SH1106 supports
        reading its display RAM back over I2C, SSD1306 does not, so a write+read-back
        of two magic bytes discriminates them (falls back to ssd1306 on any I2C
        error). The two matter because SH1106 (common on 1.3" 128x64 modules) has a
        132-column RAM at a +2 offset and NO horizontal addressing mode -- an
        SSD1306-style bulk flush on it shows a scrambled/offset "corrupted" image.
        Set explicitly if the probe ever misidentifies a clone.
      '';
    };
    gcBudgetMb = lib.mkOption {
      type = lib.types.ints.positive;
      default = 128;
      description = ''
        The fix Engine's GC collection line, in MiB: the heap-reserved size at which an
        allocation triggers a collection. fix mints a fresh ~72 KB Value chunk per frame
        (8192 Values), so the per-frame young garbage MUST be collected regularly or it
        grows unbounded and overflows zram into SD swap (measured with the flat Bad Apple:
        budget 768 -> swap climbs past 526 MB, eval re-explodes to 16 s; budget 96 -> swap
        plateaus ~165 MB, eval ~5 ms). So this must sit only modestly above the Engine's
        steady live heap (Engine baseline + the compiled ScreenSet + the flat Bad Apple
        `data` list, together well under 100 MB now that no per-frame frame objects are
        pinned -- see badapple-live.nix). Lower = tighter memory but more frequent
        collection hitches; since collection is major-only (#34) each is ~O(live heap),
        ~100 ms, so a too-low budget adds visible hitches while a too-high one leaks. 128
        balances both and keeps the plateau safely inside zram. (The RIGHT long-term fix
        is a correct CHEAP minor GC so collects are O(garbage), not O(heap) -- then this
        knob barely matters.) fix's automatic line would be 256 MB on this board (too
        high). aarch64 only (no Engine on riscv).
      '';
    };
    evalScreens = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        A LIST of pure-Nix per-frame OLED screens (each the unified content
        contract: `scope: { bitmap = [ <int> ... ]; nextMs; }`, bitmap a flat
        list of packed ints, 4 page-bytes/int LE). When non-empty, the oled
        engine compiles them ALL ONCE into ONE shared fix Engine (a ScreenSet --
        one Value/chunk heap for the whole set, not one per screen) and applies
        the current one every frame; the USER long-press / SIGUSR2 cycles through
        them. Each is passed as a repeated `--eval-screen` arg (named by its file
        basename). A screen that fails to compile is skipped; if NONE load, the
        engine falls back to the computed Zig screens.

        aarch64 ONLY: the fix evaluator is compiled into the ARM core; on the
        eval-less riscv core the flags are accepted but the screens are skipped
        (the computed Zig screens run instead). The files are read at runtime
        (the oled daemon is a stage-2 service; no initrd), so point them at store paths --
        e.g. the `bling-screens` package's `<store>/screens/battery.nix` and the
        `bling-badapple-live` package's `<store>/badapple-live.nix`.
      '';
      example = lib.literalExpression ''
        [
          "''${pkgs.bling-badapple-live}/badapple-live.nix"
          "''${pkgs.bling-screens}/screens/battery.nix"
        ]
      '';
    };
    evalDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A directory the oled engine scans at runtime for *.nix screens (passed as
        `--eval-dir`), sorted by filename so a NN- numeric prefix sets the cycle order --
        drop-in, dir-based content (add a file, get a screen, no rebuild of the tool).
        The screens may `import <nixbadge/lib/...>` (a shared font/draw library), resolved
        by nix-badge's `nixbadge=/etc/nixbadge` search path. The default config sets this to
        "/etc/nixbadge/oled.d" (seeded as hackable symlinks by nixbadge-content.service).
        Combines with evalScreens
        (explicit --eval-screen paths are appended alongside the scanned ones).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixbadge-oled = {
      description = "nixbadge OLED engine (Bad Apple + screens)";
      wantedBy = [ "multi-user.target" ];
      # The i2c-1 bus, the SARADC IIO device and the USER button are all up via
      # udev well before multi-user; no ordering beyond basic.target is needed.
      serviceConfig = {
        # Runs as root: opens /dev/i2c-1 (0x3c), medians the SARADC sysfs for the
        # battery/rail screens, reads the USER button, and rewrites
        # /etc/nixbadge/leds.conf to cycle the ring's pattern.
        ExecStart = lib.concatStringsSep " " (
          [
            "${nixBadge}/bin/nix-badge oled"
            "--oled-width ${toString cfg.width}"
            "--oled-height ${toString cfg.height}"
            "--button ${cfg.button}"
            "--badapple ${badApple}/badapple.bin"
            "--backend ${cfg.backend}"
            # Cap the fix Engine's GC line so its heap collects instead of swapping (#28).
            "--gc-budget-mb ${toString cfg.gcBudgetMb}"
            # SSD1306 vs SH1106 (auto = I2C read-back probe at open).
            "--oled-controller ${cfg.controller}"
            # The pure-Nix LED pattern cycle dir (short press steps through it).
            "--bling-dir ${cfg.blingDir}"
          ]
          # The pure-Nix eval screens: one repeated `--eval-screen PATH` per
          # configured screen. All compile into ONE shared fix Engine (a
          # ScreenSet); when at least one loads they REPLACE the computed Zig
          # screens, else the oled daemon falls back to them. aarch64 only (no-op on riscv,
          # where eval is not built in). Order here = cycle order on the badge.
          ++ map (p: "--eval-screen ${p}") cfg.evalScreens
          # Dir-based content: scan oled.d for *.nix (sorted). The default config points
          # this at /etc/nixbadge/oled.d; screens there import <nixbadge/lib/...>.
          ++ lib.optional (cfg.evalDir != null) "--eval-dir ${cfg.evalDir}"
        );
        # the oled daemon exits 0 when the panel is absent (a core that does not mux the SAO
        # i2c, so /dev/i2c-1 has nothing at 0x3c): a clean no-op, not a failure,
        # so Restart=on-failure will not spin on such a core. A real fault
        # (mid-run i2c error) exits nonzero and we retry.
        Restart = "on-failure";
        RestartSec = 2;
        # Mutable state (leds.conf, oled.state, oled.backend) lives in /etc/nixbadge,
        # created declaratively (systemd.tmpfiles + nixbadge-content.service, which is
        # ordered Before= this unit) and by nix-badge's own mkdir at startup. The
        # service runs as root with no ProtectSystem, so /etc is writable.
      };
    };
  };
}
