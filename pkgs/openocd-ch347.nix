# OpenOCD with the CH347 JTAG adapter driver, for debugging the badge over the
# J1 CH347T port. nixpkgs openocd 0.12.0 predates the ch347 driver, so build a
# recent mainline snapshot with --enable-ch347.
#
# Usage: scan the C906 TAP (only answers on a riscv boot -- JTAG_CPU is the C906):
#   openocd -c "adapter driver ch347" -c "adapter speed 1000" \
#           -c "transport select jtag" -c "reset_config none" \
#           -c "jtag newtap c906 cpu -irlen 5 -expected-id 0" -c "init" -c "scan_chain"
{ pkgs }:
pkgs.openocd.overrideAttrs (o: {
  version = "unstable-2741efc6";
  src = pkgs.fetchFromGitHub {
    owner = "openocd-org";
    repo = "openocd";
    rev = "2741efc60ae03e2a5fea707685df59a3c4256437";
    hash = "sha256-B2VKz9RBxM2/2nGvlxCqEuo+9oEDdDfjG1zXrQFPs4c=";
    fetchSubmodules = true;
  };
  nativeBuildInputs = (o.nativeBuildInputs or [ ]) ++ [
    pkgs.autoreconfHook
    pkgs.which
    pkgs.git
    pkgs.texinfo
  ];
  configureFlags = (o.configureFlags or [ ]) ++ [
    "--enable-ch347"
    "--disable-doxygen-html"
  ];
})
