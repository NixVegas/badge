# Out-of-tree port of the VENDOR (Sophgo/CVITEK) SDHCI host controller driver
# for the CV181x / SG2000, built against the mainline kernel.
#
# Why: the AIC8800D80 SDIO WiFi downloads + enumerates fine on mainline's
# sdhci-of-dwcmshc cv18xx path, but the fmac firmware never comes alive after
# DBG_START_APP - a wall that WORKS on the vendor 5.10 kernel. Rather than keep
# cherry-picking register deltas onto mainline dwcmshc (cv18xx-vsw.patch), we run
# the vendor's whole custom SDHCI driver out-of-tree (same philosophy as the
# already-out-of-tree aic8800 driver), so the exact vendor behaviour (SD1
# instance select, 1.8V pwrsw flow, ADMA/64-bit-off quirks, f_src clock model,
# rich tap tuning, cvi_sdio_rescan export) is reproduced as a coherent whole.
#
# Source: github.com/sophgo/linux_5.10 sg200x-dev drivers/mmc/host/cvitek/
# (sdhci-cv181x.{c,h}), vendored in ./sdhci-cv181x/ with 7.0.12 API shims:
#   - vendored private sdhci.h / sdhci-pltfm.h / sdhci-cqhci.h from 7.0.12
#   - dropped the procfs stats block (needed core/card.h internals) and the
#     removable-card CD machinery (private struct mmc_gpio, of_get_named_gpio)
#   - f_src -> f_max (Sophgo mmc_host field), platform_driver.remove -> void,
#     sdhci_pltfm_free -> devm, and local defines for the Sophgo-core-only
#     SDHCI_QUIRK2_{RX,TX}_PHASE_FORWARD / SDHCI_ERR_INT_STATUS / dropped the
#     sdhci_ops.select_drive_strength member (not in mainline sdhci_ops).
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
