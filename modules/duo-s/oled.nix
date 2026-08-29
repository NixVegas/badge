# OLED engine: the nix-badge `oled` daemon drives the SAO OLED with
# Bad Apple (the default wake screen) plus battery/load/power/clock screens, and
# cycles LED patterns on the USER button / SIGUSR1, OLED screens on a long press /
# SIGUSR2.
#
# It owns the OLED + USER button + signals. The WS2812 ring stays with the
# leds.nix painter (which starts in the initrd and survives switch_root, the
# flicker-free early-boot path) -- the oled daemon only rewrites
# /var/lib/nix-badge/leds.conf to change the ring's pattern, and the painter
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
        # /var/lib/nix-badge/leds.conf to cycle the ring's pattern.
        ExecStart = lib.concatStringsSep " " (
          [
            "${nixBadge}/bin/nix-badge oled"
            "--oled-width ${toString cfg.width}"
            "--oled-height ${toString cfg.height}"
            "--button ${cfg.button}"
            "--badapple ${badApple}/badapple.bin"
          ]
          # The pure-Nix eval screens: one repeated `--eval-screen PATH` per
          # configured screen. All compile into ONE shared fix Engine (a
          # ScreenSet); when at least one loads they REPLACE the computed Zig
          # screens, else the oled daemon falls back to them. aarch64 only (no-op on riscv,
          # where eval is not built in). Order here = cycle order on the badge.
          ++ map (p: "--eval-screen ${p}") cfg.evalScreens
        );
        # the oled daemon exits 0 when the panel is absent (a core that does not mux the SAO
        # i2c, so /dev/i2c-1 has nothing at 0x3c): a clean no-op, not a failure,
        # so Restart=on-failure will not spin on such a core. A real fault
        # (mid-run i2c error) exits nonzero and we retry.
        Restart = "on-failure";
        RestartSec = 2;
        # Shared with the leds painter; ensures /var/lib/nix-badge exists for the
        # leds.conf rewrite.
        StateDirectory = "nix-badge";
      };
    };
  };
}
