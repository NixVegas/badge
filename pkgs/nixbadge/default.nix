{
  lib,
  jq,
  stdenv,
  writeShellApplication,
  esp-idf,
  target,
  mkShell,
}:

let
  shell = mkShell {
    name = "nixbadge-${target}-dev-shell";
    packages = [
      esp-idf
    ];
    inherit target;
    shellHook = ''
      export IDF_COMPONENT_MANAGER=0
      cd src
      if [ ! -f sdkconfig ]; then
        idf.py set-target $target
      fi
    '';
  };

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
        $stubarg write_flash "@flash_args"
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

  buildInputs = [
    esp-idf
  ];

  inherit target;

  preConfigure = ''
    # The build system wants to create a cache directory somewhere in the home
    # directory, so we make up a home for it.
    mkdir .temp
    export HOME="$(realpath .temp)"

    # idf-component-manager wants to access the network, so we disable it.
    export IDF_COMPONENT_MANAGER=0
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
    inherit shell;
  };
})
