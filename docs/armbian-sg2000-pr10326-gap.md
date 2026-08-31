# Armbian PR #10326 (Milk-V Duo S / SG2000) — gap analysis vs badgeos

*Research memo, 2026-08-31. armbian/build#10326 "Add Milk-V DuoS", merged
2026-08-09 — a mainline-7.x board port. Question: what does it enable that we
lack, esp. TPU + graphics? Summary: the PR brings no TPU and no video
(`HAS_VIDEO_OUTPUT=no`, TPU explicitly excluded); its value is a curated,
mainline-portable peripheral enablement set + confirmation of our fip split.*

## What the PR is

Mainline kernel (7.0 edge / 7.2 bleedingedge), the SAME version + 57-patch
series for BOTH arches (out-of-tree cherry-picks of pending LKML work + the
maintainer's board DTS/eMMC pinmux). Vendor u-boot-2021.10 + sophgo/fsbl +
opensbi built from source → fip.bin, no blobs. Two separate boards
(`milkv-duos-arm.csc` / `milkv-duos-riscv.csc`), each a full image — they do
NOT switch cores at runtime; the slide switch + ROM picks the matching fip
(same conclusion as docs/sg2000-unified-fip-verdict.md). Userspace BSP:
CDC-NCM USB gadget, efuse-derived MACs, AIC8800 wifi+BT (BT via hciattach on
uart4), zram 100%.

## Portability key

The PR runs on mainline 7.2 — so every peripheral item below is **portable to
our kernel** (not vendor-5.10-locked). The only vendor-5.10-only subsystems
(TPU, VO/DSI, VENC/VDEC, ISP) are exactly the ones the PR also omits.

## Gap table (what we lack)

| Subsystem | PR has | We have | Port | Worth it |
|---|---|---|---|---|
| C906L remoteproc | `sophgo_cv1800b_c906l` + mailbox + rproc DTS + cvirtos.elf | MBOX=m, REMOTEPROC=y, no rproc driver/node | Easy | **High** — programs the idle little core |
| eFuse/NVMEM | `NVMEM_SOPHGO_EFUSE` + DTS, MAC from FTSN | NVMEM=y, no driver | Easy | Medium |
| Thermal | `CV1800_THERMAL=y` + zones | unset | Easy | Medium |
| PWM | `PWM_CV1800=y` + DTS | framework only | Easy | Med-High — HW PWM for LED/buzzer/servo |
| Audio | TDM/ADC/DAC =y + sound-card DTS | same syms =m, no card node | Easy | Medium |
| USB gadget | CONFIGFS=y + CDC-NCM service + device dr_mode | =m, host-only DTS | Easy | **High** — USB-net to a host |
| pstore/ramoops | PSTORE_RAM=y + ramoops node | =m, no node | Trivial | Medium — crash logs across reboot |
| eth mdio-mux | `MDIO_BUS_MUX_SOPHGO_CV1800B=y` | DWMAC=m, no mux | Easy | hardens our working eth |
| CPU 1050MHz | FSBL `OD_CLK_SEL=y` | default 850MHz | Trivial | **High** — ~24% free clock, 1 line |
| fence.tso emu (riscv) | OpenSBI patch | unpatched | Easy | Medium — prevents riscv SIGILL |
| TPU | nothing | nothing | vendor-only | see below |
| Video/display | nothing | I2C OLED + Sharp SPI | vendor-only (SoC VO) | see below |

## TPU (greenfield; zero mainline effort)

0.5-TOPS INT8 TPU, entirely vendor-stack. To run a model:
1. GPL `cvi-tpu` driver (`duo-buildroot-sdk-v2` osdrv/interdrv/tpu) → `/dev/cvi-tpu0`, MMIO+DMA, no firmware blob.
2. DTS `cvitek,tpu` node — already in our vendor tree (`pkgs/kernel/duos-vendor/dts/cv181x_base.dtsi:44`).
3. **ION carveout** (~170MB of 512MB) — vendor defconfig has it; `/dev/ion`.
4. `cviruntime` userspace (C API CVI_NN_*) — source-available, **NO LICENSE file** (Nix-closure redistribution risk).
5. Off-device: `tpu-mlir` (BSD-2) compiles ONNX → `.cvimodel`; prebuilt models in milkv-duo/tdl-models.

Mainline blocker: legacy **ION was removed in 5.11**; needs ION back-port or
runtime repatched to dma-buf heaps (nobody's done it). **Fast demo:** boot our
already-packaged vendor 5.10 kernel (has TPU node + ION + memmap), build
cvi-tpu + ION as modules, drop a prebuilt mobilenet.cvimodel, run one
classification.

## Graphics

SoC VO (MIPI-DSI/RGB-LCD/VPSS/VENC/VDEC/JPEG) is **vendor-5.10-only**, zero
mainline. H.26x encoder is a firmware-dependent Chips&Media VPU drop. Camera→
encode→RTSP only plausible on vendor 5.10 + cvi_mpi (also unlicensed).

**The useful inversion:** driving external panels needs none of that, and our
built 7.2 config ALREADY has the mainline DRM drivers:
- `TINYDRM_SHARP_MEMORY=m` — the Sharp Memory LCD (#42); bind via
  `sharp,ls027b7dh01` (our DTS stubs it at sg2000-milkv-duo-s.dts) instead of
  hand-rolled SPI framing.
- `DRM_SSD130X_{I2C,SPI}=m` — proper DRM/KMS for the SSD1306 OLED (#43), vs
  our bit-banged path.
So the display takeaway is a `/dev/fb0`+DRM standards path we could point
renderers at; the SoC's HW VO/encoder stays out of scope unless a DSI panel
forces it.

## Top 5 adoptable (value/effort)

1. **CPU 1050MHz** — `OD_CLK_SEL=y` in pkgs/firmware/fsbl.nix, ~24% clock, 1 line, no kernel rebuild.
2. **C906L remoteproc** — cherry-pick driver + mailbox/rproc DTS (7.2 patches 0021/0023/0034/0035/0037), ship cvirtos.elf. Programs the idle core.
3. **USB CDC-NCM gadget** — CONFIGFS/F_NCM =y + device dr_mode overlay + configfs script. Plug into a laptop → network iface.
4. **Sharp LCD via TinyDRM** — bind existing `TINYDRM_SHARP_MEMORY` through the sharp node; real DRM target (feeds #42).
5. **eFuse MAC + pstore/ramoops** — NVMEM_SOPHGO_EFUSE (patch 0028) for deterministic MAC + PSTORE_RAM=y + ramoops node (patch 0056) for crash logs.

Already covered by us (PR confirms, adds nothing): watchdog-reboot, AIC8800
wifi+BT, reset-simple, SDIO voltage-switch, the fip split.

Source: armbian/build#10326; milkv-duo/duo-buildroot-sdk-v2 (TPU osdrv);
sophgo/{cviruntime,tpu-mlir}.
