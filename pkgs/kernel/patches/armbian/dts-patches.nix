# Armbian sophgo-sg200x-7.2 patches that touch arch/*/boot/dts (device-tree
# nodes), applied to kernel.src to build our board DTBs from a POST-PATCHED
# tree (see pkgs/firmware/duos-{arm,riscv}-dtb.nix). The mainline 7.2 sophgo
# dtsi our board DTS #includes lacks the SoC peripheral nodes (thermal, pwm,
# efuse, mailbox, i2s, timer, dma-mux); these add them with the correct
# per-arch interrupt specifiers (GIC on arm64, PLIC on riscv). Board-level
# hunks target the mainline milkv-duo-s board .dts, which we do NOT #include,
# so those are inert for our DTBs. Generated from the full series; keep in
# numeric (apply) order. The matching DRIVER patches live in soc-features.nix.
[
  ./0002-arm64-dts-sophgo-add-initial-Milk-V-Duo-S-board-supp.patch
  ./0004-riscv64-dts-sophgo-add-SG2000-dtsi.patch
  ./0005-riscv64-dts-sophgo-add-initial-Milk-V-Duo-S-board-su.patch
  ./0006-riscv64-dts-sophgo-enable-full-512MB-RAM-for-Milk-V-.patch
  ./0009-riscv-dts-sophgo-add-cv180x-thermal-sensor-dts-node.patch
  ./0011-riscv-dts-sophgo-add-thermal-zones-for-cv180x.patch
  ./0013-riscv-dts-sophgo-add-timer-dt-node-for-CV1800.patch
  ./0014-riscv64-dts-sophgo-use-mdio-mux-driver-for-Sophgo-CV.patch
  ./0015-riscv64-dts-sophgo-enable-USB-OTG-for-Milk-V-Duo-S-S.patch
  ./0016-riscv64-dts-sophgo-add-watchdog-timer-node-for-Sophg.patch
  ./0017-riscv64-dts-sophgo-enable-cv180x-watchdog-timer-for-.patch
  ./0018-riscv64-dts-sophgo-enable-uart4-for-sg2000-milkv-duo.patch
  ./0020-riscv-dts-sophgo-enable-all-peripherals-for-sg2000.patch
  ./0026-riscv-dts-sophgo-cv180x-Allow-the-DMA-multiplexer-to.patch
  ./0028-nvmem-Add-Sophgo-eFuse-driver.patch
  ./0029-riscv-dts-sophgo-enable-efuse-for-sg2000-milkv-duo-s.patch
  ./0030-riscv-dts-sophgo-dts-nodes-for-i2s-tdm-modules.patch
  ./0031-riscv-dts-sophgo-add-cv1800-PWM-device-nodes.patch
  ./0032-riscv-dts-sophgo-enable-PWM-chips-for-sg2000-milkv-d.patch
  ./0033-riscv-dts-sophgo-enable-I2S-devices-for-sg2000-milkv.patch
  ./0034-riscv-dts-sophgo-add-mailbox-node-for-cv180x.patch
  ./0035-riscv-dts-sophgo-add-remoteproc-nodes-for-sg2000.patch
  ./0036-riscv-dts-sophgo-add-board-support-for-Milk-V-Duo-25.patch
  ./0038-riscv-dts-sophgo-cv180x-use-SOC_PERIPHERAL_IRQ-for-d.patch
  ./0039-arm64-dts-sophgo-enable-Milk-V-Duo-S-peripherals-in-.patch
  ./0040-riscv-dts-sophgo-put-the-Milk-V-Duo-S-USB-port-in-ho.patch
  ./0041-arm64-dts-sophgo-put-the-Milk-V-Duo-S-USB-port-in-ho.patch
  ./0042-riscv-dts-sophgo-mux-the-Milk-V-Duo-S-eMMC-pads-from.patch
  ./0043-arm64-dts-sophgo-mux-the-Milk-V-Duo-S-eMMC-pads-from.patch
  ./0044-riscv-dts-sophgo-disable-the-unused-Milk-V-Duo-S-cop.patch
  ./0045-arm64-dts-sophgo-disable-the-unused-Milk-V-Duo-S-cop.patch
  ./0046-riscv-dts-sophgo-note-that-Milk-V-Duo-S-uart2-pads-a.patch
  ./0047-arm64-dts-sophgo-note-that-Milk-V-Duo-S-uart2-pads-a.patch
  ./0048-riscv-dts-sophgo-add-a-Milk-V-Duo-S-C906L-overlay.patch
  ./0049-arm64-dts-sophgo-add-a-Milk-V-Duo-S-C906L-overlay.patch
  ./0050-riscv-dts-sophgo-add-a-Milk-V-Duo-S-USB-device-mode-.patch
  ./0051-arm64-dts-sophgo-add-a-Milk-V-Duo-S-USB-device-mode-.patch
  ./0052-riscv-dts-sophgo-add-Milk-V-Duo-S-pin-header-overlay.patch
  ./0053-arm64-dts-sophgo-add-Milk-V-Duo-S-pin-header-overlay.patch
  ./0054-riscv-dts-sophgo-mux-the-Milk-V-Duo-S-microSD-pads-f.patch
  ./0055-arm64-dts-sophgo-mux-the-Milk-V-Duo-S-microSD-pads-f.patch
  ./0056-riscv-dts-sophgo-reserve-a-ramoops-region-on-the-Mil.patch
  ./0057-arm64-dts-sophgo-reserve-a-ramoops-region-on-the-Mil.patch
]
