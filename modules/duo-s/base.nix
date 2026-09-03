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
      # rather than in the driver.
      boot.kernelParams = [
        # /dev/console is the LAST console= entry. Put ttyS0 (the Husky serial
        # bridge -> ser2net) LAST so SERIAL is /dev/console: PID1's
        # "Starting/Started" status, the emergency/single-user shell, and the
        # console getty land on serial -- the practical default for a badge
        # debugged remotely over ser2net (systemd boot status shows up on the
        # tcp/3333 console). tty1 (the Sharp fbcon panel, #42) is still a
        # registered console, so it gets ALL kernel printk during boot and keeps
        # its own getty@tty1 login (enabled below); it just gives up the systemd
        # "Starting X" marquee, which moved to serial. earlycon keeps the very
        # early boot on serial too (the panel's DRM driver isn't up until ~6.3s).
        # (Earlier this was reversed -- panel as /dev/console -- but serial is
        # the more common debug path, so status belongs there.)
        "console=tty1"
        "console=ttyS0,115200"
        "earlycon"
        "iomem=relaxed"
        "fbcon=rotate:2"
        # Reserve a 16MB contiguous CMA pool for coherent DMA. The stmmac
        # ethernet (4070000.ethernet) allocates its TX/RX descriptor rings with
        # dma_alloc_coherent; without a reserved pool that alloc pulls from the
        # general allocator and FAILS occasionally under memory-pressure
        # fragmentation (late boot, once the fix Engines + wifi stack are up) ->
        # "stmmac_setup_dma_desc: DMA descriptors initialization failed" and eth0
        # dies (#15). CMA gives coherent DMA a reserved contiguous region so the
        # rings always allocate. 16MB is reclaimable for movable/cache pages when
        # not used for DMA, so it is not simply lost on the tight 351/512MB board.
        # Needs CONFIG_CMA + CONFIG_DMA_CMA (pinned below).
        "cma=16M"
      ];

      # Dress the fb console (#42) in Spleen -- the same family as the OLED
      # screens -- via setfont (applies to all VTs incl. the panel's tty1).
      # 6x12 = 66x20 on the 400x240 panel; 8x16 (50x15) is bigger, 5x8 (80x30)
      # denser. earlySetup runs the setfont in the INITRD, so tty1 already
      # carries Spleen before the Sharp fbcon binds it (~6.3s) -- otherwise the
      # panel came up in the built-in kernel font and visibly swapped to Spleen
      # only once systemd-vconsole-setup ran, seconds into userspace.
      console.font = "${pkgs.spleen}/share/consolefonts/spleen-6x12.psfu";
      console.earlySetup = true;

      # Serial (ttyS0) is /dev/console (above), so systemd's getty-generator
      # already spawns the console getty there (serial-getty@ttyS0) for remote
      # ser2net login (#11); keep it enabled explicitly so it survives regardless
      # of the generator. The PANEL (tty1) is no longer /dev/console, so it would
      # otherwise lose its login -- enable getty@tty1 explicitly so the Sharp
      # panel keeps an interactive shell (plus the kernel printk it gets as a
      # registered console). PID1 status + the emergency/single-user shell now
      # land on serial, not the panel.
      #
      # NOTE: do NOT wire journald ForwardToConsole to mirror the log onto the
      # other tty -- it streams the WHOLE journal forever and drowns the getty
      # (every session/service line interrupts the prompt). One /dev/console gets
      # the systemd status; the other tty stays a quiet getty + kernel printk.
      systemd.services."serial-getty@ttyS0".enable = true;
      systemd.services."getty@tty1".enable = true;

      # pstore/ramoops (#50): dump kernel oops/panic to the reserved DRAM region
      # (ramoops@88000000 in the shared dtsi) so a crash survives a reboot and
      # reads back from /sys/fs/pstore. PSTORE=y is already in the kernel and
      # PSTORE_RAM is =m; load the ramoops module from the INITRD so it registers
      # the kmsg dumper early enough to catch most panics (not just post-boot
      # ones). No kernel rebuild -- just the module + the DT node.
      boot.initrd.kernelModules = [ "ramoops" ];

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
          # Reserve CMA for coherent DMA (paired with the cma=16M kernelParam
          # above). CONFIG_CMA provides the contiguous allocator; CONFIG_DMA_CMA
          # is what makes dma_alloc_coherent actually draw from the default CMA
          # area. Without DMA_CMA the cma=16M pool is reserved but unused -- the
          # stmmac ethernet ring alloc still hits the general allocator and fails
          # under fragmentation (#15). Pin both =y so the bootarg hardens eth0.
          name = "enable-cma-for-coherent-dma";
          patch = null;
          extraConfig = ''
            CMA y
            DMA_CMA y
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
          # The Sharp Memory Display fbcon (#42). Two reworks of the mainline
          # sharp-memory DRM flush:
          #  1. PARTIAL-BAND flush. Mainline always spi_write's the whole
          #     tx_buffer (~12.5 KB) even for one dirty line, AND miscomputes the
          #     per-line address for a y1>0 clip (it counts addresses from row 0
          #     while the mono conversion compacts source rows y1..y2 to the top
          #     of dst -- so partial damage renders to the wrong lines: the
          #     corruption we saw). Fix the addressing to match the compacted
          #     data and transmit only the dirty band (mode byte + (y2-y1)*pitch),
          #     so a single-line scroll/cursor update sends ~pitch bytes, not 12 KB.
          #  2. CHUNKED PIO write. That transmit is split into ONE spi_message of
          #     <=spi_chunk-byte transfers (default 8): each stays on the reliable
          #     dw-spi PIO path (the dw-axi-dmac multi-block path "Tx hanged up"s
          #     here), and the single message holds the controller bus_lock_mutex
          #     for the whole write so the userspace WS2812 painter (spidev,
          #     sharing SPI3 + the CS net) can't drive the shared CS high
          #     mid-flush. LEDs primary + a real fbcon, coexisting.
          name = "sharp-memory-partial-flush";
          patch = ../../pkgs/kernel/patches/sharp-memory-partial-flush.patch;
        }
        {
          # Enable the Sharp Memory LCD DRM driver (#42). =y (built-in) so it
          # probes during kernel init (~7s). And DISABLE DEFERRED_TAKEOVER: with
          # it on, fbcon waited for the first text on tty1 before binding, but
          # that text had nowhere to render until a getty opened tty1 ~60-140s
          # in (a chicken-and-egg that console=tty1 alone can't break) -- so the
          # panel stayed blank through boot. =n makes fbcon bind the moment the
          # fbdev registers, so kernel + systemd boot messages render on the
          # panel from ~7s. (A source change to the sharp-memory-* patch rebuilds
          # the whole kernel either way, so =m bought no iteration win.)
          # DRM/FB/FRAMEBUFFER_CONSOLE/FONT_8x16/VT and USB HID are already in the
          # base config, so the getty on tty1 + a keyboard give a text terminal.
          # Panel is mounted upside down -> fbcon=rotate:2 (boot.kernelParams).
          name = "enable-sharp-memory-drm";
          patch = null;
          extraConfig = ''
            DRM y
            TINYDRM_SHARP_MEMORY y
            FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER n
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

    # --- SoC-level enablement shared by BOTH cores. ---
    # The SG2000 is ONE die: the SDIO wifi host, the cv1800b reset controller,
    # the DesignWare watchdog and the out-of-tree cvitek SDHCI host are the same
    # hardware blocks whichever core boots, so this is NOT arch-specific. It used
    # to be gated on isAarch64, which silently left the RISC-V build without wifi,
    # with a half-reset SPI3 (garbled LEDs + a dead Sharp panel), and only a lucky
    # DW_WATCHDOG=m from the riscv defconfig. Both cores run the same
    # linuxPackages_latest, so every patch below applies verbatim to each kernel.
    # Genuinely ISA-specific config, if any ever arises, goes in a
    # `lib.mkIf pkgs.stdenv.hostPlatform.isRiscV64 { ... }` block.
    {
      # Two targeted patches to the mainline cv18xx SDIO glue so the onboard
      # AIC8800D80 wifi comes up:
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
        # Mainline registers no working restart handler for the SG2000 on either
        # core: ARM's /psci SYSTEM_RESET hits a BL31 blob that does not implement
        # it, and RISC-V's SBI SRST has no cv18xx platform reset in OpenSBI -- so
        # machine_restart() spins after "reboot: Restarting system" (bench-proven
        # on both). dw_wdt registers a restart handler at priority 128. With the
        # watchdog@3010000 node (in each core's DTS) and the FSBL's
        # RTC_EN_WDT_RST_REQ gate at 0x050260E0, a watchdog timeout resets the
        # whole chip. Built in (=y) so the handler is present without a module
        # load (riscv otherwise only gets a lucky =m from its defconfig). The
        # Kconfig symbol is DW_WATCHDOG (the driver file is dw_wdt.c). It selects
        # WATCHDOG_CORE; keep WATCHDOG on explicitly.
        {
          name = "enable-dw-wdt-reboot";
          patch = null;
          extraConfig = ''
            WATCHDOG y
            WATCHDOG_CORE y
            DW_WATCHDOG y
          '';
        }
        # reset-simple drives sophgo,cv1800b-reset (the SG2000 reset controller,
        # &rst). Both cores' spi3 (from the base cv180x.dtsi) carry
        # `resets = <&rst RST_SPI3>`; dw-apb-ssi takes it as OPTIONAL, so without
        # a bound reset controller SPI3 probes anyway but comes up half-reset --
        # garbled WS2812 output + a dead Sharp panel on the shared bus. The
        # nixpkgs arm64/riscv64 configs leave RESET_SIMPLE off, so enable it here
        # for both. (ARM also declares reset-controller@3003000 in its DTS; RISC-V
        # gets &rst from the base cv180x.dtsi.)
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
      # Arm it short so the reset fires in ~2s. On ARM the dw_wdt in-kernel
      # restart path does not reset promptly, so this systemd path is what makes
      # `reboot` work; on RISC-V the in-kernel restart already resets promptly
      # (bench-proven), so this is belt-and-suspenders there -- harmless, and it
      # still buys the hang-recovery below.
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
    }
  ];
}
