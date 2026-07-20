# Architecture-agnostic system config for the Milk-V Duo S badge.
# Everything here is identical whether the ARM (aarch64) or RISC-V (riscv64)
# large core boots. Nothing arch-specific belongs in this file.
{ pkgs, lib, ... }:
{
  networking.hostName = "nixbadge-duos";

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
