# BL2 (FSBL) + chip_conf.bin for Sophgo SG2000 / Milk-V Duo S.
# Builds plat/cv181x BL2 from sophgo/fsbl rev 29edcfa0b5f999c8ea8f0759b0dd0038421e6c25.
# Does not build the full fip (no u-boot, no fiptool). Outputs:
#   $out/bl2.bin      - BL2 image (arm: TOC 0xAA640001, riscv: TOC 0xC906B001)
#   $out/chip_conf.bin - chip configuration table (pure-python, no extra deps)
#
# core = "arm"   (default): BOOT_CPU=aarch64, aarch64-embedded toolchain.
# core = "riscv": BOOT_CPU=riscv, riscv64-embedded toolchain, TOC 0xC906B001.
# import ./fsbl.nix { inherit pkgs; } uses the arm path.
{ pkgs, core ? "arm", dumpRom ? false }:
let
  # Per-core toolchain and build parameters.
  coreAttrs =
    if core == "arm" then {
      cc = pkgs.pkgsCross.aarch64-embedded.stdenv.cc;
      bootCpu = "aarch64";
      arch = "aarch64";
      ldFlags = "TF_LDFLAGS_aarch64=--no-warn-rwx-segments";
    } else if core == "riscv" then {
      cc = pkgs.pkgsCross.riscv64-embedded.stdenv.cc;
      bootCpu = "riscv";
      arch = "riscv";
      ldFlags = "TF_LDFLAGS_aarch64=--no-warn-rwx-segments";
    } else
      throw "fsbl.nix: unknown core=${core}, expected arm or riscv";

  cc = coreAttrs.cc;
  crossPrefix = cc.targetPrefix;

  src = pkgs.fetchFromGitHub {
    owner = "sophgo";
    repo = "fsbl";
    rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  };

  memmap = ./duos-arm-memmap.h;

  # One-shot mask-ROM dumper (dumpRom = true). The 96 KiB boot ROM (ROM_SIZE
  # 0x18000) is readable only from inside BL2. The post-FSBL world sees the
  # mirror at 0x40000000 zeroed and the real base firewalled. BL2 reads it as
  # 32-bit words (the ROM is word-only) and emits each byte as hex via
  # console_putc (no printf width dependency). It pets the DW watchdog
  # (0x76 -> WDT_CRR at 0x0301000C) every word so the minute-long dump cannot
  # trip a reset. The leading NOTICE prints the first 4 words, so a faulting or
  # zero read shows up before the long stream. The ROM address differs per core:
  # ARM sees the mirror at 0x40000000 (live during BL2, since BL2 calls the ROM
  # API at 0x40000060); the C906 sees it at 0x04418000.
  romBase = if core == "arm" then "0x40000000" else "0x04418000";
  dumpInc = pkgs.writeText "romdump.inc.c" ''
    { /* BadgeOS one-shot mask-ROM dumper */
      extern int console_putc(int c);
      static const char romhx[16] = "0123456789abcdef";
      volatile unsigned int *romw = (volatile unsigned int *)(${romBase}UL);
      unsigned int romnw = 0x18000U / 4, romi, romk;
      const char *romp, *rb = "\nROMDUMP_BEGIN\n", *re = "\nROMDUMP_END\n";
      NOTICE("ROMDUMP base=0x%x first=0x%x 0x%x 0x%x 0x%x\n",
        (unsigned int)(${romBase}UL), romw[0], romw[1], romw[2], romw[3]);
      for (romp = rb; *romp; romp++) console_putc(*romp);
      for (romi = 0; romi < romnw; romi++) {
        unsigned int w = romw[romi];
        for (romk = 0; romk < 4; romk++) {
          unsigned int b = (w >> (romk * 8)) & 0xff;
          console_putc(romhx[(b >> 4) & 0xf]);
          console_putc(romhx[b & 0xf]);
        }
        if ((romi & 0xf) == 0xf) console_putc('\n');
        mmio_write_32(0x0301000C, 0x76);
      }
      for (romp = re; *romp; romp++) console_putc(*romp);
    }
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "sg2000-fsbl-${core}";
  version = "29edcfa";

  inherit src;

  # The riscv64-none-elf bare-metal linker does not support -z relro / -z now
  # (Linux hardening flags). Disable them for the riscv path. The arm path is
  # unaffected, because the aarch64-none-elf linker ignores unknown -z flags.
  hardeningDisable = if core == "riscv" then [ "relro" "bindnow" ] else [];

  nativeBuildInputs = [
    cc
    pkgs.gnumake
    pkgs.python3
    pkgs.dtc
    pkgs.libfaketime
  ];

  # Place the memmap header where the build expects it.
  # The Makefile adds -Ibuild to INCLUDES, and mmap.h does:
  #   #include "cvi_board_memmap.h"
  # Copy it into build/ inside the source tree (created during the build).
  # Run addresses are board/DDR-driven and identical for arm and riscv.
  postPatch = ''
    mkdir -p build
    cp ${memmap} build/cvi_board_memmap.h
  '' + (if core == "riscv" then ''
    # GCC 15 (riscv64-none-elf) uses the new xtheadXXX extension form, not the
    # old vendor-blob "vxthead". Replace it in cpu.mk. Add xtheadsync, which
    # th.sync.i in cpu_helper.c requires.
    substituteInPlace lib/cpu/riscv/cpu.mk \
      --replace-fail 'rv64imafdcvxthead' 'rv64imafdc_xtheadcmo_xtheadsync'

    # GCC 15 + binutils 2.46 require the "th." prefix on T-Head instructions.
    substituteInPlace lib/cpu/riscv/cpu_helper.c \
      --replace-fail '"icache.iall\n"' '"th.icache.iall\n"' \
      --replace-fail '"sync.i\n"'      '"th.sync.i\n"'

    # T-Head custom CSRs: replace named CSRs with their numeric addresses.
    # mxstatus=0x7C0  mhcr=0x7C1  mcor=0x7C2 (T-Head C906 ISA manual).
    # bl2_entrypoint.S and bl1_entrypoint.S use mxstatus/mcor/mhcr.
    # cache.c uses mhcr in inline asm strings.
    substituteInPlace lib/cpu/riscv/bl2_entrypoint.S \
      --replace-fail 'mxstatus' '0x7C0' \
      --replace-fail 'mcor'     '0x7C2' \
      --replace-fail 'mhcr'     '0x7C1'
    substituteInPlace lib/cpu/riscv/bl1_entrypoint.S \
      --replace-fail 'mxstatus' '0x7C0' \
      --replace-fail 'mcor'     '0x7C2' \
      --replace-fail 'mhcr'     '0x7C1'
    substituteInPlace lib/cpu/riscv/cache.c \
      --replace-fail 'mhcr' '0x7C1'
  '' else "") + (if dumpRom then ''
    # Inject the one-shot mask-ROM dumper after the FSBL banner NOTICE.
    # An #include inside bl2_main() inserts the { ... } block as a statement,
    # before load_ddr(). The dump needs only the UART and the stack.
    cp ${dumpInc} plat/cv181x/bl2/romdump.inc.c
    sed -i '/FSBL %s:%s/a #include "romdump.inc.c"' plat/cv181x/bl2/bl2_main.c
  '' else "");

  buildPhase = ''
    # Pass a fixed BUILD_STRING so the Makefile does not call git rev-parse.
    # Without this override, Makefile line 77 runs:
    #   BUILD_STRING := g$(shell git rev-parse --short HEAD 2>/dev/null)
    # The fixed value makes the intent explicit and keeps git out of
    # nativeBuildInputs.
    export HOME=$TMPDIR
    export CROSS_COMPILE=${crossPrefix}
    export PATH=${cc}/bin:${cc.bintools.bintools}/bin:$PATH

    # Neutralize wall-clock time sources for reproducible builds:
    # - SOURCE_DATE_EPOCH=1 makes GCC substitute a fixed epoch time for the
    #   __DATE__ and __TIME__ macros.
    # - BUILD_MESSAGE_TIMESTAMP overrides make_helpers/build_macros.mk line 218,
    #   which otherwise runs $(shell date -Is). That timestamp is embedded in
    #   bl2.bin as the build_message[] C string (visible in the FSBL serial
    #   banner: "FSBL <ver>:<timestamp>").
    # - faketime wraps any remaining date(1) calls that ignore SOURCE_DATE_EPOCH.
    #
    # OD_CLK_SEL=y (#44): the overdrive clock plan in plat/cv180x/platform.c --
    # sets mpll=1050MHz and points clk_a53/clk_c906 at it (div 1), so the big
    # core runs 1050MHz instead of the default ~850MHz (~24% more). The FSBL sets
    # the PLLs before handing off, so it applies to whichever core boots. Verify
    # under a soak (no active cooling on the badge) after the first deploy of the
    # new fip.
    export SOURCE_DATE_EPOCH=1
    faketime -f "1970-01-01 00:00:01" \
    make -j$NIX_BUILD_CORES \
      CHIP_ARCH=cv181x \
      BOOT_CPU=${coreAttrs.bootCpu} \
      DDR_CFG=ddr3_1866_x16 \
      SWITCH_32K_XTAL=y \
      OD_CLK_SEL=y \
      CROSS_COMPILE=${crossPrefix} \
      BUILD_STRING=nix \
      BUILD_MESSAGE_TIMESTAMP='"1970-01-01T00:00:01+00:00"' \
      ${coreAttrs.ldFlags} \
      V=1 \
      bl2

    # chip_conf.py uses #!/usr/bin/env python3, which is not available in the
    # Nix sandbox. Invoke it directly with the python3 binary instead.
    python3 ./plat/cv181x/chip_conf.py ./build/cv181x/chip_conf.bin
  '';

  installPhase = ''
    mkdir -p $out
    cp build/cv181x/bl2.bin $out/bl2.bin
    cp build/cv181x/chip_conf.bin $out/chip_conf.bin
  '';

  meta = {
    description = "Sophgo SG2000 FSBL BL2 and chip_conf for Milk-V Duo S (${core})";
    license = pkgs.lib.licenses.bsd3;
  };
}
