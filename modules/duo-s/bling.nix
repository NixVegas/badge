# OLED "bling engine": the nix-badge `bling` daemon drives the SAO SSD1306 with
# Bad Apple (the default wake screen) plus battery/load/power/clock screens, and
# cycles LED patterns on the USER button / SIGUSR1, OLED screens on a long press /
# SIGUSR2.
#
# It owns the OLED + USER button + signals. The WS2812 ring stays with the
# leds.nix painter (which starts in the initrd and survives switch_root, the
# flicker-free early-boot path) -- bling only rewrites /var/lib/nix-badge/leds.conf
# to change the ring's pattern, and the painter hot-reloads it. So this service
# does NOT touch spidev and cannot disturb the ring's boot animation.
{ pkgs, lib, ... }:
let
  nixBadge = import ../../pkgs/badge/nix-badge.nix { inherit pkgs; };
  # The Bad Apple blob is arch-independent DATA (a packed 1-bit frame file), but
  # producing it runs ffmpeg + a tiny C packer. Build those on the build host
  # (buildPackages), not the target -- with target pkgs a cross build would try
  # to run aarch64 ffmpeg under emulation to transcode 3.5 min of video, which is
  # absurdly slow / breaks the build. The output bytes are identical either way.
  badApple = import ../../pkgs/badge/badapple { pkgs = pkgs.buildPackages; };
in
{
  systemd.services.nixbadge-bling = {
    description = "nixbadge OLED bling engine (Bad Apple + screens)";
    wantedBy = [ "multi-user.target" ];
    # The i2c-1 bus, the SARADC IIO device and /dev/gpiochip* (the USER button)
    # are all up via udev well before multi-user; no explicit ordering needed
    # beyond the default basic.target.
    serviceConfig = {
      # Runs as root: opens /dev/i2c-1 (0x3c), reads the SARADC sysfs for the
      # battery/rail screens, reads /dev/gpiochip* for the USER button, and
      # rewrites /var/lib/nix-badge/leds.conf to cycle the ring's pattern.
      ExecStart = "${nixBadge}/bin/nix-badge bling --badapple ${badApple}/badapple.bin";
      # bling exits 0 when the panel is absent (a core that does not mux the SAO
      # i2c, so /dev/i2c-1 has nothing at 0x3c): that is a clean no-op, not a
      # failure, so Restart=on-failure will not spin on such a core. A real fault
      # (mid-run i2c error) exits nonzero and we retry.
      Restart = "on-failure";
      RestartSec = 2;
      # Shared with the leds painter + the SARADC calibrate service; ensures
      # /var/lib/nix-badge exists for the leds.conf rewrite.
      StateDirectory = "nix-badge";
    };
  };
}
