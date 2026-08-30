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
  # Link the upstream Nix C API (libnixexpr) as a SECOND per-frame evaluator backend
  # alongside fix, for an A/B comparison. aarch64 only (the evaluator runs on the arm core;
  # riscv stays fix-only). The static-link recipe is proven -- see
  # docs/superpowers/plans/2026-08-29-nix-c-api-backend.md.
  nixEval ? true,
}:
let
  hp = pkgs.stdenv.hostPlatform;
  lib = pkgs.lib;
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
        # GC missed-edge fix (#34), DEFINITIVE: the minor mark never seeded the pinned
        # pre-arming region, so a live young child reachable only from a pinned parent (the
        # compiled screen lambda + its captured lib, which acquire new young referents every
        # frame and are NOT captured by the write barrier) was swept -> "minor mark not closed
        # -- missed edge" panic on draw-heavy screens. seedPinnedRegionMinor walks the pinned
        # region young-gated in both minor branches (O(pinned edges) ~ 8192 on the badge; the
        # major already did the equivalent). Root-caused via fix-gc-repro; supersedes the
        # earlier young-source-barrier attempt (which couldn't help -- the barrier never fires
        # for these edges -- and bloated the remset into multi-second collects).
        patch -p1 -d $out < ${./nix-badge/fix-stub/gc-seed-pinned-minor.patch}
        # ...and the airtight belt (#34): force MAJOR-only collection. seedPinnedRegionMinor
        # covers PINNED parents but the panic recurs with POST-arming tenured parents; a major
        # rebuilds old/young from the true reachable set so it cannot sweep a live child at all.
        # Enabled per-Engine via ev.setAlwaysMajor(true) in fixeval.zig.
        patch -p1 -d $out < ${./nix-badge/fix-stub/gc-always-major.patch}
        # Scope the Object-diet sizeOf asserts to x86_64: they fail on aarch64
        # ReleaseFast (alignment differs), and the badge's production fix graph is
        # ReleaseFast (gc_debug=ReleaseSafe would disable object-slot reuse ->
        # ~160 leaked Object headers/frame; see build.zig fix_optimize).
        patch -p1 -d $out < ${./nix-badge/fix-stub/gc-sizeof-diet-x86only.patch}
        # riscv64 support: a riscv64 fiber contextSwitch + MAP_NORESERVE + seq_cst
        # fence + hugetlb NORESERVE, so the RISC-V core gets the full evaluator too.
        # Source-only + arch-gated at comptime, so the hunks are inert on aarch64 /
        # x86_64; applies on every build. (qemu-proven via fix-selftest.)
        patch -p1 -d $out < ${./nix-badge/fix-stub/riscv64-fiber.patch}
      '';

  fixArg = pkgs.lib.optionalString (patchedFixSrc != null) "-Dfix-src=${patchedFixSrc}";

  # ---- Nix C API backend (aarch64 only) --------------------------------------------------
  wantNix = nixEval && hp.isAarch64;
  # The split C API components (aarch64-musl-static): nix-expr-c pulls in nix-expr/store/util
  # + boost + boehm-gc; the -c siblings carry the other nix_api_*.h.
  nixComps = pkgs.pkgsStatic.nixVersions.nixComponents_2_34;
  nixExprC = nixComps."nix-expr-c";
  nixStoreC = nixComps."nix-store-c";
  nixUtilC = nixComps."nix-util-c";
  nixFetchersC = nixComps."nix-fetchers-c";
  # closureInfo over the C-API dev+out captures every referenced static-lib + pkgconfig dir
  # (the .pc files reference the sibling component/dep lib dirs).
  nixClosure = pkgs.buildPackages.closureInfo {
    rootPaths = [ nixExprC nixExprC.dev nixStoreC nixStoreC.dev nixUtilC nixUtilC.dev nixFetchersC ];
  };
  # gcc C++ runtime archives (full path): libstdc++.a lives in the cc `lib` output; libgcc.a
  # (with _Unwind_*) in the cc's main output under lib/gcc/<triple>/<ver>/.
  nixCcLib = pkgs.pkgsStatic.stdenv.cc.cc.lib;
  nixCcMain = pkgs.pkgsStatic.stdenv.cc.cc;
  # The 4 static libs whose -L pkg-config --static omits. Use getLib: these packages'
  # DEFAULT output is `bin` (no /lib); the .a lives in the `lib`/`out` output.
  nixExtraLibDirs = map (p: "${lib.getLib p}/lib") [
    pkgs.pkgsStatic.acl
    pkgs.pkgsStatic.bzip2
    pkgs.pkgsStatic.libunistring
    pkgs.pkgsStatic.llhttp
  ];
  # nix_api_{value,expr}.h use C23 `[[deprecated("...")]]` attributes on a couple of typedefs
  # that zig's translate-c (aro) cannot parse ("expected external declaration"). They are
  # pure deprecation markers -- copy the nix-expr-c headers and strip the attributes so
  # @cImport succeeds. (nix-store-c / nix-util-c headers carry no such attributes.)
  nixExprCHeaders = pkgs.buildPackages.runCommand "nix-expr-c-headers-nodeprecated" { } ''
    mkdir -p $out/include
    cp -r ${nixExprC.dev}/include/. $out/include/
    chmod -R +w $out/include
    sed -i 's/\[\[deprecated([^]]*)\]\]//g' $out/include/*.h
  '';
in
pkgs.buildPackages.stdenv.mkDerivation {
  pname = "nix-badge";
  version = "0.2";

  src = ./nix-badge;

  # pkg-config is invoked by full store path in the buildPhase (below), not via
  # nativeBuildInputs -- its cross setup hook prefixes the binary name and rewrites
  # PKG_CONFIG_PATH, both of which fight the manual, absolute-path invocation we need
  # to read the aarch64 nix .pc files.
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

    nixArgs=""
    ${lib.optionalString wantNix ''
      # Nix C API link flags from pkg-config + the closure (the proven static-link recipe).
      PC_DIRS=""
      for p in $(cat ${nixClosure}/store-paths); do
        for d in "$p/lib/pkgconfig" "$p/share/pkgconfig"; do [ -d "$d" ] && PC_DIRS="$PC_DIRS:$d"; done
      done
      export PKG_CONFIG_PATH="''${PC_DIRS#:}"

      NIX_INC="${nixExprCHeaders}/include:${nixStoreC.dev}/include:${nixUtilC.dev}/include"
      # -l names only (the full --libs also carries -Wl,--wrap, which zig cc rejects).
      # A plain NATIVE pkg-config (pkgsBuildBuild -> unprefixed bin/pkg-config); the .pc
      # files carry absolute store paths so no cross/target awareness is needed. The cross
      # buildPackages.pkg-config only ships a target-prefixed binary.
      PKGCONFIG="${pkgs.pkgsBuildBuild.pkg-config}/bin/pkg-config"
      NIX_LIBS=$("$PKGCONFIG" --libs-only-l --static nix-expr-c | tr ' ' '\n' | sed -n 's/^-l//p' | grep . | paste -sd,)
      # -L dirs from pkg-config + the 4 it omits (acl/bz2/unistring/llhttp).
      NIX_LIBDIRS=$( {
        "$PKGCONFIG" --libs-only-L --static nix-expr-c | tr ' ' '\n' | sed -n 's/^-L//p'
        for d in ${builtins.concatStringsSep " " nixExtraLibDirs}; do echo "$d"; done
      } | grep . | sort -u | paste -sd:)
      # Some deps (boost_url, the aws-c-* / aws-crt-cpp S3 stack) appear in the .pc as
      # FULL-PATH .a files, not -l/-L flags, so they must be linked as objects. Preserve
      # pkg-config's order + repeats (circular aws deps). Then the C++ runtime archives:
      # libstdc++.a + libgcc.a (has _Unwind_*).
      NIX_ARCHIVES=$("$PKGCONFIG" --libs --static nix-expr-c | tr ' ' '\n' | grep -E '^/.*\.a$' | paste -sd:)
      STDCPP=$(find ${nixCcLib} -name libstdc++.a 2>/dev/null | head -1)
      LIBGCC=$(find ${nixCcMain} -name libgcc.a 2>/dev/null | head -1)
      NIX_OBJS="$NIX_ARCHIVES:$STDCPP:$LIBGCC"

      nixArgs="-Dnix-include=$NIX_INC -Dnix-libdirs=$NIX_LIBDIRS -Dnix-libs=$NIX_LIBS -Dnix-objs=$NIX_OBJS"
      echo "nix-badge: linking Nix C API backend ($NIX_LIBS)"
    ''}

    zig build -Dtarget=${zigTarget} -Doptimize=ReleaseSafe ${fixArg} $nixArgs --prefix "$out"
    runHook postBuild
  '';

  # `zig build --prefix $out` already installed to $out/bin.
  dontInstall = true;

  meta = {
    description = "Badge control tool for the Milk-V Duo S NixOS badge (Zig)";
    platforms = pkgs.lib.platforms.linux;
  };
}
