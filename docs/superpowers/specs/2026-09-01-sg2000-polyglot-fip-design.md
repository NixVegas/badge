# SG2000 unified polyglot fip — design spec

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:writing-plans to turn
> this into a task-by-task implementation plan.

**Goal:** Ship one static `fip.bin` that boots either the ARM A53 or the RISC-V C906
depending on the GPIO_RTX core-select strap, so switching cores becomes a live strap
flip (`nix-badge core <arch>` + reboot in AUTO) with **zero SD access** — decoupling the
boot-core switch from the SD card.

**Architecture:** A polyglot BL2 whose first 32-bit word is simultaneously a valid
aarch64 and RISC-V branch; each ISA lands on its own trampoline, relocates its FSBL body
to the BL2 run base, and boots. The two cores' monitors and u-boots ride separate fip
param2 slots. `fip.bin` never changes; the 74AUP1G175 latch is the sole core selector.

**Tech stack:** sophgo/fsbl @ `29edcfa` (pinned in `pkgs/firmware/fsbl.nix`);
`plat/cv181x/fiptool.py`; `gcc-arm-embedded` + `pkgsCross.riscv64-embedded`; Nix
(`pkgs/firmware/*.nix`, `pkgs/sdcard/*.nix`, `modules/duo-s/*.nix`); nix-badge (Zig).

## Global constraints

- **Non-secure boot only.** One `BL2_IMG_SIG` cannot sign two disjoint bodies; enabling
  secure boot later breaks the polyglot permanently. The badge is non-secure — fine.
  This is a hard, documented limitation, not a bug to fix.
- **Recovery is mandatory and cheap.** `fip-arm.bin` and `fip-riscv.bin` stay on the SD
  as known-good blobs. Rollback = `cp fip-arm.bin fip.bin` (from the still-booting core
  or an SD reader). Never remove them.
- **FSBL sources stay byte-identical to today's proven builds** except the one localized
  `bl2_opt.c` slot-redirect on the secondary (riscv) variant. All new risk lives in two
  small per-ISA asm stubs + the merge/pack tooling, which are independently testable.
- Build on citadel (`--max-jobs 0`), never `--builders ''` (see badge-deploy memory).
- Every commit ends with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Feasibility (already established)

`docs/sg2000-unified-fip-verdict.md`: the entry word `0x1400006F` (`6f 00 00 14` LE) is
BOTH a valid aarch64 `b #444` and a valid RISC-V `j 320` (JAL, rd=x0, `.option norvc`),
one of 2048 words in the B-imm26 × JAL intersection, verified with llvm-mc. The ROM gates
only on `MAGIC1=CVBL01\n`; `MAGIC2` is emitted as 0 (ungated); all PK/SIG fields are 0 so
the ROM does no crypto; `BL2_IMG_CKSUM` is a plain CRC16 fiptool recomputes. Only 4 param1
fields differ between the two shipped fips; `CHIP_CONF` is byte-identical.

**Unproven until bench:** the entry+trampoline+relocation+alternate-slot chain has never
executed on real silicon. The two bench tests (Section: Testing) bisect any failure.

## Boot flow and fip layout

The BootROM on the strapped core loads exactly one BL2 slot to `BL2_BASE` (= per-core
`TPU_SRAM_BASE`: arm mirror `0x40100000`, riscv `TPU_SRAM_ORIGIN_BASE` — same physical
TPU-SRAM, two address views), then jumps to word 0. `BL2_SIZE = 0x37000`; the merged
image (arm body ≈ `0xe000` + riscv body ≈ `0xac00` + stubs/header ≈ `0x1000`) ≈ `0x1b000`,
well within budget.

```
fip.bin (polyglot, static on the SD):
  param1 header   MAGIC1=CVBL01, MAGIC2=0, CRCs recomputed        (shared)
  CHIP_CONF       DDR/pinmux init — byte-identical for both cores (shared)
  BL2 slot        POLYGLOT BL2 (below)
  MONITOR         arm bl31.bin           — primary core
  LOADER_2ND      arm u-boot (LZMA)      — primary core
  BLCP_2ND        riscv OpenSBI fw_dynamic — secondary; RUNADDR 0x9FE00000 → 0x80000000
  LOADER_2ND_B    riscv u-boot (LZMA)    — secondary core
```

Per-core boot: ROM → BL2 word 0 → ISA branch → ISA trampoline → relocate FSBL body to
`BL2_BASE` → FSBL → monitor + u-boot from that core's slots → Linux. `arm` = primary
(FSBL reads MONITOR + LOADER_2ND, unpatched); `riscv` = secondary (FSBL `bl2_opt.c`
patched to read BLCP_2ND + LOADER_2ND_B).

## Component 1 — the polyglot BL2 (Approach A: relocating stubs)

Layout of the merged BL2 image (offsets from word 0, which the ROM places at `BL2_BASE`):

```
+0x000  word 0 = 0x1400006F           aarch64 `b #444` / riscv `j 320`
+0x004  7 words of zero               bl2_head padding (ROM does not read these)
+0x140  (320)  riscv trampoline+stub  reached by `j 320`
+0x1BC  (444)  arm trampoline+stub    reached by `b #444`
+0x1000 (page) arm FSBL body          bl2.bin from fsbl.nix core=arm  (linked at BL2_BASE)
+....   riscv FSBL body               bl2.bin from fsbl.nix core=riscv (linked at BL2_BASE)
```

Both FSBL bodies are built exactly as today (linked to run at `BL2_BASE`), so only one can
sit at `BL2_BASE`; each actually sits at an offset. Each **relocating stub** (per ISA):

1. Copies itself (the tiny copier, a few dozen bytes) into the LD's spare SRAM window
   `0x0C030000` (64 KB, unused by BL2) and branches there — so the copy that follows does
   not overwrite the running code.
2. From SRAM, copies its FSBL body from `BL2_BASE + body_offset` down to `BL2_BASE`
   (`body_size` bytes; each ISA uses ITS `BL2_BASE` view — arm `0x40100000`, riscv origin).
3. Jumps to `BL2_BASE` (the FSBL body's real entry, now in place).

The arm stub is assembled with the aarch64 cross toolchain, the riscv stub with the
riscv64 one. The riscv stub is `.option norvc` (4-byte insns) so C-extension packing can't
shift the entry offset. `body_offset`/`body_size` are known at merge time from the two
`bl2.bin` sizes; the merge tool (python) lays the pieces out, patches the stub constants,
prepends the entry word + zero head, appends the bodies, and pads to page alignment.

**Merge tool** (`pkgs/firmware/polyglot-bl2.nix` or a script in `fip-polyglot.nix`): inputs
= arm `bl2.bin`, riscv `bl2.bin`, assembled arm stub, assembled riscv stub, per-core
`BL2_BASE`. Output = the merged BL2 blob. Deterministic, no wall-clock.

## Component 2 — secondary FSBL variant (`bl2_opt.c` slot redirect)

`fsbl.nix` gains `slot ? "primary"` (default) `| "secondary"`. The secondary build (riscv)
gets a `postPatch` redirect so the FSBL reads its payloads from the spare slots:

- `load_monitor` reads `fip_param2.blcp_2nd_{loadaddr,size,runaddr,cksum}` instead of the
  `monitor_*` fields. `blcp_2nd_runaddr` is range-checked against DRAM in `bl2_opt.c` — we
  set it to `0x80000000` (in DRAM), so the check passes and the riscv monitor loads where a
  monitor runs. Bypass the normal blcp_2nd RTOS/C906L-handoff path (`AXI_SRAM_RTOS_BASE`
  write) for this variant.
- `load_loader_2nd` reads `LOADER_2ND_B_{loadaddr,size}` instead of `LOADER_2ND_*`.

Primary (arm) FSBL is unpatched. Exact call sites: `load_monitor` (`bl2_opt.c:~258`),
`load_loader_2nd` (`bl2_opt.c:~359-465`), param2 struct in the same file. The plan pins
the precise diff against `29edcfa`.

## Component 3 — fiptool packing

Extend the `genfip` invocation in the polyglot fip build to populate the spare slots:

- `--BL2=<merged polyglot bl2>` (Component 1 output).
- `--MONITOR=<arm bl31>`, `--LOADER_2ND=<arm u-boot raw>` (as today, primary).
- `--BLCP_2ND=<riscv OpenSBI fw_dynamic>` with `--BLCP_2ND_RUNADDR=0x80000000`
  (override the default `0x9FE00000`).
- `--LOADER_2ND_B=<riscv u-boot raw>`.
- `--CHIP_CONF=<shared chip_conf.bin>` (either core's — byte-identical).

**Plan must verify:** whether upstream `fiptool.py genfip` already accepts `--LOADER_2ND_B`
and `--BLCP_2ND` (with a real payload, not `test/empty.bin`) and wraps LOADER_2ND_B with
the same `ldr_2nd_hdr`/LZMA framing as LOADER_2ND; if not, add the CLI args + framing
(param2 already declares both slots, so this is arg-plumbing, not a format change). CRCs
(`PARAM_CKSUM`, `BL2_IMG_CKSUM`, `PARAM2_CKSUM`) are recomputed by fiptool.

## Component 4 — nix + system integration

- **`pkgs/firmware/fip-polyglot.nix`** (new): builds arm-FSBL(primary), riscv-FSBL(secondary),
  arm bl31, riscv OpenSBI, arm u-boot, riscv u-boot, the merged BL2 (Component 1), then runs
  `genfip` (Component 3). Output: `sg2000-fip-polyglot.bin`. Runs on `buildPackages`.
- **`pkgs/sdcard/make-boot-dir.nix`**: install `fip-polyglot.bin` **as** `fip.bin` (default);
  keep emitting `fip-arm.bin` + `fip-riscv.bin` as recovery blobs.
- **`modules/duo-s/deploy.nix`**: the existing fip-install path points `fip.bin` at the
  polyglot; still refresh the split recovery fips. Threading mirrors the current `fip` import.
- **`pkgs/sdcard/swap-core.nix`** + nix-badge `bootswap` (`modules/duo-s/bootswap.nix` +
  the Zig `core`/`bootswap` command): **drop the `cp fip-$core.bin fip.bin`**. `swap-core`
  becomes "set the latch + reboot" only; delete the wrong-fip/`E:RESET` guard rationale.
  nix-badge `bootswap` no longer touches the fip — it only latches. Update all messages.

## Testing + rollback

**Bench (bisecting):**
1. Build the polyglot; make it `fip.bin` (deploy or SD).
2. Latch ARM (`nix-badge core arm`), switch AUTO, reboot. Serial: arm FSBL banner
   (`FSBL ...`, TOC `0xAA640001`), boots to Linux. Validates entry word + arm trampoline +
   relocation + primary slots.
3. Latch RISC-V, reboot. Serial: riscv FSBL, boots to Linux. Validates riscv trampoline +
   the `bl2_opt.c` secondary-slot patch + BLCP_2ND/LOADER_2ND_B packing.
4. Confirm no `E:RESET:plat/mars/platform.c` on either strap.

**Rollback:** any failure → `cp fip-arm.bin fip.bin` (still-booting core or SD reader) →
known-good split boot. The split fips exist on the SD for exactly this.

**Unit-testable seams:** the merge tool (assert layout: entry word at 0, stubs at
320/444, bodies at expected offsets, total ≤ `0x37000`); the stub asm (offsets/sizes patch
correctly); fiptool output (slots populated, CRCs valid) — checkable off-hardware before any
board touch.

## Risks / non-goals

- **Brick risk:** a bad BL2 dead-ends the BootROM (`E:RESET` loop) → SD reflash. Mitigated
  by keeping the split recovery fips and bench-bisecting.
- **Secure boot:** permanently incompatible (non-goal; documented).
- **Not** removing the strap/latch mechanism — the 74AUP1G175 + AUTO switch stay; this only
  removes the fip-copy half of the switch.
- **Not** touching the per-core /`<core>`/extlinux trees — already per-core and correct.

## Open items for the plan to pin

1. Exact `TPU_SRAM_ORIGIN_BASE` value (riscv `BL2_BASE`); confirm arm `0x40100000`.
2. Whether `genfip` accepts `--LOADER_2ND_B` / real `--BLCP_2ND` + LZMA framing, or needs
   the CLI/framing added.
3. Precise `bl2_opt.c` diff for the secondary slot redirect against `29edcfa`.
4. The two stubs' asm (aarch64 + riscv `.option norvc`), including the SRAM self-relocate.

**Established, not open:** the ROM jumps to BL2 word 0 (the entry-word offsets 320/444 are
from byte 0). Evidence: the verdict's `E:RESET` decode shows the C906 trapped executing the
arm branch word `0x14000008` sitting at offset 0, and the normal BL2 entry is `b #32`
(`0x14000008` = branch past an 8-word head to the real entrypoint at offset 32). So word 0
is executed as an instruction and the polyglot branch targets are measured from it.
