# Vendor firmware blobs for the AICSemi AIC8800D80 SDIO WiFi chip.
#
# The out-of-tree aic8800 driver does NOT use request_firmware() (the SDIO
# build sets CONFIG_USE_FW_REQUEST = n in its top Makefile). Instead both the
# bsp and fdrv modules do a literal filp_open("<CONFIG_AIC_FW_PATH>/<name>").
# So the firmware is loaded by absolute path, not via the kernel firmware
# loader's /lib/firmware search.
#
# We install the D80 blobs under lib/firmware/aic8800_fw/SDIO/aic8800D80/,
# mirroring the radxa Debian layout (debian/aic8800-firmware.install copies
# src/SDIO/driver_fw/fw/* -> /lib/firmware/aic8800_fw/SDIO/). On NixOS this
# derivation is wired via hardware.firmware, so the files end up at
#   ${config.hardware.firmware}/lib/firmware/aic8800_fw/SDIO/aic8800D80/...
# and the stable runtime symlink /run/current-system/firmware points at that
# tree. The driver is compiled (see aic8800.nix) with
#   CONFIG_AIC_FW_PATH = /run/current-system/firmware/aic8800_fw/SDIO/aic8800D80
# so the filp_open path resolves on a running NixOS system.
{ pkgs, src }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "aic8800-firmware";
  version = "6.4.3.0-unstable-2026-06-20";

  inherit src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    dst="$out/lib/firmware/aic8800_fw/SDIO"
    mkdir -p "$dst"
    cp -r src/SDIO/driver_fw/fw/aic8800D80 "$dst/aic8800D80"
    chmod -R u+w "$dst/aic8800D80"

    # Overlay the EXACT firmware the working Duo S Debian image uses:
    # firmware-aic8800-cv181x 2024.10.14-2 (scpcom sophgo-sg200x-debian, the
    # known-good vendor-5.10 setup). Its blobs use the same filenames the radxa
    # driver loads but are a DIFFERENT, cv181x-correct build:
    #   fmacfw_8800d80_u02.bin md5 4062b3a3 (vs radxa's, vs the milkv-buildroot
    #   13e6f0e5 we tried before -- three distinct builds of the "same" file).
    # The radxa/milkv fmac builds upload clean but never confirm START_APP on
    # this chip; this is the matched cv181x set. (milkv-fw/ kept for reference.)
    cp -f ${./debian-fw}/* "$dst/aic8800D80/"
    runHook postInstall
  '';

  # NixOS's hardware.firmware path compresses every blob with zstd, because the
  # kernel's request_firmware() transparently decompresses .zst. This driver
  # does NOT use request_firmware(); it does a literal filp_open() of the bare
  # ".bin" name, so a compressed "...bin.zst" on disk fails to open. Opt this
  # package out of compression (udev.nix checks `firmware.compressFirmware or
  # true`) so the blobs stay at their literal filenames.
  passthru.compressFirmware = false;

  meta = {
    description = "AICSemi AIC8800D80 SDIO WiFi vendor firmware blobs";
    license = pkgs.lib.licenses.unfreeRedistributableFirmware;
  };
}
