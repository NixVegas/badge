# SG2000 unified fip.bin: verdict and boot-flow evidence

*Research memo, 2026-08-31. Question: can ONE fip.bin serve BOTH the ARM and
RISC-V core, selected by the strap — so the core swap wouldn't need to rewrite
`/boot/fip.bin`? We investigated this once before, split the fips, and forgot
the exact reason. This recovers it with citations so it stays recovered.*

## Verdict

**No clean unified fip is possible. The split is effectively mask-ROM-forced.**
Keep `fip-arm.bin` / `fip-riscv.bin` + the swap (pkgs/sdcard/swap-core.nix and
`nix-badge bootswap`'s native fip copy).

Two stacked structural facts force it:

1. The fip format has exactly **one BL2 slot**, and BL2 is **ISA-specific
   machine code** (`plat/cv181x/fiptool.py:144-172` in sophgo/fsbl @ 29edcfa:
   one `BL2_IMG_*` group; `param2` likewise one `MONITOR`, one `LOADER_2ND`).
2. The mask ROM runs that one BL2 **on the strapped core**, with **no
   per-core content selection** anywhere in the image. Core select is the
   GPIO_RTX hardware strap (TRM 3.1), not an image field. `conf_info.boot_sel`
   (TRM 7.3.2) reports the boot *device*, never the core.

The per-ISA `TOC_HEADER_NAME` magic (`0xC906B001` riscv / `0xAA640001` arm,
fsbl Makefile:184-187) is **written as zero** in our built fips (MAGIC2 is
declared in fiptool.py:147 but never emitted) — the ROM does not gate on it.

## Boot flow (what is per-ISA)

- **Stage 0, mask ROM (per-ISA, on-die):** each big core has its own ROM
  (aarch64 API table at 0x40000020.., riscv at 0x04418020..; see
  `plat/cv181x/include/{aarch64,riscv}/rom_api_refer.h`, and
  `pkgs/firmware/fsbl.nix` romBase). It parses `fip_param1` at a fixed
  layout, block-loads the single BL2 into TPU-SRAM, jumps — on the strapped
  core, whatever ISA the BL2 actually is.
- **Stage 1, BL2/FSBL (per-ISA):** built per core (`fsbl.nix`,
  BOOT_CPU=aarch64|riscv). Ours: arm BL2 = 0xde00 bytes, riscv = 0xaa00.
- **Stage 2, monitor (per-ISA):** arm = TF-A bl31.bin, riscv = OpenSBI
  fw_dynamic.bin (`pkgs/firmware/fip.nix`; fsbl `bl2_opt.c:258 load_monitor`).
- **Stage 3, LOADER_2ND (per-ISA):** the core's own U-Boot (LZMA), then
  `jump_to_monitor` (`bl2_opt.c:359-465`).

## The E:RESET:plat/mars/platform.c:114 signature

Observed on the bench when the strap said RISC-V but fip.bin was the ARM one:

```
C.SCS/0/0.WD.URPL.SDI/25000000/6000000.BS/SD.PS.SD/0x0/0x1000/0x1000/0.PE.BS.SD/0x1000/0xe000/0xe000/0.BE.J.
E:RESET:plat/mars/platform.c:114
```

Decode: `PS.SD/0x0/0x1000` = param1 load; `BS.SD/0x1000/0xe000` = BL2 body
load — and **0xe000 matches the ARM BL2 size** (riscv would be ~0xac00), so
the C906 ROM demonstrably loaded the ARM payload. `J.` = jump; the first ARM
word (`0x14000008`, an aarch64 `b`) is an illegal instruction stream on the
C906, the trap lands in the ROM's handler (BL2 never installed its own
vector), and the ROM's boot-failure funnel resets: `SYSTEM_RESET` →
`__system_reset()` prints `RESET:%s:%d` (`plat/cv181x/platform.c:35`,
`platform.h:26-31`). "mars" is Sophgo's internal platform name for the SG2000
ROM build. Same signature as milkv-duo/duo-buildroot-sdk issue #86.

So: wrong-ISA fip + strapped core = **reset loop until the fip is corrected**
— which is why `nix-badge bootswap` swaps the fip BEFORE latching, and reverts
it if the latch fails.

## If someone insists on one image (don't)

Technically constructible, no config flag exists:
1. Polyglot dual-ISA BL2 entry stub (both ISAs decode the first bytes as a
   branch into their own body; ~100K combined fits the 0x37000 BL2 budget).
2. Second core's monitor + U-Boot packed into the spare `LOADER_2ND_B` /
   `BLCP_2ND` slots (fiptool.py:192-210) + patched `bl2_opt.c` loaders.
3. fip.nix/fiptool rework to pack it all.
Days of fragile work; strictly worse than copying one file. Rejected.

## Prior art

Milk-V official, Armbian, and the community all ship **separate per-arch
images** and treat the switch as reflash. Our one-file swap-then-latch is
already ahead of the ecosystem.

Sources: sophgo/fsbl @ 29edcfa (pinned in pkgs/firmware/fsbl.nix); SG2000 TRM
V1.0-alpha ch.3.1/4/7.3.2; milkv-duo/duo-buildroot-sdk#86; Armbian "One
board, two architectures" blog; spotpear Duo S switching wiki.
