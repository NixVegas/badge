# OpenSBI fw_dynamic.bin for Sophgo SG2000 / Milk-V Duo S (RISC-V MONITOR).
#
# Builds upstream OpenSBI PLATFORM=generic, dynamic firmware only.
# fw_dynamic carries no payload; the FSBL loads U-Boot separately and passes
# next-stage info via a dynamic-info struct at runtime.
#
# FW_FDT_PATH embeds our RISC-V DTB into the firmware. Upstream generic OpenSBI
# REQUIRES a device tree to find the console UART, CLINT/timer, PLIC and memory.
# The Sophgo FSBL passes a1=OPENSBI_FDT_ADDR (0x80080000) but nothing places a
# valid DTB there in our clean build, so without an embedded FDT OpenSBI can't
# init (no banner, hangs before U-Boot). FW_FDT_PATH overrides the a1 pointer
# with the built-in DTB (which OpenSBI then also forwards to U-Boot; U-Boot
# ignores it via CONFIG_OF_EMBED). We reuse the mainline cv181x/sg2002-based
# Duo S DTB - OpenSBI only consumes cpu/clint/plic/uart/memory from it.
#
# Source: riscv-software-src/opensbi v1.8.1 (nixpkgs 26.05 pinned version).
# Toolchain: riscv64-unknown-linux-gnu (pkgsCross.riscv64.buildPackages.gcc).
#
# $out is fw_dynamic.bin directly (mirrors bl31-blob.nix), so it drops into
# fip.nix's MONITOR slot.
{ pkgs }:
let
  # Reuse the source and version nixpkgs 26.05 already pins (v1.8.1).
  inherit (pkgs.opensbi) src version;

  # riscv64-unknown-linux-gnu cross toolchain available from nixpkgs.
  crossGcc = pkgs.pkgsCross.riscv64.buildPackages.gcc;
  crossPrefix = crossGcc.targetPrefix;

  # Built-in device tree for OpenSBI: the mainline Duo S RISC-V DTB, compiled
  # from the kernel the NixOS configs use (linuxPackages_latest). It carries the
  # c906 cpu, CLINT, PLIC, uart0 and memory that OpenSBI generic needs.
  riscvDtb = import ./duos-riscv-dtb.nix {
    inherit pkgs;
    kernel = pkgs.linuxPackages_latest.kernel;
  };
  fdt = "${riscvDtb}/sophgo/sg2000-milkv-duo-s.dtb";
in
pkgs.stdenv.mkDerivation {
  pname = "opensbi-fw-dynamic";
  inherit version src;

  nativeBuildInputs = [
    crossGcc
    crossGcc.bintools
    pkgs.python3
    pkgs.gnumake
  ];

  # OpenSBI scripts have Python shebangs; patch them so Nix sandbox finds
  # the interpreter.
  postPatch = ''
    patchShebangs ./scripts
  '';

  buildPhase = ''
    export PATH=${crossGcc}/bin:${crossGcc.bintools.bintools}/bin:$PATH
    # SOURCE_DATE_EPOCH=1 tells OpenSBI's Makefile (lines 222-228) to use
    # a fixed epoch date for OPENSBI_BUILD_TIME_STAMP instead of calling
    # date(1) at build time.  Without this the build embeds the current
    # wall-clock time and the firmware is not bit-reproducible.
    export SOURCE_DATE_EPOCH=1

    make -j$NIX_BUILD_CORES \
      PLATFORM=generic \
      CROSS_COMPILE=${crossPrefix} \
      FW_DYNAMIC=y \
      FW_JUMP=n \
      FW_PAYLOAD=n \
      FW_FDT_PATH=${fdt}
  '';

  installPhase = ''
    install -D build/platform/generic/firmware/fw_dynamic.bin "$out"
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "OpenSBI fw_dynamic for RISC-V MONITOR slot (SG2000 / Milk-V Duo S)";
    license = pkgs.lib.licenses.bsd2;
  };
}
