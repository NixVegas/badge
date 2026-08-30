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
#   nix-badge bling set --pattern solid --color '#ff00ff'
# The CLI only writes /etc/nixbadge/leds.conf. The running service watches
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
  badgeFixSrc,
  ...
}:
let
  cfg = config.nixbadge.bling;

  pkg = import ../../pkgs/badge/nix-badge.nix {
    inherit pkgs;
    fixSrc = badgeFixSrc;
  };

  configFile = pkgs.writeText "nix-badge-leds.conf" ''
    device = ${cfg.device}
    count = ${toString cfg.count}
    speed_hz = ${toString cfg.speedHz}
    bits = ${toString cfg.bits}
    cs_high = ${if cfg.csHigh then "1" else "0"}
    brightness = ${toString cfg.brightness}
    fps = ${toString cfg.fps}
    pattern = ${cfg.pattern}
    colors = ${lib.concatStringsSep "," cfg.colors}
    ${lib.optionalString (cfg.blob != null) "blob = ${cfg.blob}"}
    ${lib.optionalString (cfg.evalPattern != null) "eval = ${cfg.evalPattern}"}
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
      ExecStart = "${pkg}/bin/nix-badge bling run --config ${configFile} --backend ${cfg.backend}";
      # on-failure, not always. The service exits 0 when the spidev node never
      # appears, which is what a core without an SPI3 pinmux does, and we must
      # not spin on that.
      Restart = "on-failure";
      RestartSec = 1;
      # No real-time priority. The WS2812 flicker under load came from PIO SPI
      # underrunning the TX FIFO; the DTS now feeds the FIFO by DMA (see the spi3
      # dmas / &dmac), so the CPU no longer clocks out frames and the painter's
      # scheduling no longer affects the waveform. It once ran SCHED_FIFO to keep
      # the PIO loop from being preempted, but that was actively harmful with DMA:
      # the dw-axi-dmac set_hw_channel path logs once per frame, and at RT priority
      # that printk to the slow serial console starved the AIC8800 wifi bring-up on
      # a fresh boot. Run at normal priority; the painter sleeps between 30fps
      # frames and does nothing timing-critical on the CPU anymore.
    };
  };
in
{
  options.nixbadge.bling = {
    enable = lib.mkEnableOption "the badge WS2812 LED ring";

    count = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Number of WS2812 LEDs on the ring.";
    };

    blob = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        A baked "BLED" RGB-frame blob (see pkgs/badge/bling-content/leds.nix, a
        pure-Nix `f(t) -> [rgb]` pattern evaluated by fix) to play on the ring
        instead of a computed pattern. null uses the computed `pattern`.
        Reloadable at run time: nix-badge bling set --blob PATH.
      '';
    };

    evalPattern = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        A pure-Nix LED pattern FUNCTION (see pkgs/badge/bling-content/leds-live.nix:
        `scope: { bitmap = [ 0xRRGGBB... ]; nextMs; }`) evaluated per frame by the
        embedded fix evaluator. Unlike `blob` (baked at build time), this reads the
        LIVE scope (t, battery, ...) each frame. Highest precedence, over blob and
        the computed pattern. aarch64 only -- ignored on the riscv core, which has
        no evaluator and falls back to blob/computed. Reloadable at run time:
        nix-badge bling set --eval PATH. Note: if set here (declaratively) the file
        is added to the initrd so early boot can eval it.
      '';
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "fix" "nix" ];
      default = "fix";
      description = ''
        Which per-frame evaluator drives an `evalPattern`: "fix" (embedded `expr`)
        or "nix" (the upstream Nix C API, aarch64 only), for an A/B on the LED ring.
        No-op unless `evalPattern` is set. On riscv (or nixEval off) "nix" falls
        back to fix at open().
      '';
    };

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/spidev3.0";
      description = "spidev node for the SPI3 controller.";
    };

    bits = lib.mkOption {
      type = lib.types.enum [
        3
        4
        8
      ];
      default = 8;
      description = ''
        SPI bits sent for each WS2812 bit.

          4  0 -> 1000, 1 -> 1110   high 25% or 75%, 12 bytes per LED
          3  0 -> 100,  1 -> 110    high 33% or 67%,  9 bytes per LED

        4 is the default and matches joosteto/ws2812-spi. Its wider 25/75 split
        has about twice the discrimination margin of the 3-bit 33/67 split. The
        3-bit encoding only worked on this badge within about 1% of nominal
        timing, and even then bits flipped at random.

        Reloadable at run time: nix-badge bling set --bits 3
      '';
    };

    csHigh = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ask spidev for SPI_CS_HIGH. Keep this true.

        The badge wires LED_DIN = CS AND SDO through U10, so chip select gates
        the LED data and has to be active HIGH. That is fixed in the device
        tree, not here: spi3 declares

          cs-gpios = <&portb 16 GPIO_ACTIVE_HIGH>

        with the pad muxed to XGPIOB_16 (mux 3) rather than SPI3_CS (mux 5).

        SPI_CS_HIGH cannot do it. With the native DesignWare chip select,
        dw_spi_set_cs only decides whether to raise the Slave Enable bit, and
        the pad polarity is fixed active-low in hardware. Only a gpiod chip
        select honours polarity. This option is kept purely as an escape hatch.
      '';
    };

    speedHz = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6400000;
      description = ''
        SPI clock in Hz. Together with `bits` this sets the LED bit time. The
        driver rounds to an even divisor of ssi_clk, and the service logs the
        timing it actually got.

        The badge chain is mixed XL-1615 and XL-2020, whose T1H window is
        0.9 to 1.0 us, NOT the WS2812B 0.8 us. With ssi_clk at 187.5 MHz and
        bits = 4, 3200000 gives divider 60, so 3125000 Hz: a 320 ns SPI bit,
        T0H 320 ns and T1H 960 ns, which sits inside that window.

        bits = 4 is required to reach it. With bits = 3 a 960 ns T1H would need
        a 480 ns SPI bit, giving a 1440 ns period that is too slow.

        Reloadable at run time, so a sweep needs no rebuild:
          nix-badge bling set --speed-hz 6400000
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
        message = "nixbadge.bling.colors must have at least one colour.";
      }
    ];

    environment.systemPackages = [ pkg ];

    # The binary and its config must live inside the initrd, not only on the
    # real root, because the service starts before switch_root.
    boot.initrd.systemd.storePaths = [
      "${pkg}/bin/nix-badge"
      configFile
    ]
    # A declaratively-set eval pattern is read by name at runtime, so its source
    # must be in the initrd too for early-boot eval.
    ++ lib.optional (cfg.evalPattern != null) cfg.evalPattern;

    # spi-dw-mmio and spidev are built into the kernel, but the DTS routes SPI3
    # through the cv1800b dmamux for slave DMA, so dw_spi defers its probe until
    # the DMA controller and the dmamux are present. Both are modules
    # (CONFIG_DW_AXI_DMAC=m, CONFIG_SOPHGO_CV1800B_DMAMUX=m) that otherwise
    # autoload only at ~t=94s -- long after this service's spidev wait -- so
    # /dev/spidev3.0 would not exist in the initrd and the ring would stay dark
    # until a manual restart. Force them into the initrd so dw_spi probes with DMA
    # early: the ring lights from the initrd on, and the DMA offload keeps the
    # whole system responsive under LED load.
    boot.initrd.kernelModules = [ "dw_axi_dmac_platform" "cv1800b_dmamux" ];

    boot.initrd.systemd.services.nixbadge-bling = unit [ "initrd.target" ];
    systemd.services.nixbadge-bling = unit [ "sysinit.target" ];

    # /etc/nixbadge holds the runtime config the CLI writes (leds.conf), alongside
    # the seeded default content. common.nix also declares this dir; tmpfiles dedups.
    # The initrd has no populated /etc/nixbadge, which is why early boot always uses
    # the declarative config.
    systemd.tmpfiles.rules = [ "d /etc/nixbadge 0755 root root -" ];
  };
}
