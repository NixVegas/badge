# Board-common config for the Milk-V Duo S (Sophgo SG2000).
# Shared by both the ARM and RISC-V core configs. The genuinely
# per-core bits (DTB name, firmware packaging) live in core-*.nix.
{ pkgs, lib, config, ... }:
{
  config = lib.mkMerge [
    # --- Shared, arch-agnostic board config ---
    {
      # Mainline-first on both cores. The SG2000 is well supported on arm64 and
      # riscv64 in mainline (SoC dtsi in tree), so we run a stock mainline kernel
      # and avoid vendor patches. Onboard AIC8800 SDIO wifi is brought up ON
      # mainline via two small targeted patches to the kernel's OWN cv18xx SDIO
      # glue (see the aarch64 branch below), NOT the vendor 5.10 kernel or the
      # whole-driver graft.
      boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

      # The SG2000 uses the standard DesignWare UART. Same console node
      # regardless of which core boots, so it stays here, not in core-*.nix.
      boot.kernelParams = [ "console=ttyS0,115200" "earlycon" ];

      # Boot via U-Boot's extlinux. The vendor FSBL still runs first and is
      # packaged per-core in core-*.nix (ATF for ARM, OpenSBI for RISC-V).
      boot.loader.grub.enable = false;
      boot.loader.generic-extlinux-compatible.enable = true;

      hardware.deviceTree.enable = true;

      # SPI3 drives the WS2812 LED ring through spidev (see modules/duo-s/leds.nix).
      # nixpkgs leaves SPIDEV off and builds the DesignWare SPI glue as modules.
      # The LED service starts in the initrd, so we build all of it in (=y) and
      # avoid module load ordering that early. Without SPIDEV the spidev@0 node
      # in the DTS binds nothing and /dev/spidev3.0 never appears.
      boot.kernelPatches = [
        {
          name = "enable-spidev-for-leds";
          patch = null;
          # The Kconfig symbol is SPI_SPIDEV, not SPIDEV. The module file is
          # spidev.c, which is what makes the short name look right.
          # NOTE: no DMA here on purpose. SPI3 runs in PIO, which stalls a
          # little (a 417 byte LED frame took 1481 us against 1067 us of real
          # bit time) and makes fast animations flicker. Wiring the SPI3 DMA
          # was tried and REVERTED: the mainline dw-axi-dmac programs its
          # handshake number through an apb_regs window that only exists for
          # compatibles with AXI_DMA_FLAG_HAS_APB_REGS, which
          # snps,axi-dma-1.01a is not, so every slave transfer failed with
          # "apb_regs not initialized". dw_spi retried per frame, flooding the
          # console and starving the SD probe until the board would not boot.
          # See the NO DMA comment on spi3 in the device trees.
          extraConfig = ''
            SPI y
            SPI_DESIGNWARE y
            SPI_DW_MMIO y
            SPI_SPIDEV y
          '';
        }
      ];
    }

    # --- The only legitimate in-module arch fork: ISA-only differences with
    # no separate file of their own. hostPlatform is the single source of
    # truth, no redundant option needed. ---
    (lib.mkIf pkgs.stdenv.hostPlatform.isRiscV64 {
      # RISC-V-specific tweaks go here as we discover them.
    })
    (lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 {
      # ARM core: stock mainline kernel + two targeted patches to the mainline
      # cv18xx SDIO glue so the onboard AIC8800D80 wifi comes up. These are the
      # distilled delta of a vendor/mainline bisect (see memory
      # duos-vendor-kernel-plan), NOT the whole vendor driver graft:
      #
      #   cv18xx-vsw.patch      hooks the mainline .init/.postinit/.voltage_switch
      #                         slots (already called for rk35xx/th1520) for the
      #                         SD1/SDIO instance: sets reg_0x200[16] instance
      #                         select + [8]/[9] reset-out, drives the SoC pad
      #                         rail to a real 1.8V (SD_PWRSW_CTRL=0xB) which
      #                         mainline never does, forces 1.8V signalling, and
      #                         caps the link at SDR25 (mainline SDR104 PHY is
      #                         incomplete). Gated on the DTS "sophgo,sdio-inst1".
      #   mmc-no-async-irq.patch keeps the SDIO 3.0 card in NORMAL in-band IRQ
      #                         mode. Mainline auto-enables the ASYNC irq (EAI)
      #                         once the 1.8V switch succeeds, but sdhci/dwcmshc
      #                         has no async delivery path, so the fmac START_APP
      #                         confirm interrupt is dropped in clock-gated idle.
      boot.kernelPatches = [
        {
          name = "cv18xx-sdio-voltage-switch";
          patch = ../../pkgs/firmware/cv18xx-vsw.patch;
        }
        {
          name = "mmc-no-async-sdio-irq";
          patch = ../../pkgs/firmware/mmc-no-async-irq.patch;
        }
        # Enable the DesignWare watchdog so userspace `reboot` actually resets
        # the SoC. Mainline registers no working restart handler for the SG2000
        # (the /psci SYSTEM_RESET path hits a BL31 blob that does not implement
        # it, so machine_restart() spins after "reboot: Restarting system").
        # dw_wdt registers a restart handler at priority 128; combined with the
        # &soc watchdog@3010000 node in sg2000-milkv-duo-s.dts (and the FSBL's
        # RTC_EN_WDT_RST_REQ gate at 0x050260E0), a watchdog timeout resets the
        # whole chip. Built in (=y) so the handler is present without a module
        # load. The Kconfig symbol is DW_WATCHDOG (the driver file is dw_wdt.c);
        # it selects WATCHDOG_CORE, we keep WATCHDOG on explicitly.
        {
          name = "enable-dw-wdt-reboot";
          patch = null;
          extraConfig = ''
            WATCHDOG y
            WATCHDOG_CORE y
            DW_WATCHDOG y
          '';
        }
        # reset-simple drives sophgo,cv1800b-reset (the SG2000 reset controller).
        # nixpkgs' arm64 config leaves it off; without it SPI3 (and any resettable
        # peripheral) is stuck held-in-reset. See the DTS reset-controller@3003000.
        {
          name = "enable-reset-simple";
          patch = null;
          extraConfig = ''
            RESET_CONTROLLER y
            RESET_SIMPLE y
          '';
        }
      ];

      # The DW_WATCHDOG restart handler (above) resets via the watchdog, but the
      # reset actually fires through systemd's reboot-safety watchdog, whose
      # request is clamped to the hw max (~42s) - so `reboot` took ~40s. Arm it
      # short so the reset fires in ~2s. (The dw_wdt in-kernel restart path does
      # not reset promptly on this SoC; the systemd watchdog does.)
      systemd.watchdog.rebootTime = "2s";

      # Auto-recover from a hard hang (e.g. an aic8800 driver IRQ storm that
      # starves the serial getty so no `reboot` can be typed): systemd pings the
      # hw watchdog every runtimeTime/2; if PID1 is starved past runtimeTime the
      # watchdog fires and resets the SoC on its own. Essential for unattended
      # wifi-driver iteration.
      systemd.watchdog.runtimeTime = "20s";

      # Out-of-tree VENDOR cvitek cv181x SDHCI host driver, bound to the wifi
      # SDIO host mmc@4320000 via its DTS compatible "cvitek,cv181x-sdio" (see
      # the DTS &sdhci1 override). Replaces mainline sdhci-of-dwcmshc for that
      # one node so the AIC8800 fmac gets the exact vendor SDIO bring-up. The
      # rootfs SD/eMMC hosts keep using mainline dwcmshc. cv18xx-vsw.patch above
      # is now inert for the wifi node (dwcmshc no longer matches it) but stays
      # to avoid a kernel rebuild.
      boot.extraModulePackages = [
        (import ../../pkgs/firmware/sdhci-cv181x.nix {
          inherit pkgs;
          kernel = config.boot.kernelPackages.kernel;
        })
      ];
      boot.kernelModules = [ "sdhci-cv181x" ];
    })
  ];
}
