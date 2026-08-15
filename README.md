# Nix Badge v2

For the PCB, use [our git server](https://git.nixos.lv/NixVegas/pcb)
since it doesn't fit on GitHub anymore.

For the v1 readme, see [v1.md](v1.md).

This README is still very TODO, since this is the first release after DEF CON.

## Hardware features

- Dual-core ARM/RISC-V [Milk-V Duo Module 01](https://milkv.io/docs/duo/getting-started/duo-module-01) (core selected at boot; both ARM and RISC-V boot)
- 24 WS2812 LEDs on SPI3, powered from VSEL rather than the 3.3V buck (deliberately go red glitch-art on low battery)
- AIC8800 WiFi (kernel driver needs a rebase from 5.10; we have the bootrom)
- 0.5 TOPS TPU (works under Debian; drivers need forward-porting)
- DSI → HDMI out via an [Olimex-based](https://github.com/OLIMEX/MIPI-HDMI) bridge (needs a DSI kernel driver)
- USB-C with mode switching
- Serial + JTAG over the CH347
- 10/100 Ethernet
- Battery power (AA cells)
- Voltage-measurement ADCs
- Supercapacitor RTC circuit
- SAO connector (6-pin keyed header)
- OLED connector (4-pin I2C)
- Front pin header for a [Sharp Memory Display](https://www.adafruit.com/product/4694)
- Button

## Build

- Modify your config in modules/duo-s/common.nix
- `nix build` will cross-compile a polyglot ARM and RISC-V image

## Running

- ARM is selected by default, set the physical `builtins.currentSystem` switch to aarch64-linux.
  Yes, really, this is not a joke.
- Connect over serial (115200/8n1)
- Run `nix-badge` to control the badge once it's booted
