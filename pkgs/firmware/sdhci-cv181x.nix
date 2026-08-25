# Out-of-tree port of the vendor (Sophgo/CVITEK) SDHCI host controller driver
# for the CV181x / SG2000, built against the mainline kernel.
#
# The mainline sdhci-of-dwcmshc cv18xx path downloads and enumerates the
# AIC8800D80 SDIO WiFi. The fmac firmware then fails to start after
# DBG_START_APP. The vendor 5.10 kernel works. This driver runs the vendor's
# custom SDHCI driver out-of-tree instead of porting register deltas onto
# mainline dwcmshc. The full vendor behaviour is reproduced as a whole: SD1
# instance select, 1.8V power-switch flow, ADMA/64-bit-off quirks, f_src clock
# model, tap tuning, and the cvi_sdio_rescan export.
#
# Source: github.com/sophgo/linux_5.10 sg200x-dev drivers/mmc/host/cvitek/
# (sdhci-cv181x.{c,h}), vendored in ./sdhci-cv181x/ with 7.0.12 API shims:
#   - vendored private sdhci.h / sdhci-pltfm.h / sdhci-cqhci.h from 7.0.12
#   - dropped the procfs stats block (needs core/card.h internals) and the
#     removable-card CD machinery (private struct mmc_gpio, of_get_named_gpio)
#   - f_src -> f_max (Sophgo mmc_host field), platform_driver.remove -> void,
#     sdhci_pltfm_free -> devm, and local defines for the Sophgo-core-only
#     SDHCI_QUIRK2_{RX,TX}_PHASE_FORWARD / SDHCI_ERR_INT_STATUS
#   - dropped the sdhci_ops.select_drive_strength member (not in mainline
#     sdhci_ops).
{
  pkgs,
  kernel,
}:
pkgs.stdenv.mkDerivation {
  pname = "sdhci-cv181x";
  version = "vendor-5.10-unstable-${kernel.version}";

  src = ./sdhci-cv181x;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  inherit (pkgs.stdenv.hostPlatform) linuxArch;
  crossPrefix = pkgs.stdenv.cc.targetPrefix;

  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)"
    "ARCH=${pkgs.stdenv.hostPlatform.linuxArch}"
    "CROSS_COMPILE=${pkgs.stdenv.cc.targetPrefix}"
    "modules"
  ];

  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/mmc/host"
    mkdir -p "$instdir"
    install -p -m 0644 sdhci-cv181x.ko "$instdir/"
    ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to -t ${kernel.dev} "$instdir/sdhci-cv181x.ko"
    runHook postInstall
  '';

  dontStrip = true;

  meta = {
    description = "Out-of-tree CVITEK cv181x SDHCI host driver for mainline (WiFi SDIO bring-up)";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
