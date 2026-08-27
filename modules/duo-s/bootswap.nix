# Boot-core swap on a long BOOT-button hold. `nix-badge bootswap` watches the
# btn-boot-n GPIO; holding it for >=3s latches the OTHER core (74AUP1G175) and
# reboots -- but only when the board switch is on AUTO (it re-reads the strap and
# reverts if the switch overrides the latch). btn-boot-n is dual-purpose (it's
# also the ROM recovery strap), so this makes the boot button useful in Linux;
# the dedicated USER button (PWR_GPIO1) drives the bling engine separately.
{ pkgs, lib, config, ... }:
let
  nixBadge = import ../../pkgs/badge/nix-badge.nix { inherit pkgs; };
in
{
  systemd.services.nixbadge-bootswap = {
    description = "nixbadge boot-core swap on BOOT-button hold";
    wantedBy = [ "multi-user.target" ];
    # systemctl (for the clean reboot) + the gpiochips (btn-boot-n and the
    # core-select latch) are up by multi-user; the daemon falls back to reboot(2)
    # if systemctl is unreachable.
    path = [ config.systemd.package ];
    serviceConfig = {
      # Root: reads btn-boot-n, drives the core-select latch, and reboots.
      ExecStart = "${nixBadge}/bin/nix-badge bootswap";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
