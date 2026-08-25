# Onboard WiFi for the Milk-V Duo S: AICSemi AIC8800D80 on SDIO.
#
# The SDIO controller (mmc@4320000 / sdhci1) uses the mainline dwcmshc cv18xx host
# (see pkgs/firmware/dts/sg2000-milkv-duo-s.dts). The cap-sdio-irq property delivers
# the in-band SDIO interrupt through the sdio_claim_irq path. The aic8800 driver is
# built with usePoll = false so it uses that path. This also keeps the controller
# runtime-resumed, with the clock alive, across the post-START_APP wait.
#
# The driver and firmware come from the radxa-pkg/aic8800 fork. This is the vendor
# driver carried forward to recent mainline kernels through a quilt series. WiFi is
# built only on the ARM core. The SDIO host DTS and power sequence live there.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  src = pkgs.fetchFromGitHub {
    owner = "radxa-pkg";
    repo = "aic8800";
    rev = "bd11969265809a0fc948f1107c8256bbb2c1aa60";
    hash = "sha256-7M02L7G/cadlUWF3YG5CAumtmV7RmEbRHWqZQTddRUI=";
  };

  firmware = import ../../pkgs/wifi/aic8800-firmware.nix { inherit pkgs src; };

  driver = import ../../pkgs/wifi/aic8800.nix {
    inherit pkgs src;
    kernel = config.boot.kernelPackages.kernel;
    # usePoll = false selects the real in-band SDIO IRQ RX path (sdio_claim_irq),
    # not a poll kthread. The AIC8800 needs a 32.768kHz clock to complete fmac
    # init (FSBL SWITCH_32K_XTAL + u-boot CLK32K pinmux). Without that clock the
    # fmac stays dark and does not assert its in-band CARD_INT.
    #
    # With the clock present the fmac completes init, cfg80211 registers, and the
    # vendor SDHCI delivers the in-band CARD_INT, so the sdio_claim_irq path carries
    # all fmac traffic. The old poll/drain path (chip_id hardcode, force-credit,
    # FDRV busrx drain) was for a dead fmac and faults on live RX (NULL deref in
    # rwnx_rx_handle_msg via aicwf_busrx_thr). Keep usePoll = false.
    usePoll = false;
  };

  # AIC8800 wifi is the same SG2000/cv181x SoC block on both cores. Enable it on
  # both the ARM and RISC-V cores.
  onDuoS = pkgs.stdenv.hostPlatform.isAarch64 || pkgs.stdenv.hostPlatform.isRiscV64;
in
{
  # WiFi diagnostics from the shell, on both cores.
  environment.systemPackages = [ pkgs.iw ];

  # The AIC8800 is the same SoC SDIO block on both cores. The SDIO host node and
  # power sequence live in each core's DTS (sg2000-milkv-duo-s{,-riscv}.dts).
  hardware.firmware = lib.mkIf onDuoS [ firmware ];
  boot.extraModulePackages = lib.mkIf onDuoS [ driver ];
  boot.kernelModules = lib.mkIf onDuoS [
    "aic8800_bsp"
    "aic8800_fdrv"
  ];

  # The aic bsp calls cvi_get_wifi_pwr_on_desc()/cvi_sdio_rescan() from the
  # sdhci-cv181x host driver. Load the host first so these symbols resolve
  # before aic8800_bsp starts.
  boot.extraModprobeConfig = lib.mkIf onDuoS ''
    softdep aic8800_bsp pre: sdhci-cv181x
  '';
}
