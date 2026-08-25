# AICSemi AIC8800D80 SDIO WiFi kernel modules for the Milk-V Duo S.
#
# Source: github.com/radxa-pkg/aic8800. Build the SDIO fullMAC modules only:
#   aic8800_bsp    SDIO probe and firmware download.
#   aic8800_fdrv   fullMAC netdev (wlan0).
#   aic8800_btlpm  BT UART line discipline. Built, but not used.
#
# kbuild runs against the aic8800/ tree. The radxa series covers kernels 6.1 to
# 6.19. Two gaps remain at 7.1: the cfg80211 net_device to wireless_dev change
# (aic8800-linux-7.1-sdio.patch) and the removed <linux/of_gpio.h>.
#
# The driver loads firmware from a file path (CONFIG_USE_FW_REQUEST=n). Set
# CONFIG_AIC_FW_PATH to the NixOS runtime firmware tree.
{
  pkgs,
  kernel,
  src,
  fwPath ? "/run/current-system/firmware/aic8800_fw/SDIO/aic8800D80",
  # cv18xx SDIO RX poll. Use it if the host does not deliver the in-band
  # interrupt. Off: mainline dwcmshc with cap-sdio-irq delivers it.
  usePoll ? false,
  # Skip the experimental patches. Build a stock radxa driver with the firmware
  # path change only.
  stock ? false,
}:
let
  driverSubdir = "src/SDIO/driver_fw/driver/aic8800";

  # kbuild takes ARCH from the build host by default, which breaks the RISC-V
  # cross build. Derive it from the target kernel. linuxArch is "arm64" or
  # "riscv". crossPrefix is "" for a native build, or the cross prefix.
  inherit (pkgs.stdenv.hostPlatform) linuxArch;
  crossPrefix = pkgs.stdenv.cc.targetPrefix;
  # radxa series patches, in series order, that apply to the SDIO tree. Apply them
  # here (--binary keeps the tree CRLF). Skip the three USB-only patches; they
  # fail on CRLF in USB files that this build does not use.
  seriesPatches = [
    "fix-sdio-firmware-path.patch"
    "fix-sdio-fall-through.patch"
    "fix-linux-6.1-build.patch"
    "fix-linux-6.7-build.patch"
    "fix-linux-6.5-build.patch"
    "fix-linux-6.9-build.patch"
    "fix-linux-6.13-build.patch"
    "fix-linux-6.14-build.patch"
    "fix-linux-6.15-build.patch"
    "fix-linux-6.16-build.patch"
    "fix-linux-6.17-build.patch"
    "fix-linux-6.19-build.patch"
    "fix-vmalloc-not-include.patch"
    "fix-build-on-low-memory-devices.patch"
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "aic8800-sdio";
  version = "6.4.3.0-unstable-2026-06-20-${kernel.version}";

  inherit src;

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # Apply the radxa series, the SDIO 7.1 fix, then the local patches. Two changes
  # stay as substituteInPlace: the firmware path uses a nix variable, and the
  # of_gpio.h removal deletes one line.
  postPatch = ''
    for p in ${pkgs.lib.concatStringsSep " " seriesPatches}; do
      patch -p1 --binary -i "debian/patches/$p"
    done
    patch -p1 --binary -i ${./aic8800-linux-7.1-sdio.patch}

    # Set the firmware path to the NixOS runtime tree.
    substituteInPlace ${driverSubdir}/aic8800_bsp/Makefile \
      --replace-fail '"/lib/firmware/aic8800_fw/SDIO/aic8800D80"' '"${fwPath}"'

    # Use the BT-coex firmware, not the wifi-only one. The combo chip stages the
    # BT patch tables, so the wifi-only image is inconsistent and stops after the
    # jump (chip_id=0, "cmd queue crashed").
    substituteInPlace ${driverSubdir}/aic8800_bsp/aic_bsp_main.c \
      --replace-fail '"fmacfw_8800d80_u02.bin"' '"fmacfwbt_8800d80_u02.bin"'

    # Add the mmc headers and the CVITEK enumeration.
    patch -p1 --binary -i ${./aic8800-mmc-sdio-headers.patch}
    patch -p1 --binary -i ${./aic8800-cvitek-sdio-enum.patch}

    # Kernel 6.16 removed <linux/of_gpio.h>. rfkill.c is the only btlpm file built
    # and does not use it, so delete the include.
    substituteInPlace ${driverSubdir}/aic8800_btlpm/rfkill.c \
      --replace-fail '#include <linux/of_gpio.h>
' ""

    ${pkgs.lib.optionalString usePoll ''
      ${pkgs.buildPackages.python3}/bin/python3 ${./aic8800-cv18xx-poll.py}
    ''}

    # Experimental patches. Skip them with stock.
    ${pkgs.lib.optionalString (!stock) ''
      patch -p1 --binary -i ${./aic8800-drop-user-ext-flags.patch}
      patch -p1 --binary -i ${./aic8800-patch-buffer-reloc.patch}
      patch -p1 --binary -i ${./aic8800-fix6-nonblocking-startapp.patch}
      # CONFIG_AMSDU_RX=n stops the {0x170, ...} firmware patch-table write.
      substituteInPlace ${driverSubdir}/aic8800_bsp/Makefile \
        --replace-fail 'CONFIG_AMSDU_RX = y' 'CONFIG_AMSDU_RX = n'
    ''}
  '';

  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)/${driverSubdir}"
    "ARCH=${linuxArch}"
    "CROSS_COMPILE=${crossPrefix}"
    # cvi_get_wifi_pwr_on_desc() and cvi_sdio_rescan() come from the sdhci-cv181x
    # graft, so modpost cannot see them. Warn, do not fail. A softdep loads
    # sdhci-cv181x before aic8800_bsp.
    "KBUILD_MODPOST_WARN=1"
    "modules"
  ];

  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/net/wireless/aic8800"
    mkdir -p "$instdir"
    for ko in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
      install -p -m 0644 ${driverSubdir}/$ko/$ko.ko "$instdir/"
    done

    # Remove the embedded kernel.dev path so the linux-dev package stays out of the
    # runtime closure. The badge has little RAM and updates over the network.
    for ko in "$instdir"/*.ko; do
      ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to -t ${kernel.dev} "$ko"
    done
    runHook postInstall
  '';

  # The *.ko files are pre-stripped. Let the kmod hooks handle them.
  dontStrip = true;

  meta = {
    description = "AICSemi AIC8800D80 SDIO WiFi out-of-tree kernel modules";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
