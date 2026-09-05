# nix-badge: the badge's own control tool (Zig).
#
# One static binary for the badge-specific functions:
#   nix-badge leds ...    the WS2812 chain on SPI3 (service, initrd onward)
#   nix-badge core ...    the ARM/RISC-V select latch (U2 74AUP1G175)
#   nix-badge power       rail voltages (sysfs iio-rescale + power_supply) + fault GPIOs
#   nix-badge mmio ...    32-bit /dev/mem peek/poke for register bring-up
#   nix-badge bling ...   the OLED bling engine (Bad Apple + screens)
#
# Built with Zig and cross-compiled to a STATIC musl binary.
#
# Static is deliberate. A NixOS host has no /lib/ld-linux-*.so.1 interpreter, so a
# dynamically linked cross binary would not run, while a static musl binary needs
# no interpreter and keeps the closure empty. The LED service also has to keep
# running across switch_root, and a static binary at its store path resolves the
# same before and after, with no libc to find. Zig cross-compiles both cores on
# the build host, so there is no QEMU and no target toolchain.
#
# The fix evaluator is NOT passed in from here. build.zig.zon pins psyclyx/fix as
# an ordinary Zig dependency, and build.zig patches the fetched tree itself: it
# overlays the fetch-less fetcher stubs and applies fix-stub/*.patch. `zig.fetchDeps`
# below fetches that dependency in a separate fixed-output derivation, so this
# build still runs with no network. The stubs are what keep curl and libgit2 out of
# the closure: every network fetch in the embedded evaluator returns
# error.FetchUnsupported.
{
  pkgs,
  # Link the upstream Nix C API as a SECOND per-frame evaluator beside fix, so the
  # two can be compared on the same content. aarch64 only: that evaluator runs on
  # the arm core and the riscv core stays on fix.
  nixEval ? true,
  # Link the Nix C API DYNAMICALLY (shared nixComponents .so's + a patchelf'd NixOS glibc
  # interpreter/rpath) instead of the static-musl archive link. The static LLD crunch of
  # ~200 MB of .a's is the build's ~15-minute long pole; the dynamic link is seconds, so
  # every Zig iteration on the oled runtime stops paying it. DYNAMIC BINARIES MUST NOT go
  # in the initrd (the LED painter survives switch_root precisely because the static
  # binary resolves with no interpreter): the bling/initrd instance stays static, only the
  # stage-2 oled service uses this. aarch64 + nixEval only.
  nixDynamic ? false,
}:
let
  hp = pkgs.stdenv.hostPlatform;
  lib = pkgs.lib;
  # The dynamic variant targets glibc (the shared nixComponents are glibc builds); pin
  # zig's glibc-stub version to nixpkgs' major.minor so linked symbol versions exist at
  # runtime. Everything else stays static musl (see the header note).
  wantDynamic = nixDynamic && nixEval && hp.isAarch64;
  glibcMM = lib.versions.majorMinor pkgs.glibc.version;
  zigTarget =
    if hp.isAarch64 then
      (if wantDynamic then "aarch64-linux-gnu.${glibcMM}" else "aarch64-linux-musl")
    else if hp.isRiscV64 then
      "riscv64-linux-musl"
    else
      throw "nix-badge: unsupported target ${hp.system}";

  # ---- Nix C API backend (aarch64 only) --------------------------------------------------
  wantNix = nixEval && hp.isAarch64;
  # The split C API components: static -> aarch64-musl-static archives (the proven
  # ~15-minute LLD link); dynamic -> the ordinary shared glibc builds (cache-served,
  # linked in seconds; deps resolve transitively through each .so's own baked rpath).
  nixComps =
    if wantDynamic then
      pkgs.nixVersions.nixComponents_2_34
    else
      pkgs.pkgsStatic.nixVersions.nixComponents_2_34;
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

  # One flattened nix-expr-c.pc for Zig's pkg-config query to answer from.
  #
  # Zig calls `pkg-config nix-expr-c --cflags --libs`, with no --static, and keeps
  # only the -I, -L, -l and -D arguments from the answer. The component .pc files
  # as shipped do not survive that: the C++ libraries this needs sit in
  # `Requires.private`, which a query without --static never expands, and the
  # expansion emits some dependencies as absolute .a paths, which Zig's parser
  # drops. Filtering the rest is wanted, because these files also carry
  # `-Wl,--wrap`, which zig cc rejects.
  #
  # So resolve the whole graph ONCE here, at packaging time, and write the result
  # into a single file's `Cflags` and `Libs`. Zig's plain query then gets the
  # complete answer. Placing this directory first on PKG_CONFIG_PATH means it
  # answers for nix-expr-c ahead of the real component.
  #
  # The patched headers come first in `Cflags`, so the copies with the C23
  # attributes removed win over the originals.
  nixEvalPkgConfig = pkgs.buildPackages.runCommand "nix-badge-nix-expr-c-pc" { } ''
    export PKG_CONFIG_PATH=""
    for p in $(cat ${nixClosure}/store-paths); do
      for d in "$p/lib/pkgconfig" "$p/share/pkgconfig"; do
        [ -d "$d" ] && PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$d"
      done
    done
    export PKG_CONFIG_PATH="''${PKG_CONFIG_PATH#:}"
    pkgconfig=${pkgs.pkgsBuildBuild.pkg-config}/bin/pkg-config

    cflags="-I${nixExprCHeaders}/include $("$pkgconfig" ${staticFlag} --cflags nix-expr-c)"

    # Rewrite each absolute archive into a -L and -l pair naming the same file, so
    # it survives Zig's argument filter. Order and repeats are preserved, because
    # the aws components reference each other in a cycle.
    #
    # The pair drops the "lib" prefix and the ".a" suffix rather than using the
    # linker's -l:<file> form, which Zig does not parse: it reads the whole
    # ":libfoo.a" as a library name and then looks for a lib:libfoo.a to link.
    # Only the archive exists in these directories, so a plain -l finds it.
    libs="-L$out/lib"
    for arg in ${extraLibDirFlags} $("$pkgconfig" ${staticFlag} --libs nix-expr-c) ${cxxRuntimeFlags}; do
      case "$arg" in
        /*.a)
          base=''${arg##*/}
          base=''${base#lib}
          libs="$libs -L''${arg%/*} -l''${base%.a}"
          ;;
        *) libs="$libs $arg" ;;
      esac
    done

    mkdir -p $out/lib/pkgconfig
    ${lib.optionalString (!wantDynamic) ''
      cp "$(find ${nixCcLib} -name libstdc++.a | head -1)" $out/lib/libnixbadge_cxx.a
      cp "$(find ${nixCcMain} -name libgcc.a | head -1)" $out/lib/libnixbadge_gcc.a
      chmod +w $out/lib/libnixbadge_cxx.a $out/lib/libnixbadge_gcc.a
    ''}
    cat > $out/lib/pkgconfig/nix-expr-c.pc <<EOF
    Name: nix-expr-c
    Description: The Nix C API, resolved for nix-badge
    Version: ${nixExprC.version}
    Cflags: $cflags
    Libs: $libs
    EOF
  '';

  # `--static` pulls in Requires.private, which is where the C++ libraries live.
  # The dynamic link needs none of it: each .so finds its own dependencies through
  # the rpath baked into it.
  staticFlag = lib.optionalString (!wantDynamic) "--static";

  # The library directories pkg-config omits, for four dependencies whose default
  # output holds no lib directory, and the C++ runtime archives, which no .pc file
  # names at all. libstdc++ is the C++ runtime and libgcc carries the unwinder.
  extraLibDirFlags = lib.optionalString (!wantDynamic) (
    lib.concatMapStringsSep " " (d: "-L${d}") nixExtraLibDirs
  );
  # The C++ runtime is linked under private names.
  #
  # Zig's command line treats `stdc++` as one of its libc++ spellings and turns
  # `-lstdc++` into "link LLVM's libc++" instead of "find libstdc++.a". These
  # components are built against gcc's libstdc++, and the two are not
  # ABI-compatible, so that substitution ends in undefined `std::__cxx11` symbols.
  # Copying the archives under names Zig has no opinion about links the real ones.
  cxxRuntimeFlags = lib.optionalString (!wantDynamic) "-lnixbadge_cxx -lnixbadge_gcc";

  nixArg = lib.optionalString wantNix "-Dnix-eval=true";
in
pkgs.buildPackages.stdenv.mkDerivation (finalAttrs: {
  pname = "nix-badge";
  version = "0.2";

  # Zig's build artifacts are kept out of this by .gitignore, which is what the
  # flake's source copy honours. That matters beyond size: `.zig-cache` holds
  # already-resolved dependencies, and a source copy carrying it makes
  # `zig build --fetch` believe there is nothing left to fetch, which leaves the
  # dependency derivation below empty.
  src = ./nix-badge;

  # The Zig dependencies build.zig.zon pins, fetched in their own fixed-output
  # derivation. That is the only step allowed to reach the network, and the build
  # phase links it in as Zig's package directory before it builds anything.
  #
  # This hash covers every pinned dependency, so it changes whenever build.zig.zon
  # does. `nix build` reports the expected value when it no longer matches.
  zigDeps = pkgs.buildPackages.zig.fetchDeps {
    inherit (finalAttrs) pname version src;
    hash = "sha256-TRytzmJv2GkyRn7+sQBUhKtaNJ2NxX/0tnKBCufdtLU=";
  };

  # pkg-config is not in nativeBuildInputs on purpose. Its cross setup hook
  # prefixes the binary name and rewrites PKG_CONFIG_PATH, and the buildPhase
  # points Zig at a specific pkg-config and a specific search path instead.
  #
  # `patch` comes from stdenv, and build.zig uses it to apply the fix patches.
  nativeBuildInputs = [ pkgs.buildPackages.zig ];

  # zig's setup hook owns the configure phase: it creates ZIG_GLOBAL_CACHE_DIR and
  # then runs this, which is where the fetched dependencies become Zig's package
  # directory. `dontConfigure` must stay off, or that phase never runs.
  postConfigure = ''
    ln -s "${finalAttrs.zigDeps}" "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  # `zig build` cross-compiles to the target, and installArtifact plus --prefix
  # put the binary at $out/bin.
  buildPhase = ''
    runHook preBuild

    ${lib.optionalString wantNix ''
      # build.zig links the Nix C API with linkSystemLibrary, so Zig runs
      # pkg-config itself and takes the include and library flags from its answer.
      # `nixEvalPkgConfig` has already reduced the component graph to one
      # nix-expr-c.pc, so all this build has to do is point Zig at it.
      #
      # Zig looks the tool up through $PKG_CONFIG, which is set here rather than
      # by putting pkg-config in nativeBuildInputs: its cross setup hook prefixes
      # the binary name and rewrites PKG_CONFIG_PATH, and both fight the single
      # generated .pc file this build wants answered.
      export PKG_CONFIG="${pkgs.pkgsBuildBuild.pkg-config}/bin/pkg-config"
      export PKG_CONFIG_PATH="${nixEvalPkgConfig}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
      echo "nix-badge: linking the Nix C API backend through pkg-config"
    ''}

    zig build -Dtarget=${zigTarget} -Doptimize=ReleaseSafe ${nixArg} --prefix "$out"

    ${lib.optionalString wantDynamic ''
      # NixOS has no /lib/ld-linux-*.so.1, so point the binary at nixpkgs' aarch64
      # loader and bake an rpath covering the libraries it names directly: the nix
      # C API components, libstdc++, and glibc. Each nix shared library then finds
      # its own dependencies through the rpath baked into it.
      #
      # The store paths written into the ELF are what keep nix from garbage
      # collecting those shared libraries out from under this package.
      RPATH="${
        lib.concatStringsSep ":" (
          map (p: "${lib.getLib p}/lib") [
            nixExprC
            nixStoreC
            nixUtilC
            nixFetchersC
            pkgs.stdenv.cc.cc
            pkgs.glibc
          ]
        )
      }"
      ${pkgs.buildPackages.patchelf}/bin/patchelf \
        --set-interpreter ${pkgs.glibc}/lib/ld-linux-aarch64.so.1 \
        --set-rpath "$RPATH" "$out/bin/nix-badge"
      echo "nix-badge: set the dynamic interpreter and rpath"
    ''}

    # ReleaseSafe embeds zig's bundled musl/std SOURCE PATHS in panic/debug
    # strings, which retains the entire zig package -- and through it the
    # clang/llvm libs, ~3.8 GB -- in the badge system closure. Those paths are
    # only ever PRINTED in panic messages, so mangle the store hash and let nix
    # drop the reference (panic traces show a defaced path; nothing dereferences
    # it). This alone halves the SD image's system closure.
    ${pkgs.buildPackages.removeReferencesTo}/bin/remove-references-to \
      -t ${pkgs.buildPackages.zig} "$out/bin/nix-badge"
    runHook postBuild
  '';

  # `zig build --prefix $out` already installed to $out/bin.
  dontInstall = true;

  meta = {
    description = "Badge control tool for the Milk-V Duo S NixOS badge (Zig)";
    platforms = pkgs.lib.platforms.linux;
  };
})
