{
  lib,
  jq,
  stdenv,
  writeShellApplication,
  esp-idf,
  target,
  zig,
  flakever,
  mkShell,
  runCommand,
  nukeReferences,
}:

let
  patchIdf = ''
    (
      cd idf/components/lwip/lwip
      if [ ! -f ip4_napt.patched ]; then
        patch -Np1 -i ${managed_components}/espressif__iot_bridge/patch/ip4_napt.patch
        touch ip4_napt.patched
      fi
    )
  '';

  shell = mkShell {
    name = "nixbadge-${target}-dev-shell";
    packages = [
      esp-idf
      zig
    ];
    inherit target;
    shellHook = ''
      cd src

      rm -rf idf
      cp -a --no-preserve=ownership $IDF_PATH idf
      chmod -R u+w idf

      export IDF_PATH=$(readlink -e idf)

      if [ ! -f sdkconfig ]; then
        idf.py set-target $target
      fi

      ${patchIdf}
    '';
  };

  nvs =
    runCommand "nvs.bin"
      {
        src = ../../src;

        nativeBuildInputs = [
          esp-idf
        ];
      }
      ''
        runPhase unpackPhase
        sh scripts/gen_nvs.sh \
          --cache-cert=${./cache.nixos.lv.pem} \
          --cache-upstream=cache.nixos.lv \
          --router-ssid=NixVegas \
          --router-passwd=RebuildTheWorld \
          --output=$out
      '';

  flash = writeShellApplication {
    name = "flash";
    derivationArgs = {
      inherit (flakever) version;
    };
    text = ''
      set -euo pipefail

      script="$(dirname "''${BASH_SOURCE[0]}")"
      cd "$script/../libexec/nixbadge/build"

      chip=""
      stub=""
      before=""
      after=""

      eval "$(
        jq -r '.extra_esptool_args | to_entries | map("\(.key)=\(.value|@sh)") | .[]' "flasher_args.json"
      )"
      stubarg=""
      if [ "$stub" = "false" ]; then
        stubarg="--no-stub"
      fi

      set -x
      exec ${esp-idf}/python-env/bin/python3 -m esptool "$@" \
        --chip "$chip" \
        --before "$before" --after "$after" \
        $stubarg write_flash "@flash_args" 0x9000 ${nvs}
    '';

    runtimeInputs = [
      esp-idf
      jq
    ];
  };

  console = writeShellApplication {
    name = "console";
    derivationArgs = {
      inherit (flakever) version;
    };
    text = ''
      set -euo pipefail
      exec ${esp-idf}/python-env/bin/python3 -m esp_idf_monitor "$@"
    '';
    runtimeInputs = [
      esp-idf
    ];
  };

  zigDeps = zig.fetchDeps {
    pname = "nixbadge";
    inherit (flakever) version;
    src = ../../src;
    fetchAll = true;
    hash = "sha256-GxDDvyVHaTn1uvvUbnd9FlfU+8BQEVzIuQq2w4DEJe8=";
  };

  managed_components =
    runCommand "nixbadge-components"
      {
        src = ../../src;
        inherit target;

        nativeBuildInputs = [
          esp-idf
        ];

        outputHash = "sha256-t8nGtWoZ7DGPk70KHEVMAL/mi9aUkpENtwsUVUjtCPw=";
        outputHashAlgo = "sha256";
        outputHashMode = "recursive";
      }
      ''
        runPhase unpackPhase

        mkdir .temp
        export HOME="$(realpath .temp)"

        idf.py set-target $target
        cp -r managed_components $out
      '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "nixbadge-${finalAttrs.target}";
  inherit (flakever) version;

  outputs = [
    "out"
    "flash"
  ];

  # See $IDF_PATH/examples for many examples.
  src = ../../src;

  nativeBuildInputs = [
    zig
    nukeReferences
  ];

  buildInputs = [
    esp-idf
  ];

  inherit target;

  preConfigure = ''
    # The build system wants to create a cache directory somewhere in the home
    # directory, so we make up a home for it.
    mkdir .temp
    export HOME="$(realpath .temp)"

    cp -a --no-preserve=ownership $IDF_PATH idf
    chmod -R u+w idf
    export IDF_PATH=$(readlink -e idf)

    cp -r ${managed_components} managed_components
    ${patchIdf}

    # Populate the Zig package cache from the FOD `zig.fetchDeps` produced for
    # us (build.zig.zon dependencies, baked into a single derivation).
    export ZIG_GLOBAL_CACHE_DIR="$HOME/zig-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"
    cp -rLT "${zigDeps}" "$ZIG_GLOBAL_CACHE_DIR/p"
    chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  configurePhase = ''
    runHook preConfigure
    idf.py set-target $target
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    idf.py build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp build/nixbadge.elf build/nixbadge.bin $out/
    nuke-refs $out/nixbadge.elf
    nuke-refs $out/nixbadge.bin
    runHook postInstall
  '';

  dontFixup = true;

  doDist = true;

  allowedReferences = [
    flash
    console
  ];

  distPhase = ''
    runHook preDist

    # Stage just the files the flash script reads at runtime into $flash so
    # the output is self-contained.
    build_dir=$flash/libexec/nixbadge/build
    mkdir -p $flash/bin "$build_dir/bootloader" "$build_dir/partition_table"
    ln -s ${lib.getExe flash} $flash/bin/
    ln -s ${lib.getExe console} $flash/bin/

    cp build/flasher_args.json "$build_dir/"
    cp build/flash_args "$build_dir/"
    cp build/nixbadge.bin "$build_dir/"
    cp build/bootloader/bootloader.bin "$build_dir/bootloader/"
    cp build/partition_table/partition-table.bin "$build_dir/partition_table/"

    # Scrub embedded /nix/store/... references from the staged binaries.
    nuke-refs "$build_dir/nixbadge.bin"
    nuke-refs "$build_dir/bootloader/bootloader.bin"
    nuke-refs "$build_dir/partition_table/partition-table.bin"

    runHook postDist
  '';

  passthru = {
    inherit shell nvs;
  };
})
