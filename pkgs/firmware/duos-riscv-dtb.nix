# Standalone DTB build for the Milk-V Duo S RISC-V core (Sophgo SG2002 die).
#
# Compiles pkgs/firmware/dts/sg2000-milkv-duo-s-riscv.dts against the
# riscv kernel source's DTS include tree, mirroring the kernel dtb build rule:
#
#   HOSTCC -E -nostdinc -I scripts/dtc/include-prefixes \
#          -undef -D__DTS__ -x assembler-with-cpp <dts> -o <tmp.dts>
#   dtc -I dts -O dtb -i <sophgo-dir> -i scripts/dtc/include-prefixes \
#       <tmp.dts> -o <dtb>
#
# The include-prefixes directory has symlinks for each arch that allow
# sg2002.dtsi to reach cv180x-cpus.dtsi, cv180x.dtsi, cv181x.dtsi,
# and the pinctrl header to reach include/dt-bindings/. No full kernel
# rebuild is needed; only the kernel source tarball is unpacked.
#
# Output layout: $out/sophgo/sg2000-milkv-duo-s.dtb
# -> hardware.deviceTree.name = "sophgo/sg2000-milkv-duo-s.dtb"
{ pkgs, kernel }:
let
  dtsDir = ./dts;
  dts = "${dtsDir}/sg2000-milkv-duo-s-riscv.dts";
  # Build the DTB from a POST-PATCHED kernel tree. kernel.src is the raw upstream
  # tarball, but the mainline 7.2 sophgo dtsi our board DTS #includes (sg2002.dtsi
  # -> cv180x.dtsi) lacks the SoC peripheral nodes (thermal, pwm, efuse, mailbox,
  # i2s, timer, dma-mux). Armbian's DTS patches add them with the correct riscv
  # PLIC interrupt specifiers; apply them here so our #include chain picks the
  # nodes up. The matching DRIVER patches ride the kernel build itself (see
  # modules/duo-s/soc-features.nix); board-level hunks target the mainline board
  # .dts we do not #include, so they are inert for this DTB.
  patchedSrc = pkgs.applyPatches {
    name = "linux-${kernel.version}-sophgo-dts-patched";
    src = kernel.src;
    patches = import ../kernel/patches/armbian/dts-patches.nix;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "duos-riscv-dtb";
  version = kernel.version;

  src = patchedSrc;

  nativeBuildInputs = [ pkgs.buildPackages.buildPackages.gcc pkgs.buildPackages.buildPackages.dtc ];

  dontConfigure = true;

  buildPhase = "true";

  installPhase = ''
    KSRC="$NIX_BUILD_TOP/$sourceRoot"
    cd "$KSRC"

    # The kernel's dtc/include-prefixes contains relative symlinks such as
    # riscv -> ../../../arch/riscv/boot/dts. We must resolve them so they
    # work from an arbitrary working directory. Build an include dir with
    # absolute symlinks.
    INCDIR=$(mktemp -d)
    for link in scripts/dtc/include-prefixes/*; do
      name=$(basename "$link")
      real=$(realpath "scripts/dtc/include-prefixes/$name")
      ln -s "$real" "$INCDIR/$name"
    done
    # Also expose the top-level include/ (for dt-bindings not via symlink)
    ln -sf "$(realpath include)" "$INCDIR/include"

    # Sophgo riscv DTS dir (for dtc -i, so labels resolve within the dir)
    SOPHGO_DIR=$(realpath arch/riscv/boot/dts/sophgo)

    # Preprocess: cpp resolves #include chains. The DTS lives outside the
    # kernel tree so we give an explicit -I for the sophgo dir so that
    # the relative #include "sg2002.dtsi" resolves, and -I for INCDIR so
    # that <dt-bindings/...> and the RISC-V include-prefixes symlinks work.
    TMPDTS=$(mktemp "$NIX_BUILD_TOP/sg2000-milkv-duo-s-riscv.XXXXXX.dts")
    gcc -E \
      -nostdinc \
      -I "$INCDIR" \
      -I "$SOPHGO_DIR" \
      -I "${dtsDir}" \
      -undef -D__DTS__ \
      -x assembler-with-cpp \
      ${dts} \
      -o "$TMPDTS"

    # Compile to DTB.
    mkdir -p "$out/sophgo"
    dtc \
      -I dts \
      -O dtb \
      -i "$SOPHGO_DIR" \
      -i "$INCDIR" \
      -Wno-unit_address_vs_reg \
      -Wno-avoid_unnecessary_addr_size \
      -Wno-alias_paths \
      -Wno-interrupt_map \
      -Wno-simple_bus_reg \
      "$TMPDTS" \
      -o "$out/sophgo/sg2000-milkv-duo-s.dtb"
  '';

  meta = {
    description = "Milk-V Duo S (SG2002 RISC-V C906) device tree blob";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
