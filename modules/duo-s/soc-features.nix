# Sophgo CV1800/SG2000 SoC peripheral drivers ported from Armbian's
# sophgo-sg200x-7.2 patch series (armbian/build#10326). These are cherry-picks
# of pending-LKML work that is NOT yet in mainline 7.2, so they apply as source
# patches on top of linuxPackages_latest and add drivers our kernel otherwise
# lacks. The board runs the SAME mainline 7.2 as Armbian, so every patch below
# applies verbatim to both the ARM and RISC-V kernels; each driver gates on
# `depends on ARCH_SOPHGO`, which both cores satisfy.
#
# See docs/armbian-sg2000-pr10326-gap.md for the gap analysis. This module
# carries the DRIVER + binding patches (what makes the kernel *build* with these
# features); the matching device-tree NODES that make the drivers actually bind
# live in our own board DTS under pkgs/firmware/dts/ -- the DTB is compiled from
# kernel.src (unpatched), so DTS hunks in these patches would never reach it.
#
# Patch provenance (Armbian sophgo-sg200x-7.2, author Lukasz Sobala et al.):
#   0007/0008  thermal: cv1800 SoC temperature sensor            -> CV1800_THERMAL
#   0010/0012  net: Sophgo CV1800 MDIO multiplexer               -> MDIO_BUS_MUX_SOPHGO_CV1800B
#   0019/0022  pwm: Sophgo CV1800 PWM                            -> PWM_CV1800
#   0021/0023/0037  remoteproc: C906L little-core controller     -> SOPHGO_CV1800B_C906L
#   0027/0028  nvmem: Sophgo eFuse (deterministic MAC from FTSN) -> NVMEM_SOPHGO_EFUSE
# 0028 is carried DRIVER-ONLY: its original form also adds an efuse node to the
# in-tree riscv cv180x.dtsi referencing CLK_EFUSE macros that may be undefined in
# mainline 7.2's clock header, which would break the kernel's own `make dtbs`.
# The efuse DT node is ported into our board DTS instead.
{ pkgs, lib, config, ... }:
let
  ap = ../../pkgs/kernel/patches/armbian;
in
{
  config = {
    boot.kernelPatches = [
      # --- device-tree binding docs (new files only; zero conflict risk) ---
      { name = "sophgo-thermal-binding";   patch = "${ap}/0007-dt-bindings-thermal-sophgo-cv1800-thermal-Add-Sophgo.patch"; }
      { name = "sophgo-mdio-mux-binding";  patch = "${ap}/0010-dt-bindings-net-Add-Sophgo-CV1800-MDIO-multiplexer.patch"; }
      { name = "sophgo-pwm-binding";       patch = "${ap}/0019-dt-bindings-pwm-sophgo-add-pwm-for-Sophgo-CV1800-ser.patch"; }
      { name = "sophgo-c906l-binding";     patch = "${ap}/0021-dt-bindings-remoteproc-Add-C906L-rproc-for-Sophgo-CV.patch"; }
      { name = "sophgo-efuse-binding";     patch = "${ap}/0027-dt-bindings-nvmem-Add-sophgo-efuses.patch"; }

      # --- drivers ---
      { name = "sophgo-cv1800-thermal";    patch = "${ap}/0008-thermal-cv1800-Add-cv1800-thermal-driver-support.patch"; }
      { name = "sophgo-cv1800-mdio-mux";   patch = "${ap}/0012-net-mdio-mux-Add-MDIO-mux-driver-for-Sophgo-CV1800-S.patch"; }
      { name = "sophgo-cv1800-pwm";        patch = "${ap}/0022-pwm-sophgo-add-pwm-support-for-Sophgo-CV1800-SoC.patch"; }
      { name = "sophgo-c906l-remoteproc";  patch = "${ap}/0023-drivers-remoteproc-Add-C906L-controller-for-Sophgo-C.patch"; }
      # 0037 fixes the probe function in the file 0023 creates -> must come after 0023.
      { name = "sophgo-c906l-remoteproc-probe-fix"; patch = "${ap}/0037-drivers-remoteproc-fix-C906L-probe-function.patch"; }
      { name = "sophgo-efuse-driver";      patch = "${ap}/0028-nvmem-Add-Sophgo-eFuse-driver-DRIVER-ONLY.patch"; }

      # --- config for the ported drivers + the USB-gadget / pstore items ---
      {
        name = "sophgo-soc-features-config";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          # Ported Sophgo SoC drivers (all gate on ARCH_SOPHGO, which both cores
          # set). Built as modules: proves they compile and makes them available
          # without forcing early built-in ordering. The device-tree nodes that
          # make them bind flow in through the DTB (built from the DTS-patched
          # kernel source -- see pkgs/firmware/duos-{arm,riscv}-dtb.nix).
          CV1800_THERMAL = module;
          PWM_CV1800 = module;
          SOPHGO_CV1800B_C906L = module;
          NVMEM_SOPHGO_EFUSE = module;
          # The MDIO mux driver `select`s MDIO_BUS_MUX; nixpkgs already pulls it in
          # built-in (=y) via another selector, so pin it =y to match (an =m child
          # can depend on a =y core).
          MDIO_BUS_MUX = yes;
          MDIO_BUS_MUX_SOPHGO_CV1800B = module;

          # USB CDC-NCM gadget (#46): badge-as-network-device over USB. All mainline
          # -- no driver patch, just the NCM composite function on top of the gadget
          # stack nixpkgs already ships (USB_GADGET=y, and dwc2 is ALREADY
          # USB_DWC2_DUAL_ROLE=y, so the DTS dr_mode = "otg"/"peripheral" overlay can
          # flip the port to peripheral). configfs stays available so a userspace
          # service can assemble the gadget at runtime. (The device-mode DTS overlay +
          # the configfs setup service are wired separately.)
          CONFIGFS_FS = yes;
          USB_CONFIGFS = module;
          USB_CONFIGFS_NCM = yes;

          # pstore/ramoops (#50): our kernel had PSTORE_RAM=m + PSTORE=y but no
          # console backend, so the continuously-written console ring was never
          # captured. Enable the console + pmsg backends so a reboot preserves the
          # tail of the kernel log (and userspace pmsg) in /sys/fs/pstore, matching
          # Armbian's ramoops setup. The region itself (0x90000000) is in the DTS.
          PSTORE_CONSOLE = yes;
          PSTORE_PMSG = yes;
        };
      }
    ];

    # Reboot panics through the NORMAL reset path instead of hanging until the
    # hardware watchdog trips. Armbian runs PANIC_TIMEOUT=10 for exactly this
    # reason: with panic_timeout=0 a panicking board sits wedged until dw_wdt
    # hard-resets it (~21s) -- a colder reset than a kernel-initiated one, and the
    # path least likely to leave the ramoops DRAM region intact for the next boot.
    boot.kernelParams = [ "panic=10" ];
  };
}
