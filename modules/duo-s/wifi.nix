# Onboard WiFi for the Milk-V Duo S badge: AICSemi AIC8800D80 on SDIO.
#
# Mainline-pure approach: the SDIO controller (mmc@4320000 / sdhci1) runs the
# stock mainline dwcmshc cv18xx host (see pkgs/firmware/dts/sg2000-milkv-duo-s.dts),
# with cap-sdio-irq so the chip's in-band SDIO interrupt is delivered through the
# real sdio_claim_irq path. The aic8800 driver is built WITHOUT the old poll
# workaround (usePoll = false) so it uses that path -- which is also what pins the
# controller runtime-resumed (clock alive) across the post-START_APP wait, the bit
# every prior poll-based attempt was missing.
#
# Driver + firmware come from the radxa-pkg/aic8800 fork (vendor driver carried
# forward to recent mainline kernels via its quilt series). Built only on the ARM
# core, which is where the SDIO host DTS + power sequence live.
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
    # The cv18xx dwcmshc host does NOT deliver the AIC8800's in-band SDIO
    # CARD_INT to the driver (proven on hw: with the real sdio_claim_irq path the
    # first BSP command cmd 1024 times out waiting for reqcfm 1025, and the RX
    # handler never logs a single tick). Synchronous SDIO reads DO work here
    # (firmware upload + card enumeration succeed), so drive the same RX handler
    # from a poll kthread. This is the empirically-required RX path on this SoC.
    # FIX6: the vendor SDHCI delivers the real in-band CARD_INT, so the normal
    # sdio_claim_irq RX path handles every cfm EXCEPT the START_APP one (1038),
    # which the loader posts then self-clears by jumping. We stop waiting on that
    # racy cfm entirely (see aic8800.nix start_app non-blocking sub), so the poll
    # workaround is not needed here; real IRQ carries fdrv's traffic.
    #
    # 2026-07-05: ROOT CAUSE FOUND = the radxa driver corrupted the fmacfw in RAM
    # by writing the patch table to a stale hardcoded 0x0016F800 (aic8800.nix now
    # ports the vendor NEW_PATCH_BUFFER_MAP relocation). The whole poll/drain/
    # chip_id-bypass machinery was built for the WRONG theory (fmac alive-but-RX-
    # broken) under that corrupted firmware. Test the clean vendor-matching path:
    # usePoll=false = stock radxa fdrv + real in-band IRQ via the vendor SDHCI, no
    # poll patches. With intact firmware the fmac should come alive and deliver its
    # cfms normally -> real wlan0.
    usePoll = false;
  };

  onArm = pkgs.stdenv.hostPlatform.isAarch64;
in
{
  # WiFi diagnostics from the shell, on both cores.
  environment.systemPackages = [ pkgs.iw ];

  # Onboard AIC8800 is wired on the ARM core only (the SDIO host node + pwrseq in
  # the ARM DTS target it).
  hardware.firmware = lib.mkIf onArm [ firmware ];
  boot.extraModulePackages = lib.mkIf onArm [ driver ];
  boot.kernelModules = lib.mkIf onArm [
    "aic8800_bsp"
    "aic8800_fdrv"
  ];
}
