{
  lib,
  jq,
  stdenv,
  writeShellApplication,
  esp-idf,
  target,
  zig,
  mkShell,
  runCommand,
}:

let
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
    '';
  };

  nvs = runCommand "nvs.bin" {
    src = ../../src;

    nativeBuildInputs = [
      esp-idf
    ];
  } ''
    runPhase unpackPhase
    sh scripts/gen_nvs.sh --cache-cert=${./cache.nixos.org.pem} --output=$out
  '';

  flash = writeShellApplication {
    name = "flash";
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
    text = ''
      set -euo pipefail
      exec ${esp-idf}/python-env/bin/python3 -m esp_idf_monitor "$@"
    '';
    runtimeInputs = [
      esp-idf
    ];
  };

  managed_components = runCommand "nixbadge-components" {
    src = ../../src;
    inherit target;

    nativeBuildInputs = [
      esp-idf
    ];

    outputHash = "sha256-SlOwixJ9nipYZOad4BIhXjX9l2i3QeRrTXNr7gRgaQY=";
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
  } ''
    runPhase unpackPhase

    mkdir .temp
    export HOME="$(realpath .temp)"

    idf.py set-target $target
    cp -r managed_components $out
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "nixbadge-${finalAttrs.target}";
  version = "0.1";

  outputs = [
    "out"
    "flash"
  ];

  # See $IDF_PATH/examples for many examples.
  src = ../../src;

  nativeBuildInputs = [
    zig
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

    (cd idf/components/lwip/lwip; patch -Np1 -i ${managed_components}/espressif__iot_bridge/patch/ip4_napt.patch)
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
    cp -a build $out
    runHook postInstall
  '';

  dontFixup = true;

  doDist = true;

  distPhase = ''
    runHook preDist

    mkdir -p $flash/bin $flash/libexec/nixbadge
    ln -s ${lib.getExe flash} $flash/bin/
    ln -s ${lib.getExe console} $flash/bin/
    ln -s $out $flash/libexec/nixbadge/build

    runHook postDist
  '';

  passthru = {
    inherit shell nvs;
  };
})
