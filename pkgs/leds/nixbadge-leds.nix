# nixbadge-leds: the WS2812 driver that runs from the initrd onwards.
#
# The binary must keep running across switch_root, so it links against nothing
# outside its own closure and it uses no wrapper script. The systemctl path is
# baked in at compile time, which keeps the result a real ELF file. A shell
# wrapper would need a shell in the initrd.
{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "nixbadge-leds";
  version = "0.1";

  src = ./nixbadge-leds;

  dontConfigure = true;

  # Dynamically linked on purpose. makeInitrdNG puts store paths at their real
  # /nix/store location inside the initramfs, so the interpreter and libc
  # resolve the same before and after switch_root. A static link would need
  # glibc.static for every target, which buys nothing here.
  # No systemd reference on purpose. The CLI only writes the runtime config
  # and the running service notices the new mtime, so nothing here has to call
  # systemctl. That keeps the closure to glibc alone.
  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -std=c11 \
      -o nixbadge-leds nixbadge-leds.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nixbadge-leds "$out/bin/nixbadge-leds"
    runHook postInstall
  '';

  meta = {
    description = "WS2812 LED service for the Milk-V Duo S badge";
    platforms = pkgs.lib.platforms.linux;
  };
}
