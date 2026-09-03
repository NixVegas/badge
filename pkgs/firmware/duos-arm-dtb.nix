# Standalone DTB build for the Milk-V Duo S (Sophgo SG2000, aarch64).
#
# Compiles pkgs/firmware/dts/sg2000-milkv-duo-s.dts against the kernel
# source's DTS include tree, mirroring the kernel's own dtb build rule:
#
#   HOSTCC -E -nostdinc -I scripts/dtc/include-prefixes \
#          -undef -D__DTS__ -x assembler-with-cpp <dts> -o <tmp.dts>
#   dtc -I dts -O dtb -i <sophgo-dir> -i scripts/dtc/include-prefixes \
#       <tmp.dts> -o <dtb>
#
# The include-prefixes directory has symlinks for each arch (riscv ->,
# arm64 ->, dt-bindings -> ...) that allow sg2000.dtsi to reach the
# riscv/sophgo cv180x.dtsi and cv181x.dtsi, and the pinctrl header to
# reach include/dt-bindings/. No full kernel rebuild is needed.
#
# Output layout: $out/sophgo/sg2000-milkv-duo-s.dtb
# -> hardware.deviceTree.name = "sophgo/sg2000-milkv-duo-s.dtb"
{ pkgs, kernel }:
let
  dtsDir = ./dts;
  dts = "${dtsDir}/sg2000-milkv-duo-s.dts";
  # Build the DTB from a POST-PATCHED kernel tree. kernel.src is the raw upstream
  # tarball, but the mainline 7.2 sophgo dtsi our board DTS #includes (sg2000-
  # milkv-duo-module-01.dtsi -> sg2000.dtsi) lacks the SoC peripheral nodes
  # (thermal, pwm, efuse, mailbox, i2s, ...). Armbian's DTS patches add them with
  # the correct arm64 GIC interrupt specifiers; apply them here so our #include
  # chain picks the nodes up. The matching DRIVER patches ride the kernel build
  # itself (see modules/duo-s/soc-features.nix); board-level hunks target the
  # mainline board .dts we do not #include, so they are inert for this DTB.
  patchedSrc = pkgs.applyPatches {
    name = "linux-${kernel.version}-sophgo-dts-patched";
    src = kernel.src;
    patches = import ../kernel/patches/armbian/dts-patches.nix;
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "duos-arm-dtb";
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
    # copies / absolute symlinks.
    INCDIR=$(mktemp -d)
    for link in scripts/dtc/include-prefixes/*; do
      name=$(basename "$link")
      # Resolve relative symlinks so they work from an arbitrary working directory:
      real=$(realpath "scripts/dtc/include-prefixes/$name")
      ln -s "$real" "$INCDIR/$name"
    done
    # Also expose the top-level include/ (for dt-bindings not via symlink)
    ln -sf "$(realpath include)" "$INCDIR/include"

    # Sophgo arm64 DTS dir (for dtc -i, so labels resolve within the dir)
    SOPHGO_DIR=$(realpath arch/arm64/boot/dts/sophgo)

    # Preprocess: cpp resolves #include chains. The DTS lives outside the
    # kernel tree so we give an explicit -I for the sophgo dir so that
    # relative #include "sg2000-milkv-duo-module-01.dtsi" resolves.
    TMPDTS=$(mktemp "$NIX_BUILD_TOP/sg2000-milkv-duo-s.XXXXXX.dts")
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
    description = "Milk-V Duo S (SG2000 aarch64) device tree blob";
    license = pkgs.lib.licenses.gpl2Only;
  };
}
