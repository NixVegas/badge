# Build one ext4 root holding the UNION of several NixOS systems' closures
# (e.g. an aarch64 and a riscv64 build of the same config sharing one /nix/store).
# Boot selects which system runs via the kernel cmdline init= path.
{ pkgs }:
{ systems, label }:
let
  toplevels = map (s: s.config.system.build.toplevel) systems;
  primary = pkgs.lib.head toplevels;
in
pkgs.callPackage "${pkgs.path}/nixos/lib/make-ext4-fs.nix" {
  storePaths = toplevels;
  volumeLabel = label;
  populateImageCommands = ''
    mkdir -p ./files/sbin
    ln -s ${primary}/init ./files/sbin/init
    mkdir -p ./files/nix/var/nix/profiles
    ln -s ${primary} ./files/nix/var/nix/profiles/system
  '';
}
