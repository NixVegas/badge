# nix-badge: the badge's own control tool.
#
# One binary for the badge-specific functions:
#   nix-badge leds ...   the WS2812 chain on SPI3
#   nix-badge core ...   the ARM/RISC-V select latch (U2 74AUP1G175)
#
# The LED half runs as a service from the initrd onwards, so the binary must
# keep running across switch_root. It links against nothing outside its own
# closure and uses no wrapper script: makeInitrdNG puts store paths at their
# real /nix/store location inside the initramfs, so the interpreter and libc
# resolve the same before and after switch_root.
{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "nix-badge";
  version = "0.1";

  src = ./nix-badge;

  dontConfigure = true;

  # No systemd reference on purpose. The CLI only writes the runtime config and
  # the running service notices the new mtime, so nothing here calls systemctl.
  # That keeps the closure to glibc alone. The GPIO work uses the kernel's
  # character-device uAPI directly, so libgpiod is not a build dependency
  # either.
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -std=c11 -o nix-badge nix-badge.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nix-badge "$out/bin/nix-badge"
    runHook postInstall
  '';

  meta = {
    description = "Badge control tool for the Milk-V Duo S NixOS badge";
    platforms = pkgs.lib.platforms.linux;
  };
}
