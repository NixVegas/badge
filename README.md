# Nix Badge

Hardware features:

- 12x WS2812 LEDs connected to IO14 (with a pleasant RGB fade pattern from the RMT)
    - Most of this was taken from Espressif's examples: [here](https://github.com/espressif/esp-idf/tree/master/examples/peripherals/rmt/led_strip_simple_encoder) and [here](https://github.com/espressif/esp-idf/tree/master/examples/peripherals/rmt/led_strip).
- Button connected to IO3
- Status LED connected to IO15
- SDET (SD Detect) pin to IO8
- VSEL2 pin (VSEL / 2) to IO2 (used for reading battery level over ADC)
- Serial obviously works over USB

## Known issues

**The SD card has 3v3 and GND wired backwards on v1.0 of the badge hardware. It may kill your SD card. There's no fix for this badge that doesn't involve cutting and soldering wires. :-(**

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

## Starting the badge mesh

Hold the button while booted. Default network is `NixBadge_XXXXXX`, password is 12345678.

## Substituting over the mesh

- Connect to the wifi network listed above. You will be assigned a DHCP address.
- `nix-shell --option substituters http://192.168.5.1:1008 -p hello` (just set the last octet to 1)

Sadly, it won't be cached because the SD slot is borked. It's also pretty slow. By default, it connects to the NixVegas wifi for an upstream and substitutes from https://cache.nixos.lv.

You can use the badge as a generic router, too. It will also be slow.

## Automated testing

Looks like Espressif has a test harness [using pytest](https://github.com/espressif/pytest-embedded). Soon?
