# nix-badge: the badge's own control tool (Zig).
#
# One static binary for the badge-specific functions:
#   nix-badge leds ...    the WS2812 chain on SPI3 (service, initrd onward)
#   nix-badge core ...    the ARM/RISC-V select latch (U2 74AUP1G175)
#   nix-badge power       rail voltages (sysfs iio-rescale + power_supply) + fault GPIOs
#   nix-badge mmio ...    32-bit /dev/mem peek/poke for register bring-up
#   nix-badge bling ...   the OLED bling engine (Bad Apple + screens)
#
# Built with Zig, cross-compiled to a STATIC musl binary. Static is deliberate:
# a NixOS host has no /lib/ld-linux-*.so.1 interpreter, so a dynamically linked
# cross binary would not run; a static musl binary has no interpreter and runs
# as-is (and keeps the closure to nothing). Zig cross-compiles both cores
# natively on the build host -- no QEMU, no target toolchain -- so we build with
# buildPackages.zig against pkgs.stdenv.hostPlatform's target triple. The LED
# service must keep running across switch_root; a static binary at its real
# /nix/store path resolves identically before and after, with no libc to find.
{ pkgs }:
let
  hp = pkgs.stdenv.hostPlatform;
  zigTarget =
    if hp.isAarch64 then
      "aarch64-linux-musl"
    else if hp.isRiscV64 then
      "riscv64-linux-musl"
    else
      throw "nix-badge: unsupported target ${hp.system}";
in
pkgs.buildPackages.stdenv.mkDerivation {
  pname = "nix-badge";
  version = "0.2";

  src = ./nix-badge;

  nativeBuildInputs = [ pkgs.buildPackages.zig ];

  dontConfigure = true;

  # Zig wants a writable HOME + global cache. The build is zero-dependency
  # (IronStyle: `zig build` is the only tool), so it runs fully offline in the
  # sandbox. `zig build` cross-compiles to the target and installArtifact + the
  # --prefix put the static binary at $out/bin/nix-badge.
  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    zig build -Dtarget=${zigTarget} -Doptimize=ReleaseSafe --prefix "$out"
    runHook postBuild
  '';

  # `zig build --prefix $out` already installed to $out/bin.
  dontInstall = true;

  meta = {
    description = "Badge control tool for the Milk-V Duo S NixOS badge (Zig)";
    platforms = pkgs.lib.platforms.linux;
  };
}
