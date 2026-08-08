# Architecture-agnostic system config for the Milk-V Duo S badge.
# Everything here is identical whether the ARM (aarch64) or RISC-V (riscv64)
# large core boots. Nothing arch-specific belongs in this file.
{ pkgs, lib, ... }:
{
  networking.hostName = "nixbadge-duos";

  # The SD image ships an ext4 root sized exactly to the store closure, so a
  # fresh card boots 100% full no matter how large the card is. These two
  # options fix that on every boot, in order:
  #   growPartition   -> growpart.service extends the last MBR partition
  #                      (NIXOS_ROOT, mmcblk0p2) to the end of the card.
  #   x-systemd.growfs -> systemd-growfs-root.service then grows the ext4 to
  #                      fill the new partition, online.
  # Both are no-ops once the card is full, so they are safe to leave on.
  # The root mount lives here, not in core-*.nix, because it is identical on
  # both cores and the two systems share one root partition.
  boot.growPartition = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_ROOT";
    fsType = "ext4";
    options = [ "x-systemd.growfs" ];
  };

  # 24 WS2812 LEDs on the SPI3 MOSI line (40-pin header pin 19). The service
  # starts in the initrd and keeps running after switch_root, so the ring shows
  # life from very early boot. See modules/duo-s/leds.nix for the option set and
  # the nixbadge-leds CLI.
  nixbadge.leds = {
    enable = true;
    count = 24;
  };

  # Networking via NetworkManager: it manages eth0 (auto-connects wired) and
  # wlan0 once the AIC8800 WiFi comes up. wpa_supplicant backend because the
  # AIC8800 is a fullMAC driver that iwd handles poorly. NetworkManager does its
  # own DHCP, so the scripted dhcpcd is off. Public nameservers as a fallback so
  # resolution works even if DHCP hands over no resolver.
  networking.networkmanager = {
    enable = true;
    wifi.backend = "wpa_supplicant";
  };
  networking.useDHCP = false;
  networking.nameservers = lib.mkDefault [
    "1.1.1.1"
    "9.9.9.9"
  ];

  # Minimal headless userland. Flesh out with the badge services later.
  users.users.badge = {
    isNormalUser = true;
    extraGroups = [ "wheel" "dialout" "gpio" "networkmanager" ];
    # TODO: replace with a real key before flashing.
    openssh.authorizedKeys.keys = [ ];
    initialPassword = "nixbadge";
  };

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };

  environment.systemPackages = with pkgs; [
    htop
    i2c-tools
    usbutils
  ];

  # Keep the closure small, this is going on an SD card.
  documentation.enable = lib.mkDefault false;
  documentation.nixos.enable = lib.mkDefault false;

  system.stateVersion = "26.05";
}
