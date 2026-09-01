# Board-common config for the Milk-V Duo S (Sophgo SG2000).
# Shared by both the ARM and RISC-V core configs. The per-core
# parts (DTB name, firmware packaging) live in core-*.nix.
{ pkgs, lib, config, ... }:
{
  config = lib.mkMerge [
    # --- Shared, arch-agnostic board config ---
    {
      # The SG2000 is supported on arm64 and riscv64 in mainline (SoC dtsi in
      # tree). Both cores run a mainline kernel. The AIC8800 SDIO wifi comes up
      # on mainline through two targeted patches to the kernel's cv18xx SDIO
      # glue (see the aarch64 branch below).
      boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

      # The SG2000 uses the standard DesignWare UART. Same console node
      # regardless of which core boots, so it stays here, not in core-*.nix.
      # iomem=relaxed disables IO_STRICT_DEVMEM's "busy region" denial (the
      # kernel otherwise EPERMs /dev/mem access to any MMIO range a driver has
      # claimed). Needed so `nix-badge mmio` can poke SoC registers during
      # bring-up -- e.g. sweeping the SAO IIC1 pinmux (claimed by 3001000.pinctrl)
      # while hunting the OLED's 0x3c ACK. Parsed generically in kernel/resource.c
      # (arch-independent). Root-only; fine for a hacker badge.
      # fbcon=rotate:2: the Sharp fbcon panel (#42) is mounted upside down, so
      # rotate the console 180 in fbcon (CONFIG_FRAMEBUFFER_CONSOLE_ROTATION)
      # rather than in the driver. console=ttyS0 stays the primary (kernel log +
      # serial recovery); the fb VT (tty1) gets its own getty below.
      boot.kernelParams = [
        # console=tty1 FIRST so kernel + systemd boot messages also render on
        # the Sharp fbcon panel (#42) -- otherwise fbcon has nothing to show and
        # DEFERRED_TAKEOVER holds off until the getty writes ~2min in. ttyS0 is
        # LAST so it stays /dev/console (serial recovery + single-user land there).
        "console=tty1"
        "console=ttyS0,115200"
        "earlycon"
        "iomem=relaxed"
        "fbcon=rotate:2"
      ];

      # Boot via U-Boot's extlinux. The vendor FSBL still runs first and is
      # packaged per-core in core-*.nix (ATF for ARM, OpenSBI for RISC-V).
      boot.loader.grub.enable = false;
      boot.loader.generic-extlinux-compatible.enable = true;

      hardware.deviceTree.enable = true;


      # SPI3 drives the WS2812 LED ring through spidev (see modules/duo-s/bling.nix).
      # nixpkgs leaves SPIDEV off and builds the DesignWare SPI glue as modules.
      # The LED service starts in the initrd, so build all of it in (=y) to avoid
      # early module load ordering. Without SPIDEV the spidev@0 node in the DTS
      # binds nothing and /dev/spidev3.0 never appears.
      boot.kernelPatches = [
        {
          name = "enable-spidev-for-leds";
          patch = null;
          # The Kconfig symbol is SPI_SPIDEV, not SPIDEV. The module file is
          # spidev.c, which makes the short name look right. SPI3 drives the
          # WS2812 ring via slave DMA through the cv1800b dmamux (see the spi3
          # dmas / &dmac in the device trees); build the DesignWare SPI glue and
          # spidev in (=y) so /dev/spidev3.0 exists from the initrd, where the LED
          # service starts.
          extraConfig = ''
            SPI y
            SPI_DESIGNWARE y
            SPI_DW_MMIO y
            SPI_SPIDEV y
          '';
        }
        {
          # SPI3 slave DMA works through the cv1800b dmamux, but the dw-axi-dmac
          # driver still calls dw_axi_dma_set_hw_channel() on every transfer, and
          # on this SoC chip->apb_regs is NULL (the dmamux does the request
          # routing, so the DMAC's own apb_regs handshake is unused). That path is
          # a void no-op, but it logs dev_err("apb_regs not initialized") every
          # frame. With the LED painter running from the initrd that floods the
          # slow serial console and, at RT priority, starved the AIC8800 wifi
          # bring-up so the board came up with no network. Demote the message to
          # dev_dbg; the DMA transfer itself is unaffected.
          name = "dw-axi-dmac-apb-regs-quiet";
          patch = ../../pkgs/firmware/dw-axi-dmac-apb-regs-quiet.patch;
        }
        {
          # A failed dw-axi-dmac prep (e.g. an oversized/odd slave_sg) calls
          # axi_desc_put() over ALL nr_hw_descs entries, dma_pool_free()ing the
          # NULL llis of the never-populated tail -- a kernel NULL deref at
          # offset 8 that takes the SPI bus lock down with it (observed live: a
          # 3122-byte spidev write left every later SPI user in D-state until
          # reboot). Stop at the first NULL; entries are filled in order.
          name = "dw-axi-dmac-desc-put-null-guard";
          patch = ../../pkgs/kernel/patches/dw-axi-dmac-desc-put-null-guard.patch;
        }
        {
          # The SG2000's DW SSI is synthesized with ONE slave select: SER bits
          # above 0 don't exist, so a child at reg=<1> (the Sharp Memory Display
          # behind the CS inverter -- see the spi3 DTS) never clocks: the DMA
          # feeds a FIFO that never drains, times out at 200ms, and poisons the
          # channel. Device selection on this board is EXTERNAL anyway (AND gate
          # high = LEDs, inverter low = display), so every child gets SER bit 0.
          name = "spi-dw-ser-bit0";
          patch = ../../pkgs/kernel/patches/spi-dw-ser-bit0.patch;
        }
        {
          # The Sharp Memory Display fbcon (#42). The mainline sharp-memory DRM
          # driver flushes the whole frame (up to 12.5 KB) in ONE spi_write --
          # a single transfer that (a) needs a multi-block dw-axi-dmac descriptor
          # (ENOMEMs here) and (b) releases the controller bus_lock_mutex the
          # moment it returns, so the userspace WS2812 painter (spidev, sharing
          # SPI3 + the CS net) can slip a frame in and drive the shared CS high
          # mid-flush, corrupting the panel. Rework the flush into ONE
          # spi_message of <=512 B transfers: single-block DMA each, and the one
          # message holds bus_lock_mutex for the whole write so the painter
          # blocks until it completes. LEDs primary + a real fbcon, coexisting.
          name = "sharp-memory-chunk-flush";
          patch = ../../pkgs/kernel/patches/sharp-memory-chunk-flush.patch;
        }
        {
          # Enable the Sharp Memory LCD DRM driver (#42). =y (built-in): so it
          # probes during kernel init and fbcon (DEFERRED_TAKEOVER) grabs the
          # panel VT EARLY -- =m loaded so late that even the systemd boot
          # messages were missed. (A source change to the sharp-memory-* patch
          # rebuilds the whole kernel either way, so =m bought no iteration win.)
          # DRM/FB/FRAMEBUFFER_CONSOLE/FONT_8x16/VT and USB HID are already in the
          # base config, so the getty on tty1 + a keyboard give a text terminal.
          # Panel is mounted upside down -> fbcon=rotate:2 (boot.kernelParams).
          name = "enable-sharp-memory-drm";
          patch = null;
          extraConfig = ''
            DRM y
            TINYDRM_SHARP_MEMORY y
          '';
        }
        # NOTE: a sophgo-cv1800b-adc clkdiv/sample_window module-param patch was
        # tried here to fight the SARADC rail-reading attenuation, on the theory
        # that the ~688k divider undersettles the sample window. Live sweeps on
        # the badge DISPROVED it: raising clkdiv (slower ADC) LOWERS the reading,
        # and shortening sample_window RAISES it -- i.e. it is leakage-dominated,
        # not settling-dominated (the S/H cap bleeds toward a low equilibrium set
        # by the ~138k leaky ADC input). The stock config (clkdiv=1,
        # sample_window=15) already gives the most stable reading; a shorter
        # window buys less attenuation but far more jitter, so with median
        # smoothing it is no better. The real fix is a hardware buffer cap on the
        # divider (a bench mod), not a driver knob. So no ADC patch: nix-badge's
        # empirical factor (~19) on the stock timing is as good as software gets.
      ];
    }

    # --- In-module arch fork for ISA-only differences with no separate file.
    # hostPlatform is the single source of truth. ---
    (lib.mkIf pkgs.stdenv.hostPlatform.isRiscV64 {
      # RISC-V-specific config goes here.
    })
    (lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 {
      # ARM core: mainline kernel plus two targeted patches to the mainline
      # cv18xx SDIO glue so the onboard AIC8800D80 wifi comes up:
      #
      #   cv18xx-vsw.patch      hooks the mainline .init/.postinit/.voltage_switch
      #                         slots (already called for rk35xx/th1520) for the
      #                         SD1/SDIO instance: sets reg_0x200[16] instance
      #                         select + [8]/[9] reset-out, drives the SoC pad
      #                         rail to a real 1.8V (SD_PWRSW_CTRL=0xB) which
      #                         mainline does not, forces 1.8V signalling, and
      #                         caps the link at SDR25 (mainline SDR104 PHY is
      #                         incomplete). Gated on the DTS "sophgo,sdio-inst1".
      #   mmc-no-async-irq.patch keeps the SDIO 3.0 card in normal in-band IRQ
      #                         mode. Mainline auto-enables the async IRQ (EAI)
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
        # Enable the DesignWare watchdog so userspace `reboot` resets the SoC.
        # Mainline registers no working restart handler for the SG2000: the
        # /psci SYSTEM_RESET path hits a BL31 blob that does not implement it,
        # so machine_restart() spins after "reboot: Restarting system".
        # dw_wdt registers a restart handler at priority 128. With the &soc
        # watchdog@3010000 node in sg2000-milkv-duo-s.dts and the FSBL's
        # RTC_EN_WDT_RST_REQ gate at 0x050260E0, a watchdog timeout resets the
        # whole chip. Built in (=y) so the handler is present without a module
        # load. The Kconfig symbol is DW_WATCHDOG (the driver file is dw_wdt.c).
        # It selects WATCHDOG_CORE; keep WATCHDOG on explicitly.
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
        # The nixpkgs arm64 config leaves it off. Without it SPI3 and any
        # resettable peripheral stay held in reset. See the DTS
        # reset-controller@3003000.
        {
          name = "enable-reset-simple";
          patch = null;
          extraConfig = ''
            RESET_CONTROLLER y
            RESET_SIMPLE y
          '';
        }
      ];

      # The reset fires through systemd's reboot-safety watchdog. Its request is
      # clamped to the hardware max (~42s), so `reboot` takes ~40s by default.
      # Arm it short so the reset fires in ~2s. The dw_wdt in-kernel restart
      # path does not reset promptly on this SoC; the systemd watchdog does.
      systemd.watchdog.rebootTime = "2s";

      # Auto-recover from a hard hang (for example an aic8800 driver IRQ storm
      # that starves the serial getty so no `reboot` can be typed). systemd pings
      # the hardware watchdog every runtimeTime/2. If PID1 is starved past
      # runtimeTime the watchdog fires and resets the SoC.
      systemd.watchdog.runtimeTime = "20s";

      # Out-of-tree cvitek cv181x SDHCI host driver, bound to the wifi SDIO host
      # mmc@4320000 through its DTS compatible "cvitek,cv181x-sdio" (see the DTS
      # &sdhci1 override). It replaces mainline sdhci-of-dwcmshc for that one node
      # so the AIC8800 fmac gets the vendor SDIO bring-up. The rootfs SD/eMMC
      # hosts keep using mainline dwcmshc. cv18xx-vsw.patch above is now inert for
      # the wifi node (dwcmshc no longer matches it) but stays to avoid a kernel
      # rebuild.
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
