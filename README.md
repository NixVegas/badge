# Nix Badge

**HARDWARE SAMPLES ONLY**

## Build

- `nix build ^*` or `nix-build` (note that the `^*` will produce all outputs, as opposed to `nix build` which only produces the firmware)
- `./result-flash/bin/flash -p /dev/ttyACM0`
- `./result-flash/bin/console -p /dev/ttyACM0` (this is just a wrapper around `idf.py monitor`, and you can press ^] to exit)

## Development

- `nix develop` or `nix-shell`
    - This will automatically configure the project as a shellHook, creating `sdkconfig`, and drop you into `src`
- Make some changes
- `idf.py -p /dev/ttyACM0 build flash monitor`
    - Press ^] to exit
