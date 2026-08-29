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
# When `fixSrc` is a psyclyx/fix source tree (threaded through from the flake's
# `inputs.fix` via mkDuoS's specialArgs), nix-badge links fix's `expr` evaluator
# in fetch-less: we overlay the vendored fetch-less fetchers stub onto the pinned
# fix source and pass it as `-Dfix-src`. This is the build FOUNDATION for later
# per-frame Nix eval of LED patterns; it is not yet wired into any runtime loop
# (only the hidden `nix-badge fix-selftest` smoke test uses it). With fixSrc null
# the tool builds exactly as before, minus eval, so callers that do not pass it
# keep working. Either way the build stays fully offline: the patched fix source
# is a local store path, and fix's fetchers are stubbed to error.FetchUnsupported
# so there is NO curl/libgit2/network in the closure.
#
# fix's evaluator runs natively on aarch64/x86_64; riscv64 is added by a vendored
# patch (fix-stub/riscv64-fiber.patch: a riscv64 fiber contextSwitch asm + Context,
# MAP_NORESERVE, a seq_cst fence, and hugetlb NORESERVE), qemu-proven via
# fix-selftest. So BOTH badge cores get the full evaluator; only other host arches
# (for which we do not ship) fall back to eval-less.
{
  pkgs,
  fixSrc ? null,
}:
let
  hp = pkgs.stdenv.hostPlatform;
  zigTarget =
    if hp.isAarch64 then
      "aarch64-linux-musl"
    else if hp.isRiscV64 then
      "riscv64-linux-musl"
    else
      throw "nix-badge: unsupported target ${hp.system}";

  # aarch64 + riscv64 both link fix (riscv via the vendored fiber patch, see the
  # arch note above); ignore fixSrc on any other host arch.
  effectiveFixSrc = if (hp.isAarch64 || hp.isRiscV64) then fixSrc else null;

  # Overlay the vendored fetch-less fetchers stub onto the pinned fix source.
  # The stub files use relative imports (@import("fetch/types.zig")), so they
  # must live inside fix's own src/fetchers/ at build time. runCommand produces
  # a fresh, writable store path; buildPackages so it evaluates on the build
  # host. Only built when fixSrc is provided (and the arch supports it).
  patchedFixSrc =
    if effectiveFixSrc == null then
      null
    else
      pkgs.buildPackages.runCommand "fix-src-fetchless" { } ''
        cp -r ${effectiveFixSrc} $out
        chmod -R +w $out
        cp ${./nix-badge/fix-stub/stub_root.zig} $out/src/fetchers/stub_root.zig
        cp ${./nix-badge/fix-stub/stub_cache.zig} $out/src/fetchers/stub_cache.zig
        # Add Engine.applyValue + Engine.makeAttrs (native apply + native attrs
        # construction): apply a compile-once pattern lambda to a fresh per-frame
        # scope with NO source recompile, so fix mints no new chunk per frame
        # (chunks are permanent GC roots, never collected -- compile-per-frame
        # would leak). The flake pin (2b23db57) matches the patch's base exactly.
        patch -p1 -d $out < ${./nix-badge/fix-stub/native-apply.patch}
        # riscv64 support: a riscv64 fiber contextSwitch + MAP_NORESERVE + seq_cst
        # fence + hugetlb NORESERVE, so the RISC-V core gets the full evaluator too.
        # Source-only + arch-gated at comptime, so the hunks are inert on aarch64 /
        # x86_64; applies on every build. (qemu-proven via fix-selftest.)
        patch -p1 -d $out < ${./nix-badge/fix-stub/riscv64-fiber.patch}
      '';

  fixArg = pkgs.lib.optionalString (patchedFixSrc != null) "-Dfix-src=${patchedFixSrc}";
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
    zig build -Dtarget=${zigTarget} -Doptimize=ReleaseSafe ${fixArg} --prefix "$out"
    runHook postBuild
  '';

  # `zig build --prefix $out` already installed to $out/bin.
  dontInstall = true;

  meta = {
    description = "Badge control tool for the Milk-V Duo S NixOS badge (Zig)";
    platforms = pkgs.lib.platforms.linux;
  };
}
