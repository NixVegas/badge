# The Sophgo/CVITEK vendor Linux 5.10 kernel for the Milk-V Duo S (SG2000 /
# cv181x), ARM64. We pivot to this because the AIC8800 SDIO wifi firmware will
# not run on mainline (exhaustively proven: even a full vendor-host-driver graft
# left the fmac silent post-jump). The vendor tree carries the ENTIRE wifi stack
# in-tree: aic8800 (drivers/net/wireless/aicsemi/aic8800), sdhci-cv181x
# (drivers/mmc/host/cvitek), and the wifi-pin power driver (drivers/soc/cvitek).
{
  lib,
  fetchFromGitHub,
  linuxManualConfig,
  runCommand,
  buildPackages,
  ...
}@args:
let
  src = fetchFromGitHub {
    owner = "sophgo";
    repo = "linux_5.10";
    rev = "eef0cf753007de989eeb1841d423a91dd74fd3ba";
    hash = "sha256-z8nKDQkkSLNjYeY0NtUSFt46fSBAYWUrF3ugr5zqE/s=";
  };

  # The board defconfig is minimal; merge in the NixOS/systemd-required options
  # and expand to a full .config. Done in a derivation so we get the kernel build
  # tools without fighting the host toolchain.
  configfile = runCommand "duos-vendor-kernel-config" {
    nativeBuildInputs = with buildPackages; [ gnumake bison flex bc gcc perl gawk ];
  } ''
    cp -r ${src} ksrc
    chmod -R +w ksrc
    cd ksrc
    # The kconfig preprocessor runs helper scripts (ld-version.sh is awk, etc);
    # rewrite their /usr/bin shebangs to the sandbox interpreters.
    patchShebangs scripts
    cp ${./board_defconfig} arch/arm64/configs/duos_defconfig
    make ARCH=arm64 duos_defconfig
    bash ./scripts/kconfig/merge_config.sh -m .config ${./nixos-extra.config}
    make ARCH=arm64 olddefconfig
    cp .config $out
  '';
in
(linuxManualConfig ({
  version = "5.10.4";
  modDirVersion = "5.10.4";
  inherit src configfile;
  allowImportFromDerivation = true;

  # Backport the tmpfs `noswap` mount option (mainline 6.4) to 5.10. Modern
  # systemd (260) sets up every service's credentials store with
  # fsconfig(FSCONFIG_SET_FLAG, "noswap"); on a kernel whose shmem does not
  # know that option the fsconfig returns EINVAL and systemd aborts at "step
  # CREDENTIALS", taking journald/tmpfiles/udev and the whole boot down with
  # it. This teaches 5.10 shmem to parse and honor `noswap` so credentials
  # mount succeeds. The board has no swap, so it is effectively a no-op at
  # runtime, but the flag is wired through for correctness.
  kernelPatches = [
    {
      name = "shmem-noswap-backport";
      patch = ./shmem-noswap.patch;
    }
  ];
}
# linuxPackagesFor / the NixOS kernel module re-invoke this with hardening args
# (features, randstructSeed); forward them so .override keeps working.
// lib.optionalAttrs (args ? features) { inherit (args) features; }
// lib.optionalAttrs (args ? randstructSeed) { inherit (args) randstructSeed; })).overrideAttrs
  (old: {
    # Stage the vendor DTS chain (the kernel tree gitignores arch/.../dts/cvitek
    # contents; the SDK copies them in at build time) + register the board dtb.
    postPatch =
      (old.postPatch or "")
      + ''
        cp ${./dts}/cv181x_base.dtsi \
           ${./dts}/cv181x_base_arm.dtsi \
           ${./dts}/cv181x_asic_bga.dtsi \
           ${./dts}/cv181x_asic_sd.dtsi \
           ${./dts}/cv181x_default_memmap.dtsi \
           ${./dts}/cvi_board_memmap.h \
           arch/arm64/boot/dts/cvitek/
        cp ${./dts}/board.dts \
           arch/arm64/boot/dts/cvitek/sg2000_milkv_duos_glibc_arm64_sd.dts
        echo 'dtb-$(CONFIG_ARCH_CV181X) += sg2000_milkv_duos_glibc_arm64_sd.dtb' \
           >> arch/arm64/boot/dts/cvitek/Makefile
        # spacc_test is a vendor crypto test built as a -static target userspace
        # program (userprogs-always-y); it cannot link in a kernel-only build
        # (no target libc). Drop it -- we do not need the spacc crypto for wifi.
        sed -i '/spacc_test/d' drivers/crypto/Makefile
        # The vendor bolts dc8000-fb.o onto the CONFIG_FB_SIMPLE Makefile line (no
        # symbol of its own); it uses dma_alloc/free_writecombine, removed from
        # 5.10, so it fails to link. Remove just that object (keep simplefb).
        sed -i 's/ dc8000-fb\.o//' drivers/video/fbdev/Makefile
        # BADGE: disable Bluetooth so aicbt_init() is skipped. For the D80 the
        # driver hardcodes btenable=1 (aic_bsp_driver.c:1924), so it runs the BT
        # patch loader (aicbt_patch_table_load) which OOPSes on this fw with a bad
        # PC (0x20b43c... IABT) one step before the wifi START_APP. We only need
        # wifi (the sophgo default is BT-off, wifi-only fmacfw anyway); with
        # btenable=0 aicbsp_driver_fw_init skips aicbt_init (guarded by
        # `if (btenable == 1)` at :1938) and goes straight to aicwifi_init.
        substituteInPlace drivers/net/wireless/aicsemi/aic8800/aic8800_bsp/aic_bsp_driver.c \
          --replace 'btenable = 1;' 'btenable = 0;'
      '';
    # 5.10.4 cvitek drivers were written for GCC 7 and do not build clean on
    # modern GCC, which promotes several old-code patterns to hard errors.
    # Downgrade them to warnings so the tree compiles.
    makeFlags = (old.makeFlags or [ ]) ++ [
      ("KCFLAGS=-Wno-error"
        + " -Wno-error=implicit-function-declaration"
        + " -Wno-error=incompatible-pointer-types"
        + " -Wno-error=int-conversion"
        + " -Wno-error=discarded-qualifiers"
        + " -Wno-error=stringop-overflow"
        + " -Wno-error=array-bounds")
    ];
  })
