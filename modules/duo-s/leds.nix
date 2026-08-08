# WS2812 LED ring on the Milk-V Duo S badge, driven from SPI3 through spidev.
#
# The service starts in the initrd so the badge shows life as early as
# possible, and it keeps running after switch_root. systemd PID1 serializes
# unit state across a switch-root, so a unit that exists on BOTH sides with the
# same name and the same ExecStart carries over instead of being torn down.
# That is why the unit body below is shared between boot.initrd.systemd.services
# and systemd.services.
#
# To change the pattern or the colours at run time use the CLI:
#   nixbadge-leds set --pattern solid --color '#ff00ff'
# The CLI only writes /var/lib/nixbadge/leds.conf. The running service watches
# that file and reloads when the mtime moves, so nothing calls systemctl and
# the binary keeps a glibc-only closure. An animation notices within one frame,
# a static pattern within half a second.
#
# A reload takes the pattern, brightness, fps and colours. It does NOT reload
# device, count or speedHz: those describe the board, the SPI node is already
# open and the frame buffers are already sized. Change them with a rebuild.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixbadge.leds;

  pkg = import ../../pkgs/leds/nixbadge-leds.nix { inherit pkgs; };

  configFile = pkgs.writeText "nixbadge-leds.conf" ''
    device = ${cfg.device}
    count = ${toString cfg.count}
    speed_hz = ${toString cfg.speedHz}
    brightness = ${toString cfg.brightness}
    fps = ${toString cfg.fps}
    pattern = ${cfg.pattern}
    colors = ${lib.concatStringsSep "," cfg.colors}
  '';

  # One unit body, used in the initrd and in stage 2. Keep these identical or
  # the handover across switch_root does not hold.
  unit = wantedBy: {
    description = "nixbadge WS2812 LED ring";
    inherit wantedBy;
    unitConfig = {
      DefaultDependencies = false;
      IgnoreOnIsolate = true;
      # Without this the initrd's final kill would take the process down at
      # exactly the moment we want it to keep painting.
      SurviveFinalKillSignal = true;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkg}/bin/nixbadge-leds run --config ${configFile}";
      # on-failure, not always. The service exits 0 when the spidev node never
      # appears, which is what a core without an SPI3 pinmux does, and we must
      # not spin on that.
      Restart = "on-failure";
      RestartSec = 1;
    };
  };
in
{
  options.nixbadge.leds = {
    enable = lib.mkEnableOption "the badge WS2812 LED ring";

    count = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Number of WS2812 LEDs on the ring.";
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/spidev3.0";
      description = "spidev node for the SPI3 controller.";
    };

    speedHz = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2400000;
      description = ''
        SPI clock in Hz. The encoder sends 3 SPI bits for each LED bit, so this
        must give a 1.25 us LED bit. The driver rounds to an even divisor of
        ssi_clk, and the service logs the rate it actually got.
      '';
    };

    brightness = lib.mkOption {
      type = lib.types.ints.between 0 255;
      default = 64;
      description = ''
        Global brightness. WS2812 has no brightness byte, so the service scales
        the colour channels in software.
      '';
    };

    fps = lib.mkOption {
      type = lib.types.ints.between 1 200;
      default = 30;
      description = "Animation frames per second.";
    };

    pattern = lib.mkOption {
      type = lib.types.enum [
        "off"
        "solid"
        "pulse"
        "rainbow"
        "chase"
      ];
      default = "rainbow";
      description = "Pattern to show at boot.";
    };

    colors = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "#[0-9a-fA-F]{6}");
      default = [ "#ffffff" ];
      example = [
        "#ff0000"
        "#00ff00"
        "#0000ff"
      ];
      description = ''
        Colours the pattern uses. "solid" spreads them over the ring, "pulse"
        uses the first, and "chase" steps through them one lap at a time.
        "rainbow" ignores them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.colors != [ ];
        message = "nixbadge.leds.colors must have at least one colour.";
      }
    ];

    environment.systemPackages = [ pkg ];

    # The binary and its config must live inside the initrd, not only on the
    # real root, because the service starts before switch_root.
    boot.initrd.systemd.storePaths = [
      "${pkg}/bin/nixbadge-leds"
      configFile
    ];

    boot.initrd.systemd.services.nixbadge-leds = unit [ "initrd.target" ];
    systemd.services.nixbadge-leds = unit [ "sysinit.target" ];

    # /var/lib/nixbadge holds the runtime config the CLI writes. The initrd has
    # no /var, which is why early boot always uses the declarative config.
    systemd.tmpfiles.rules = [ "d /var/lib/nixbadge 0755 root root -" ];
  };
}
