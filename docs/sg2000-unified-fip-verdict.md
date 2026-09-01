# SG2000 unified fip.bin: verdict and boot-flow evidence

*Research memo, 2026-08-31. Question: can ONE fip.bin serve BOTH the ARM and
RISC-V core, selected by the strap — so the core swap wouldn't need to rewrite
`/boot/fip.bin`? We investigated this once before, split the fips, and forgot
the exact reason. This recovers it with citations so it stays recovered.*

> **CORRECTION (2026-09-01, superseded by #48).** Two claims below are overturned:
> (1) The "keep the split" verdict was re-decided — the polyglot's real win is decoupling
> the core-switch from the SD (a live latch flip, no fip copy, no reflash), a rationale this
> memo did not weigh. See `docs/superpowers/specs/2026-09-01-sg2000-polyglot-fip-design.md`.
> (2) "Secure-boot-fragile / one BL2_IMG_SIG cannot sign two disjoint bodies" is WRONG: the
> two FSBL bodies are contiguous in one BL2 slot, so one signature over the merged blob
> (`BL2_IMG_SIZE` = full merged size, which the build already sets) covers both — the
> polyglot IS secure-boot-compatible. The boot-flow evidence and construction recipe below
> remain correct and are the basis of the #48 design.

## Verdict

**Keep the split** (`fip-arm.bin` / `fip-riscv.bin` + the swap in
pkgs/sdcard/swap-core.nix and `nix-badge bootswap`'s native fip copy). A
polyglot single image IS constructible for non-secure boot (verified below —
the entry-word coexistence genuinely holds), but it is strictly less robust
than the file-swap and secure-boot-fragile, so it is rejected on merit, not
impossibility. The *clean* answer — one image the ROM selects per-core via an
image field — does not exist: the ROM is content-blind, selection is a
hardware strap.

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

## If someone insists on one image (don't) — polyglot IS constructible

A follow-up did the binary analysis the first pass hand-waved. A polyglot
entry genuinely works, and the whole image is constructible **for non-secure
boot**. It is still rejected — it doesn't remove the swap, it hides it inside
a bespoke binary, and it's secure-boot-fragile.

**The fip diff.** Only 4 param1 header fields differ between our built
fip-arm.bin and fip-riscv.bin: `PARAM_CKSUM` (0x0C), `BL2_IMG_CKSUM` (0xD4),
`BL2_IMG_SIZE` (0xD8: arm 0xE000 vs riscv 0xAA00), `PARAM2_LOADADDR` (0xE0).
Everything else in the 4KB header — including `CHIP_CONF` (DDR/pinmux init,
760B) — is byte-identical. The three payloads (BL2, MONITOR = TF-A bl31 vs
OpenSBI, LOADER_2ND = per-core u-boot) are wholly per-ISA. A unified image
shares ~1KB and duplicates all the code.

**The entry word exists.** The mask ROM jumps to BL2's first 4-byte
little-endian word. The word `6f 00 00 14` (`0x1400006F`) decodes as BOTH a
valid aarch64 `b #444` AND a valid riscv `j 320` (JAL, rd=x0 — no clobber),
confirmed with llvm-mc. It is one of **2048** words in the intersection of the
aarch64 `B imm26` space and the riscv `JAL` opcode; the two landing offsets
are independently tunable, so each core trampolines to its own FSBL body. The
riscv entry is `.option norvc` (a full 4-byte JAL), so the C-extension is
irrelevant. (The two SHIPPED entries are NOT mutually valid — arm's
`08 00 00 14` is a riscv `addi`, riscv's `6f 00 00 02` is an illegal aarch64
word — which is why naive concatenation fails and a purpose-built word is
required.)

**All non-instruction gates are clear** (non-secure boot): MAGIC2 (0x08) is 0
in both, ROM checks only MAGIC1=`CVBL01\n`; BL2_IMG_CKSUM is a plain CRC16
fiptool recomputes over the one merged body; all PK/SIG fields are zero so the
ROM does no crypto verification.

**Construction** (if you must): one BL2 slot = [polyglot word][7 zero words of
bl2_head][riscv trampoline @ its offset][arm trampoline @ its offset][both
full FSBL bodies]; the second core's monitor + u-boot ride the spare
`BLCP_2ND` / `LOADER_2ND_B` param2 slots. The real cost is patching the riscv
FSBL's `bl2_opt.c` load_monitor/load_loader_2nd to read those alternate slots,
NOT the entry word.

**Why still rejected:** (1) it does not eliminate the swap, only relocates it
into a hand-built ~690KB dual-toolchain binary; (2) it works ONLY while
non-secure — one BL2_IMG_SIG cannot sign two disjoint bodies, so enabling
secure boot later breaks it permanently. The file-swap is one atomic `cp` with
zero shared-format risk. Clever, but strictly less robust — fails the "more
robust, not just clever" bar.

## Prior art

Milk-V official, Armbian, and the community all ship **separate per-arch
images** and treat the switch as reflash. Our one-file swap-then-latch is
already ahead of the ecosystem.

Sources: sophgo/fsbl @ 29edcfa (pinned in pkgs/firmware/fsbl.nix); SG2000 TRM
V1.0-alpha ch.3.1/4/7.3.2; milkv-duo/duo-buildroot-sdk#86; Armbian "One
board, two architectures" blog; spotpear Duo S switching wiki.
