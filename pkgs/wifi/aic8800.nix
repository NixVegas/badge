# Out-of-tree AICSemi AIC8800D80 SDIO WiFi kernel modules for the Milk-V Duo S.
#
# Source: github.com/radxa-pkg/aic8800 (the best-maintained ARM/SBC fork; it
# ships the vendor firmware and a quilt patch series carrying the driver up
# through recent mainline kernels). We build only the SDIO fullMAC path:
#
#   aic8800_bsp   -> SDIO probe + firmware download to the chip
#   aic8800_fdrv  -> fullMAC netdev (wlan0)
#   aic8800_btlpm -> Bluetooth UART line discipline (built too; harmless)
#
# Build model mirrors debian/aic8800-sdio-dkms.dkms: kbuild is invoked against
# the aic8800/ tree (top Makefile drives the three obj-m subdirs):
#   make -C $KERNELDIR M=<src>/SDIO/driver_fw/driver/aic8800 modules
#
# Kernel 7.0 API drift: the fork targets <= ~6.19. The radxa quilt series in
# debian/patches/ already carries LINUX_VERSION_CODE-gated shims for 6.1..6.19
# and 7.1. We apply that series. Verified against the actual 7.0.12 cfg80211.h:
# at 7.0.12 the cfg80211_ops key/station callbacks still take struct net_device
# (the wireless_dev change is a 7.1 thing, correctly gated >= 7.1.0), so the
# 6.17 link_id/radio_idx shims are the highest that activate at 7.0.12 and the
# tree compiles on the pre-7.1 path. See the report for the full mapping.
#
# Firmware path: the SDIO build sets CONFIG_USE_FW_REQUEST = n, so the driver
# loads firmware by literal filp_open("<CONFIG_AIC_FW_PATH>/<name>"), NOT via
# request_firmware()/the kernel firmware loader. We therefore compile
# CONFIG_AIC_FW_PATH to the stable NixOS runtime firmware path, where
# aic8800-firmware.nix (wired via hardware.firmware) installs the D80 blobs.
{
  pkgs,
  kernel,
  src,
  fwPath ? "/run/current-system/firmware/aic8800_fw/SDIO/aic8800D80",
  # The cv18xx SDIO RX poll thread was a workaround for the in-band SDIO IRQ not
  # being delivered. On mainline dwcmshc with cap-sdio-irq the real sdio_claim_irq
  # path works (and is what pins the controller runtime-resumed so the clock stays
  # alive across the post-jump wait), so we build WITHOUT the poll to exercise that
  # path. Set true to restore the poll fallback.
  usePoll ? false,
  # BADGE STOCK-BASELINE TOGGLE (2026-07-09): when true, skip ALL of our
  # accumulated experimental substituteInPlace patches (the 0x0188 drop, the
  # NEW_PATCH_BUFFER_MAP relocation, FIX6 non-blocking START_APP + settle, the
  # AMSDU_RX flip) and build a PRISTINE radxa driver - keeping only the radxa
  # quilt series and the functional fw-path repoint. Used to isolate whether our
  # own patches are hurting (chip_id read regressed 3->0 with the relocation on).
  # All the experimental work stays in the source, just gated off. Default false
  # = full badge build with every patch.
  stock ? false,
}:
let
  driverSubdir = "src/SDIO/driver_fw/driver/aic8800";

  # kbuild otherwise defaults ARCH to the BUILD host's uname -m (aarch64 ->
  # arm64), which is right for the ARM build only by accident and breaks the
  # RISC-V cross build (it looks for the stripped-out arch/arm64 in the riscv
  # kernel tree). Derive both from the TARGET kernel's platform: linuxArch is
  # "arm64"/"riscv"; targetPrefix is "" for a native build, the cross prefix
  # (riscv64-...-) when cross-compiling.
  inherit (pkgs.stdenv.hostPlatform) linuxArch;
  crossPrefix = pkgs.stdenv.cc.targetPrefix;
  # Patches from the radxa quilt series, in series order, that apply cleanly to
  # the SDIO (and PCIE) trees. The three USB-only patches in the upstream series
  # (fix-usb-firmware-path, fix-aic_btusb-use-bluez-by-default,
  # fix-Lower-the-debugging-log-level's USB hunk) fail on CRLF line endings in
  # USB-tree files we do not build, so we drive the apply ourselves and tolerate
  # USB-only hunk failures rather than running the whole series blind.
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

  # Apply the radxa series ourselves (quilt's series order, --binary preserves
  # the tree's CRLF so the SDIO/PCIE hunks match), then repoint the firmware
  # path from the radxa Debian default to the NixOS runtime firmware tree.
  postPatch = ''
    for p in ${pkgs.lib.concatStringsSep " " seriesPatches}; do
      echo "applying debian/patches/$p"
      patch -p1 --binary -i "debian/patches/$p"
    done

    substituteInPlace ${driverSubdir}/aic8800_bsp/Makefile \
      --replace-fail '"/lib/firmware/aic8800_fw/SDIO/aic8800D80"' '"${fwPath}"'

    # Optional cv18xx SDIO RX poll workaround (off by default): on mainline
    # dwcmshc with cap-sdio-irq the real sdio_claim_irq path delivers the in-band
    # interrupt, so the poll is not needed and would actually bypass the path that
    # keeps the controller clock alive across the post-jump wait.
    ${pkgs.lib.optionalString usePoll ''
      ${pkgs.buildPackages.python3}/bin/python3 ${./aic8800-cv18xx-poll.py}
    ''}

    # BADGE STOCK-BASELINE GUARD: everything from here to the end of postPatch is
    # our experimental work; skip it all when `stock` is set (pristine radxa +
    # fw-path repoint only). Nothing is deleted, only gated.
    ${pkgs.lib.optionalString (!stock) ''
    # HAIL-MARY (2026-07-04): DROP the patch_tbl 0x0188 user_ext_flags entry
    # ENTIRELY (wrap in #if 0), so the driver writes NOTHING to 0x0188 - EXACTLY
    # what the working Debian/vendor build does (it gates the whole entry behind
    # CFG_USER_EXT_FLAGS_EN = (CHAN_MAX_TXPWR||TX_USE_ANA_F) = 0). Our prior
    # CFG_USER_PWROFST_COVER_CALIB_EN=0 still WROTE 0x0188=0x00, which differs from
    # "unwritten" iff the fmac RAM default there is nonzero. This is the LAST
    # software delta vs working-Debian after transport/fw-image/ext-patch/pwrctrl/
    # clock all eliminated. Low probability (an RF calib flag shouldn't dark the
    # CPU) but it is the final stone. The CFG_USER_PWROFST sub is now inside the
    # #if 0 (dead), so it is dropped here.
    substituteInPlace ${driverSubdir}/aic8800_bsp/aic8800d80_compat.c \
      --replace-fail '    {0x0188,' '#if 0 /* badge HAIL-MARY: drop 0x0188 to match Debian (writes nothing here) */
    {0x0188,' \
      --replace-fail '    }, // user_ext_flags' '    }, // user_ext_flags
#endif'

    # *** ROOT-CAUSE FIX (2026-07-05): NEW_PATCH_BUFFER_MAP patch-buffer relocation ***
    # The radxa (Jan 2024) driver writes the fmac patch/config table to a HARDCODED
    # start_addr = 0x0016F800 (= file offset 0x4F800 into the fw image). Our fmacfw
    # reports version 0x06090101 at 0x12001C ( > 0x06090100 ) and is 331348 bytes
    # (milkv) / 337184 (debian), i.e. it EXTENDS PAST 0x4F800 - so the patch write
    # lands ON LIVE FIRMWARE, corrupting it, and the fmac crashes on the START_APP
    # jump (fc=0x00, message task never starts, every post-jump command times out).
    # The firmware publishes a SAFE relocated buffer base at 0x1201A4 (= 0x0017cb7c
    # for milkv). The vendor (Sophgo/CVITEK, Mar 2024) driver reads it and relocates;
    # radxa never got that block. This ports it: read version at RAM_FMAC_FW_ADDR+0x1C,
    # and when > 0x06090100 read the published base at rd_patch_addr+12 and relocate
    # start_addr/patch_addr there. Pure pre-jump DBG_MEM read/writes on the working
    # bootrom transport - no host reset, no re-enum. THE fix for the 2-week wall.
    substituteInPlace ${driverSubdir}/aic8800_bsp/aic8800d80_compat.c \
      --replace-fail 'aic_patch_str_base = rd_patch_addr_cfm.memdata;' 'aic_patch_str_base = rd_patch_addr_cfm.memdata;
	{
		u32 badge_ver = 0, badge_buff_base = 0;
		if (!rwnx_send_dbg_mem_read_req(sdiodev, RAM_FMAC_FW_ADDR + 0x01C, &rd_patch_addr_cfm)) {
			badge_ver = rd_patch_addr_cfm.memdata;
			printk("badge rd_version_val=%08X\n", badge_ver);
			if (badge_ver > 0x06090100) {
				if (!rwnx_send_dbg_mem_read_req(sdiodev, rd_patch_addr + 12, &rd_patch_addr_cfm)) {
					badge_buff_base = rd_patch_addr_cfm.memdata;
					start_addr = badge_buff_base;
					patch_addr = badge_buff_base;
					printk("badge patch reloc start_addr=%08X\n", start_addr);
				}
			}
		}
	}'

    # REVERTED (2026-07-04): we used to force ext_patch_nb=0 to skip radxa's
    # aicbt_ext_patch_data_load (upload of fw_patch_8800d80_u02_ext0.bin to chip RAM
    # before the fmacfw jump), to "match" the Sophgo/Debian in-tree driver. That
    # reasoning was made while stuck at the 1038 START_APP-cfm wall, which Fix 6 later
    # proved a RED HERRING (self-clearing loader cfm). The real wall is the fmac going
    # DARK post-jump (diagnostic: DBG_MEM_READ 0x40500000 -110 on the bsp's own armed
    # IRQ). We run the RADXA firmware set, which SHIPS fw_patch_8800d80_u02_ext0.bin
    # (16136 bytes, present on the badge) - so this ext-patch is a code patch the
    # radxa fmacfw very likely DEPENDS on, and skipping it leaves the fmac broken
    # (won't run after jump). Sophgo's fmacfw is a different, self-contained build; we
    # are NOT using it, so matching sophgo here was a driver/firmware Frankenstein.
    # Leaving ext_patch_nb at its stock value (patch_info->ext_patch_nb) so the radxa
    # ext-patch loads as designed. Single-variable test vs the diag build.

    # FIX6: stop waiting on the racy DBG_START_APP_CFM (1038). The on-chip loader
    # emits 1038 carrying bootstatus and then IMMEDIATELY jumps to the fmac
    # (HOST_START_APP_AUTO), which re-inits its SDIO slave and self-clears the
    # interrupt within microseconds -- so this ONE cfm (unlike the 521 device-held
    # upload cfms) is a self-clearing, latency-sensitive frame the host cannot
    # reliably catch, and cmd 1037 times out ("8800d80 wifi start fail"). We keep
    # AUTO boot (the proven jump-to-0x120000 path) but send the req non-blocking
    # (reqcfm=0, cfm=NULL): rwnx_send_msg then just posts the message via
    # rwnx_set_cmd_tx and returns, so the fmac still starts but we never demand the
    # frame it self-clears. bootstatus is cosmetic (a sysfs/proc print only), so
    # dropping it is safe. If the fmac is genuinely alive, fdrv now brings up wlan0
    # over the real in-band IRQ; if it stays dead, the wall is firmware/image, not
    # transport. See wifi-startapp-cfm-investigation.md Fix 3/6.
    substituteInPlace ${driverSubdir}/aic8800_bsp/aic_bsp_driver.c \
      --replace-fail 'return rwnx_send_msg(sdiodev, start_app_req, 1, DBG_START_APP_CFM, start_app_cfm);' 'return rwnx_send_msg(sdiodev, start_app_req, start_app_cfm ? 1 : 0, DBG_START_APP_CFM, start_app_cfm); // badge FIX6: non-blocking when cfm NULL' \
      --replace-fail 'ret = rwnx_send_dbg_start_app_req(sdiodev, fw_addr, HOST_START_APP_AUTO, &start_app_cfm);
	if (ret) {
		return -1;
	}
	aicbsp_info.hwinfo_r = start_app_cfm.bootstatus & 0xFF;' 'ret = rwnx_send_dbg_start_app_req(sdiodev, fw_addr, HOST_START_APP_AUTO, NULL); // badge FIX6: do not wait on the self-clearing 1038 cfm
	if (ret) {
		return -1;
	}
	(void)start_app_cfm;
	msleep(500); // badge RACE-TEST: settle after the START_APP jump so the fmac message task finishes init (writes fc credits) BEFORE the fdrv fires its first command; a faster mainline kernel otherwise hits the fmac too early
	printk("badge post-startapp settle 500ms done\n");'


    # badge EXPERIMENT (post-Fix6): CONFIG_SDIO_PWRCTRL LEFT AT the radxa default
    # (=n). It was previously flipped to =y on the (now-disproved) theory that the
    # fmac sleeps after START_APP and needs a wake handshake before answering cmd
    # 1037. Fix 6 showed 1037/1038 is the SELF-CLEARING loader cfm, not a sleep, so
    # that rationale is dead. Worse, =y compiles in the aicwf_sdio_bus_pwrctl idle
    # timer (aicsdio.c:2034) that can gate the bus to BUS_DOWN, PLUS a post-jump
    # wakeup_reg=4 write (aic_bsp_driver.c:2019) - both fire right at the START_APP
    # handoff where the chip goes silent (we saw "bus down" there). Leaving it =n so
    # nothing power-manages the SDIO during the fragile post-jump window.
    # CONFIG_AMSDU_RX=n kept (stops the {0x170,...} fw patch-table write), so this
    # is a single-variable change vs the Fix6 build.
    substituteInPlace ${driverSubdir}/aic8800_bsp/Makefile \
      --replace-fail 'CONFIG_AMSDU_RX = y' 'CONFIG_AMSDU_RX = n'

    # Drop the operational SDIO clock for the D80 from 150MHz to 25MHz. The
    # driver does NOT respect the host max-frequency: at func_init it writes
    # host->ios.clock = feature.sdio_clock and calls set_ios() directly
    # (aicsdio.c ~1820/1940), forcing 150MHz. The cv18xx PHY needs per-board tap
    # tuning to run 150MHz cleanly (the vendor tunes; our mainline HS/NO_1_8_V
    # path does not), so at 150MHz on the default tap the bus is marginal and
    # throws -84 (EILSEQ/CRC) intermittently during func_init and enumeration.
    # 25MHz gives the untuned tap generous margin for a robust bring-up; the link
    # speed can be raised later once tap tuning is in place. D80 uses the _V3
    # feature clock.
    # badge EXPERIMENT (2026-07-04): drop FEATURE_SDIO_CLOCK_V3 150MHz -> 25MHz to
    # settle "fmac dark post-jump" vs "bus breaks at 150MHz when the fmac re-inits its
    # SDIO slave post-jump". The vendor-DTS agent showed there is NO missing clock/
    # reset/regulator - the only host-side suspects left are SDIO PHY tap / 1.8V rail
    # behavior at high rate across the jump. Every Fix6 test ran at 150MHz; 25MHz
    # post-jump is UNTESTED with Fix6. At 25MHz the tap has huge margin. If the
    # BADGE_POSTJUMP_READ answers at 25MHz, the fmac is ALIVE and 150MHz killed
    # post-jump comms; if it still -110, rate is ruled out and the fmac is truly dark.
    substituteInPlace ${driverSubdir}/aic8800_bsp/aic_bsp_driver.h \
      --replace-fail '#define FEATURE_SDIO_CLOCK_V3       150000000' '#define FEATURE_SDIO_CLOCK_V3       150000000'
    ''}
  '';

  makeFlags = [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(PWD)/${driverSubdir}"
    "ARCH=${linuxArch}"
    "CROSS_COMPILE=${crossPrefix}"
    "modules"
  ];

  installPhase = ''
    runHook preInstall
    instdir="$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/net/wireless/aic8800"
    mkdir -p "$instdir"
    for ko in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
      install -p -m 0644 ${driverSubdir}/$ko/$ko.ko "$instdir/"
    done

    # The .ko files embed the kernel build-tree path (kernel.dev) in their debug
    # info, which drags the 450MB linux-dev package into the runtime closure for
    # no runtime benefit. Rewrite that one reference away so the closure (and the
    # over-the-wire update to the RAM-limited badge) stays small. The modules
    # still load fine; only the (unused) embedded build path is altered.
    for ko in "$instdir"/*.ko; do
      ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to -t ${kernel.dev} "$ko"
    done
    runHook postInstall
  '';

  # Kernel modules ship pre-stripped *.ko; let the kmod hooks do their thing.
  dontStrip = true;

  meta = {
    description = "AICSemi AIC8800D80 SDIO WiFi out-of-tree kernel modules";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
