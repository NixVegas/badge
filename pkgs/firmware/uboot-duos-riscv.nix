# U-Boot for the Milk-V Duo S (Sophgo SG2000, riscv64 S-mode).
# Builds from sophgo/u-boot-2021.10 branch sg200x-dev, commit a955e4df4d034b214416e3913e68b2d90ebce714.
# Produces $out/u-boot-raw.bin (= u-boot.bin, the LOADER_2ND blob for riscv fip packing).
#
# The board glue is authored here, not taken from the SDK build/ tree:
#   configs/cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig  (placed via postPatch)
#   board/cvitek/cvi_board_init.c                                (riscv variant: no prior_stage_fdt_address)
#   include/cvi_board_memmap.h                                   (memory map for the Duo S 512 MB)
#   include/cvipart.h                                            (minimal SD partition defs)
#
# The vendor tree (a955e4df) has no arch/riscv/dts/cv181x_cv181xasic.dts or any cv181x riscv
# U-Boot control DTS. The riscv dts/Makefile expects arch/riscv/dts/$(CHIP)_$(CVIBOARD).dtb
# (= cv181x_cv181xasic.dtb), but the source does not exist in the tree.
#
# CONFIG_OF_PRIOR_STAGE requires OpenSBI to pass an FDT pointer in a1. A clean Nix build
# writes no valid DTB at 0x80080000. Then prior_stage_fdt_address is invalid, and
# arch/riscv/cpu/generic/dram.c:dram_init() calls fdtdec_setup_mem_size_base(), which reads
# /memory from a bad pointer and hangs before any console output.
#
# The build uses CONFIG_OF_EMBED instead. It provides a minimal standalone control DTS via
# postPatch at arch/riscv/dts/cv181x_cv181xasic.dts. U-Boot compiles the DTS and links it in
# as __dtb_dt_begin. Then gd->fdt_blob is valid from fdtdec_setup() onward, with no runtime
# FDT pointer. The DTS is self-contained (no SDK header includes) with the minimal nodes:
#     - /memory at 0x80000000 / 512 MB
#     - RISC-V C906 cpu node with PLIC and CLINT
#     - uart0 (snps,dw-apb-uart at 0x04140000, console)
#     - cv-sd@4310000 (cvitek,cv181x-sd) for SD boot
# Removal of OF_PRIOR_STAGE removes the prior_stage_fdt_address variable. It was declared only
# in arch/riscv/cpu/cpu.c under that ifdef, and neither core defines it, so both cores share the
# one common cvi_board_init.c (SoC-pad-level pinmux: ethernet, WiFi/BT, JTAG, RTC power).
#
# Patches:
#   Patch 1: Add a SYS_TEXT_BASE hex symbol to board/cvitek/cv181x/Kconfig.
#     Same reason as the ARM build. The vendor Kconfig has no SYS_TEXT_BASE entry, so the
#     defconfig value is dropped and board_f.c / efi_runtime.c get CONFIG_SYS_TEXT_BASE
#     undeclared. For riscv, arch/riscv/include/asm/boot0.h also uses CONFIG_SYS_TEXT_BASE
#     directly in assembly (.quad CONFIG_SYS_TEXT_BASE).
#   Patch 2: Append _zicsr_zifencei to the ARCH_FLAGS in arch/riscv/Makefile.
#     binutils >= 2.38 (shipped with GCC 15) requires zicsr and zifencei to be listed
#     explicitly in -march for CSR instructions (csrr, fence.i) to assemble. The vendor tree
#     targets GCC 12 / binutils 2.35, which accepted them implicitly. Nixpkgs 26.05 uses
#     GCC 15.2.0 + binutils 2.46, so the patch is required.
#
{ pkgs }:
let
  ubootSrc = pkgs.fetchFromGitHub {
    owner = "sophgo";
    repo  = "u-boot-2021.10";
    rev   = "a955e4df4d034b214416e3913e68b2d90ebce714";
    hash  = "sha256-n3Me9Q0knGv6rl4gdanHovkEf3pu9iVlaNJqCWe8hYU=";
  };

  cc = pkgs.pkgsCross.riscv64.stdenv.cc;
  crossPrefix = cc.targetPrefix;

  defconfig  = ./cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig;
  boardInit  = ./cvi_board_init.c;
  memmap     = ./duos-riscv-uboot-memmap.h;
  cvipart    = ./cvipart.h;
in
pkgs.stdenv.mkDerivation {
  pname   = "uboot-duos-riscv";
  version = "2021.10-a955e4d";

  src = ubootSrc;

  nativeBuildInputs = with pkgs; [
    cc
    gnumake
    bison
    flex
    bc
    dtc
    openssl
    python3
    swig
    ncurses
    perl
  ];

  postPatch = ''
    # Place the authored defconfig.
    cp ${defconfig} configs/cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig

    # Override the vendor boot flow in cv181x-asic.h. The vendor default env uses
    # a FIT/hush sdboot. Replace CONFIG_BOOTCOMMAND/EXTRA_ENV with a clean
    # sysboot/extlinux boot of /extlinux/extlinux.conf on mmc 0:1 (the FAT). Same
    # override and load map as the ARM build (sysboot reads the _r-suffixed addrs).
    python3 - <<'ENDPY'
with open("include/configs/cv181x-asic.h", "r") as f:
    src = f.read()

insert = r"""
/* Override: replace the vendor FIT/hush boot with NixOS extlinux/sysboot.
 * sysboot mmc 0:1 any <scriptaddr> /riscv/extlinux/extlinux.conf
 * - kernel_addr_r/fdt_addr_r/ramdisk_addr_r: sysboot requires the _r suffix
 * - does not overlap U-Boot text (0x80200000) or ION reserve (0x9A600000)
 *
 * The path is per core (/riscv/, and /arm/ in the ARM U-Boot). Each core boots
 * its own U-Boot from its own fip-<core>.bin, so each one reads its own
 * directory. A core switch then swaps only fip.bin, and no shared
 * /extlinux/extlinux.conf must stay in sync. A per-core path prevents one
 * core's U-Boot from loading the other core's kernel, which stops with
 * "Bad Linux RISCV Image magic!".
 */
#undef  CONFIG_BOOTCOMMAND
#define CONFIG_BOOTCOMMAND \
    "sysboot mmc 0:1 any 0x82000000 /riscv/extlinux/extlinux.conf"

#undef  CONFIG_EXTRA_ENV_SETTINGS
#define CONFIG_EXTRA_ENV_SETTINGS \
    "scriptaddr=0x82000000\0" \
    "kernel_addr_r=0x81000000\0" \
    "fdt_addr_r=0x88000000\0" \
    "ramdisk_addr_r=0x8a000000\0"
"""

guard = "#endif /* __CV181X_ASIC_H__ */"
if guard in src:
    src = src.replace(guard, insert + guard)
else:
    src = src + insert

with open("include/configs/cv181x-asic.h", "w") as f:
    f.write(src)
ENDPY

    # Place the riscv board init. The vendor tree gitignores it. The riscv variant
    # omits prior_stage_fdt_address because arch/riscv/cpu/cpu.c already defines it.
    cp ${boardInit} board/cvitek/cvi_board_init.c

    # Place the memory map header (all CVIMMAP_ defines for the Duo S 512 MB).
    cp ${memmap} include/cvi_board_memmap.h

    # Place the partition definitions header (the SDK generates it via mkcvipart.py).
    cp ${cvipart} include/cvipart.h

    # Patch 1: Add a SYS_TEXT_BASE Kconfig symbol to the cv181x board Kconfig.
    # The vendor Kconfig has no config SYS_TEXT_BASE entry, so the defconfig
    # value is dropped and board_f.c / efi_runtime.c get CONFIG_SYS_TEXT_BASE
    # undeclared. For riscv, arch/riscv/include/asm/boot0.h also uses
    # CONFIG_SYS_TEXT_BASE in .quad (BOOT0 header generation). A hex entry here
    # mirrors other board Kconfigs and the ARM build.
    cat >> board/cvitek/cv181x/Kconfig <<'EOF'

config SYS_TEXT_BASE
	hex "Text Base"
	default 0x80200000
	help
	  U-Boot text/code base address in DRAM. For Milk-V Duo S the
	  SDK places U-Boot (both arm64 and riscv64) at DRAM_BASE + 2 MB
	  = 0x80200000, per memmap.py. OpenSBI occupies the first 512 KB
	  (0x80000000..0x80080000) and U-Boot follows at 0x80200000.
EOF

    # Patch 2: Append _zicsr_zifencei to the riscv ARCH_FLAGS in arch/riscv/Makefile.
    # binutils >= 2.38 (nixpkgs 26.05 GCC 15 toolchain uses binutils 2.46) requires
    # zicsr and zifencei to be listed explicitly in -march for the CSR (csrr, csrw)
    # and fence.i instructions. The vendor tree targets GCC 12 / binutils 2.35, which
    # accepted these instructions without an explicit ISA extension listing.
    # drivers/timer/riscv_timer.c and board.c both use csrr via <asm/csr.h>.
    sed -i 's/-march=$(ARCH_BASE)\$(ARCH_A)\$(ARCH_C)/-march=$(ARCH_BASE)$(ARCH_A)$(ARCH_C)_zicsr_zifencei/' arch/riscv/Makefile

    # Patch 3: Provide the missing cv181x riscv U-Boot control DTS.
    # The vendor tree (a955e4df) has no arch/riscv/dts/cv181x_cv181xasic.dts.
    # The vendor dts/Makefile hardcodes DTB := arch/$(ARCH)/dts/$(CHIP)_$(CVIBOARD).dtb,
    # so with CHIP=cv181x CVIBOARD=cv181xasic it expects cv181x_cv181xasic.dtb.
    # This minimal self-contained DTS gives U-Boot a valid control FDT for:
    #   - dram_init (arch/riscv/cpu/generic/dram.c calls fdtdec_setup_mem_size_base)
    #   - driver model serial (snps,dw-apb-uart -> ns16550 DM driver)
    #   - driver model MMC (cvitek,cv181x-sd -> sdhci-mars DM driver)
    # With CONFIG_OF_EMBED, U-Boot links this DTB in as __dtb_dt_begin, so
    # gd->fdt_blob is valid from startup with no runtime FDT pointer.
    cat > arch/riscv/dts/cv181x_cv181xasic.dts <<'ENDDTS'
/dts-v1/;

/ {
	model = "SOPHGO SG2000 Milk-V Duo S (riscv64)";
	compatible = "milkv,duos", "sophgo,sg2000", "cvitek,cv181x";

	#address-cells = <2>;
	#size-cells = <2>;

	memory@80000000 {
		device_type = "memory";
		/* 512 MB DDR at 0x80000000; the first 2 MB is reserved for OpenSBI */
		reg = <0x00 0x80000000 0x00 0x20000000>;
	};

	chosen {
		stdout-path = "serial0:115200n8";
	};

	aliases {
		serial0 = &uart0;
		mmc0    = &sd;
	};

	cpus {
		#address-cells = <1>;
		#size-cells = <0>;
		timebase-frequency = <25000000>;

		cpu-map {
			cluster0 {
				core0 {
					cpu = <&cpu0>;
				};
			};
		};

		cpu0: cpu@0 {
			device_type = "cpu";
			reg = <0>;
			status = "okay";
			compatible = "riscv";
			riscv,isa = "rv64imafdc";
			mmu-type = "riscv,sv39";
			clock-frequency = <25000000>;

			cpu0_intc: interrupt-controller {
				#interrupt-cells = <1>;
				interrupt-controller;
				compatible = "riscv,cpu-intc";
			};
		};
	};

	soc {
		#address-cells = <2>;
		#size-cells = <2>;
		compatible = "simple-bus";
		ranges;

		plic0: interrupt-controller@70000000 {
			riscv,ndev = <101>;
			riscv,max-priority = <7>;
			reg-names = "control";
			reg = <0x00 0x70000000 0x00 0x4000000>;
			interrupts-extended = <&cpu0_intc 0xffffffff &cpu0_intc 9>;
			interrupt-controller;
			compatible = "riscv,plic0";
			#interrupt-cells = <2>;
			#address-cells = <0>;
		};

		clint@74000000 {
			interrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>;
			reg = <0x00 0x74000000 0x00 0x10000>;
			compatible = "riscv,clint0";
			clint,has-no-64bit-mmio;
		};
	};

	uart0: serial@4140000 {
		compatible = "snps,dw-apb-uart";
		reg = <0x00 0x04140000 0x00 0x1000>;
		clock-frequency = <25000000>;
		reg-shift = <2>;
		reg-io-width = <4>;
		interrupts = <44 4>;
		interrupt-parent = <&plic0>;
		status = "okay";
	};

	sd: cv-sd@4310000 {
		compatible = "cvitek,cv181x-sd";
		reg = <0x00 0x04310000 0x00 0x1000>;
		reg-names = "core_mem";
		bus-width = <4>;
		cap-sd-highspeed;
		cap-mmc-highspeed;
		sd-uhs-sdr12;
		sd-uhs-sdr25;
		sd-uhs-sdr50;
		sd-uhs-sdr104;
		no-sdio;
		no-mmc;
		src-frequency = <375000000>;
		min-frequency = <400000>;
		max-frequency = <200000000>;
		64_addressing;
		reset_tx_rx_phy;
		reset-names = "sdhci";
		pll_index = <6>;
		pll_reg = <0x3002070>;
		status = "okay";
	};
};
ENDDTS
  '';

  buildPhase = ''
    export HOME=$TMPDIR
    export CROSS_COMPILE=${crossPrefix}
    export ARCH=riscv
    export PATH=${cc}/bin:${cc.bintools.bintools}/bin:$PATH
    # SOURCE_DATE_EPOCH=1 tells U-Boot's filechk_timestamp.h rule to use a fixed
    # epoch date instead of calling date(1) at build time. This makes the
    # U_BOOT_DATE, U_BOOT_TIME, U_BOOT_BUILD_DATE, and U_BOOT_EPOCH constants in
    # include/generated/timestamp_autogenerated.h deterministic.
    export SOURCE_DATE_EPOCH=1

    # cvitek.mk and the riscv dts Makefile use CHIP=cv181x and CVIBOARD=cv181xasic
    # (arch/riscv/dts/$(CHIP)_$(CVIBOARD).dtb target).
    # STORAGE_TYPE=sd enables -DCONFIG_SD_BOOT via cvitek.mk.
    # OF_EMBED=y: U-Boot compiles arch/riscv/dts/cv181x_cv181xasic.dts and links
    # it into the binary; no runtime FDT pointer is needed.
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=riscv \
      -j$NIX_BUILD_CORES \
      cvitek_sg2000_milkv_duos_musl_riscv64_sd_defconfig

    # GCC 15 is stricter than the GCC 12 that Sophgo targeted.
    # -Wno-enum-int-mismatch: cmd_process return type is declared int, defined as enum.
    # -Wno-format: board code uses %d for ulong; harmless on 64-bit.
    # -Wno-error: treat remaining new warnings as warnings, not errors.
    make \
      CHIP=cv181x \
      CVIBOARD=cv181xasic \
      STORAGE_TYPE=sd \
      CONFIG_USE_DEFAULT_ENV=y \
      CROSS_COMPILE=${crossPrefix} \
      ARCH=riscv \
      KCFLAGS="-Wno-enum-int-mismatch -Wno-format -Wno-error" \
      -j$NIX_BUILD_CORES \
      all
  '';

  installPhase = ''
    mkdir -p $out
    # u-boot.bin is the raw U-Boot binary (LOADER_2ND for riscv fip packing).
    cp u-boot.bin $out/u-boot-raw.bin
    # Keep the u-boot ELF and map for debugging.
    cp u-boot $out/u-boot || true
    cp u-boot.map $out/u-boot.map || true
  '';

  meta = {
    description = "Sophgo SG2000 U-Boot 2021.10 for Milk-V Duo S (riscv64, S-mode, SD boot)";
    license     = pkgs.lib.licenses.gpl2Plus;
  };
}
