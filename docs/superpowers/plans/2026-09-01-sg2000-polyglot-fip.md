# SG2000 unified polyglot fip — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one static `fip.bin` that boots either the ARM A53 or the RISC-V C906 by the
GPIO_RTX strap, so core-switch becomes a live latch flip (`nix-badge core <arch>` + reboot in
AUTO) with zero SD access.

**Architecture:** A polyglot BL2 whose first word (`0x1400006F`) is a valid aarch64 `b #444`
AND riscv `j 320`; each ISA lands on a per-ISA relocating stub that copies its FSBL body from
its offset in the loaded image down to `BL2_BASE` and jumps. The two cores' monitors and
u-boots ride separate fip param2 slots (arm in MONITOR/LOADER_2ND, riscv in
BLCP_2ND/LOADER_2ND_B). `fip.bin` never changes; the 74AUP1G175 latch is the sole selector.

**Tech Stack:** sophgo/fsbl @ `29edcfa` (pinned in `pkgs/firmware/fsbl.nix`);
`plat/cv181x/fiptool.py`; `pkgsCross.aarch64-embedded` + `pkgsCross.riscv64-embedded` gcc;
Nix; python3 (merge tool); nix-badge (Zig).

**Spec:** `docs/superpowers/specs/2026-09-01-sg2000-polyglot-fip-design.md` (read it —
boot-flow evidence, secure-boot analysis, recovery model). Prior art:
`docs/sg2000-unified-fip-verdict.md`.

## Global Constraints

- **Non-secure boot only this round** (secure-boot-*ready*, not enabled — no eFuse burn).
- **Recovery is mandatory:** keep `fip-arm.bin` + `fip-riscv.bin` on the SD as known-good
  blobs. Never remove them. Rollback = `cp fip-arm.bin fip.bin`.
- **FSBL sources stay byte-identical** to today's proven builds except the localized
  `bl2_opt.c` slot-redirect on the secondary (riscv) variant.
- Build on citadel (`nix build ... --max-jobs 0`), never `--builders ''`.
- Deterministic builds: no `Date.now()`/wall-clock; `SOURCE_DATE_EPOCH=1` as fsbl.nix does.
- Every commit `--no-gpg-sign`, ending with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Resolved facts (baked in — do not re-derive)

- `BL2_BASE` (= per-core `TPU_SRAM_BASE`): **arm `0x40100000`** (mirror), **riscv `0x0C000000`**
  (`TPU_SRAM_ORIGIN_BASE`). Same physical 256 KB TPU-SRAM (`TPU_SRAM_SIZE 0x40000`).
- **Scratch SRAM** (free, past the image): arm `0x40130000`, riscv `0x0C030000` (the LD's
  `SRAM` region, 64 KB — `bl2.ld.S:21`). The merged image is ≈ `0x1b000` < `0x30000`.
- `BL2_SIZE` budget = `0x37000`. Entry word `0x1400006F` → aarch64 `b #444` / riscv `j 320`
  (verified by manual decode: aarch64 imm26=0x6F→444; riscv JAL rd=x0 imm=320).
- **fiptool `genfip` already accepts** `--BLCP_2ND`, `--BLCP_2ND_RUNADDR`, `--LOADER_2ND_B`.
  `MONITOR` and `BLCP_2ND` payloads are stored **raw**; `LOADER_2ND` is LZMA+`ldr_2nd_hdr`;
  **`LOADER_2ND_B` is stored raw** (`fiptool.py add_loader_2nd_b`), read by the FSBL's
  `load_uboot()` (`bl2_opt.c:342`) which reads `loader_2nd_b_*` raw (no decompress).
- `load_monitor` (`bl2_opt.c`) reads `fip_param2.monitor_{loadaddr,runaddr,size,cksum}`;
  `blcp_2nd_runaddr` is DRAM-range-checked, so `0x80000000` is valid.
- ROM jumps to BL2 word 0 (verdict `E:RESET` evidence; normal entry is `b #32` past an
  8-word head).

## File structure

```
pkgs/firmware/
  polyglot/
    stub-arm.S            NEW  aarch64 relocating stub (self-relocate + body copy + jump)
    stub-riscv.S          NEW  riscv .option norvc relocating stub
    merge-bl2.py          NEW  lay out [entry][head][stubs][arm body][riscv body], patch consts
    merge-bl2.nix         NEW  build both stubs + run merge-bl2.py -> polyglot bl2.bin
  fsbl.nix                MOD  add `slot ? "primary" | "secondary"` (secondary = bl2_opt.c patch)
  fsbl-secondary-slots.patch NEW  bl2_opt.c: load_monitor->blcp_2nd, uboot->loader_2nd_b raw
  fip-polyglot.nix        NEW  build all inputs + genfip with the extra slots -> polyglot fip
  fip.nix                 (unchanged; still builds split recovery fips)
pkgs/sdcard/
  make-boot-dir.nix       MOD  install polyglot as fip.bin; keep fip-{arm,riscv}.bin recovery
  swap-core.nix           MOD  latch-only (drop the fip.bin copy)
modules/duo-s/
  deploy.nix              MOD  point the installed fip.bin at the polyglot
  bootswap.nix            MOD  latch-only messaging
pkgs/badge/nix-badge/     MOD  `core`/`bootswap` command: latch only, no fip copy
```

---

## Task 1: aarch64 relocating stub (`stub-arm.S`)

**Files:**
- Create: `pkgs/firmware/polyglot/stub-arm.S`
- Test: assemble + `objdump` disassembly assertions (shell, in the task's nix build check)

**Interfaces:**
- Produces: an assembled `.bin` exporting a self-contained relocating routine that starts at
  its first byte. Merge tool places its first byte at offset **444** of the polyglot image and
  patches four 32-bit immediates the stub loads from a trailing constant pool:
  `SCRATCH=0x40130000`, `BODY_DST=0x40100000`, `BODY_SRC` (= `0x40100000 + arm_body_off`),
  `BODY_LEN` (= arm body byte length). The constant pool is at a fixed offset from the stub
  start (documented in the `.S`) so `merge-bl2.py` can patch it.

- [ ] **Step 1: Write the stub.** The stub must not execute from within `[BODY_DST,
  BODY_DST+BODY_LEN)` while copying (it sits at `BODY_DST+444`, inside that range), so it
  first copies ITSELF to `SCRATCH`, jumps there, then copies the body and jumps to `BODY_DST`.

```asm
/* pkgs/firmware/polyglot/stub-arm.S — aarch64 relocating stub.
 * Reached by the polyglot entry `b #444`. Position-independent. Loads its
 * parameters from a constant pool at the end (patched by merge-bl2.py).
 */
    .arch armv8-a
    .section .text
    .globl _start
_start:
    /* x9 = &_start (PC of this instr - 0). adr is PC-relative, PIC. */
    adr     x9, _start
    /* Load params from the pool (PC-relative). */
    ldr     w10, pool_scratch      // SCRATCH
    ldr     w11, pool_body_dst     // BODY_DST
    ldr     w12, pool_body_src     // BODY_SRC
    ldr     w13, pool_body_len     // BODY_LEN
    adr     x14, _end              // stub length = _end - _start
    sub     x14, x14, x9
    /* 1. copy the stub [_start.._end) to SCRATCH */
    mov     x15, x9                // src
    mov     x16, x10               // dst = SCRATCH
    mov     x17, x14               // len
1:  ldr     w0, [x15], #4
    str     w0, [x16], #4
    subs    x17, x17, #4
    b.gt    1b
    /* 2. compute the address of stage2 inside the SCRATCH copy and jump there.
       stage2 offset from _start is (_stage2 - _start). */
    adr     x0, _stage2
    sub     x0, x0, x9             // stage2 offset
    add     x0, x0, x10            // SCRATCH + offset
    br      x0
_stage2:
    /* now executing from SCRATCH; safe to overwrite BODY_DST. */
    mov     x15, x12               // src = BODY_SRC
    mov     x16, x11               // dst = BODY_DST
    mov     x17, x13               // len = BODY_LEN
2:  ldr     w0, [x15], #4
    str     w0, [x16], #4
    subs    x17, x17, #4
    b.gt    2b
    /* 3. barrier + jump to the relocated FSBL body at BODY_DST */
    dsb     sy
    isb
    br      x11
    .align  4
pool_scratch:   .word 0x40130000
pool_body_dst:  .word 0x40100000
pool_body_src:  .word 0x00000000   /* patched: BODY_DST + arm_body_off */
pool_body_len:  .word 0x00000000   /* patched: arm body length */
_end:
```

- [ ] **Step 2: Assemble + disassemble; assert.** In a scratch nix build or shell:

```bash
CC=$(nix build --no-link --print-out-paths 'nixpkgs#pkgsCross.aarch64-embedded.stdenv.cc')/bin/aarch64-none-elf-
"${CC}gcc" -c -o /tmp/stub-arm.o pkgs/firmware/polyglot/stub-arm.S
"${CC}objcopy" -O binary /tmp/stub-arm.o /tmp/stub-arm.bin
"${CC}objdump" -d /tmp/stub-arm.o | tee /tmp/stub-arm.dis
```
Expected: disassembly shows the two copy loops + `br x11`; the four `.word` pool entries are
at the tail. Assert `_stage2` lands after the first loop and the pool offsets are 16 bytes
before `_end`. Record `pool_body_src`/`pool_body_len` offsets from `_start` (merge tool needs
them).

- [ ] **Step 3: Commit.**

```bash
git add pkgs/firmware/polyglot/stub-arm.S
git commit --no-gpg-sign -m "polyglot: aarch64 relocating stub (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: riscv relocating stub (`stub-riscv.S`)

**Files:**
- Create: `pkgs/firmware/polyglot/stub-riscv.S`
- Test: assemble + `objdump` disassembly assertions.

**Interfaces:**
- Produces: an assembled `.bin`; merge tool places its first byte at offset **320** of the
  polyglot image and patches the pool: `SCRATCH=0x0C030000`, `BODY_DST=0x0C000000`,
  `BODY_SRC = 0x0C000000 + riscv_body_off`, `BODY_LEN = riscv body length`. Must be
  `.option norvc` (4-byte insns) so the C-extension can't shift the entry offset. Must fit in
  the 124 bytes between offset 320 and the arm stub at 444 — if it doesn't, offset 320 holds
  only `j _riscv_reloc` and the body of the routine is placed after offset 444 (before the
  body page at 0x1000); document which layout the merge tool uses.

- [ ] **Step 1: Write the stub.**

```asm
/* pkgs/firmware/polyglot/stub-riscv.S — riscv64 relocating stub (T-Head C906).
 * Reached by the polyglot entry `j 320`. .option norvc. PIC.
 */
    .option norvc
    .section .text
    .globl _start
_start:
    auipc   t0, 0                  // t0 = &_start
    /* load params from pool via PC-relative loads */
    lw      t1, pool_scratch - _start (t0)  // SCRATCH
    lw      t2, pool_body_dst - _start (t0) // BODY_DST
    lw      t3, pool_body_src - _start (t0) // BODY_SRC
    lw      t4, pool_body_len - _start (t0) // BODY_LEN
    la      t5, _end
    la      t6, _start
    sub     t5, t5, t6             // stub length
    /* 1. copy stub [_start.._end) to SCRATCH */
    mv      a0, t0                 // src
    mv      a1, t1                 // dst = SCRATCH
    mv      a2, t5                 // len
1:  lw      a3, 0(a0)
    sw      a3, 0(a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    addi    a2, a2, -4
    bgtz    a2, 1b
    /* 2. jump to _stage2 inside the SCRATCH copy */
    la      a4, _stage2
    la      a5, _start
    sub     a4, a4, a5             // stage2 offset
    add     a4, a4, t1             // SCRATCH + offset
    jr      a4
_stage2:
    /* executing from SCRATCH; safe to overwrite BODY_DST */
    mv      a0, t3                 // src = BODY_SRC
    mv      a1, t2                 // dst = BODY_DST
    mv      a2, t4                 // len = BODY_LEN
2:  lw      a3, 0(a0)
    sw      a3, 0(a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    addi    a2, a2, -4
    bgtz    a2, 2b
    fence
    fence.i
    jr      t2                     // jump to relocated FSBL body at BODY_DST
    .align  2
pool_scratch:   .word 0x0C030000
pool_body_dst:  .word 0x0C000000
pool_body_src:  .word 0x00000000   /* patched */
pool_body_len:  .word 0x00000000   /* patched */
_end:
```

- [ ] **Step 2: Assemble + disassemble; assert.**

```bash
CC=$(nix build --no-link --print-out-paths 'nixpkgs#pkgsCross.riscv64-embedded.stdenv.cc')/bin/riscv64-none-elf-
"${CC}gcc" -c -march=rv64imac -o /tmp/stub-riscv.o pkgs/firmware/polyglot/stub-riscv.S
"${CC}objdump" -d /tmp/stub-riscv.o | tee /tmp/stub-riscv.dis
"${CC}objcopy" -O binary /tmp/stub-riscv.o /tmp/stub-riscv.bin
wc -c /tmp/stub-riscv.bin
```
Expected: all 4-byte insns (no compressed), `jr t2` at the end, pool at tail. Record the
byte length: **if ≤ 124, layout = stub-at-320; if > 124, the merge tool puts `j _riscv_reloc`
at 320 and the routine after 444** (Task 3 handles both).

- [ ] **Step 3: Commit.**

```bash
git add pkgs/firmware/polyglot/stub-riscv.S
git commit --no-gpg-sign -m "polyglot: riscv relocating stub (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: merge tool (`merge-bl2.py`) + unit tests

**Files:**
- Create: `pkgs/firmware/polyglot/merge-bl2.py`
- Test: `pkgs/firmware/polyglot/test_merge_bl2.py` (python `unittest`, runs off-hardware)

**Interfaces:**
- Consumes: `stub-arm.bin`, `stub-riscv.bin` (Tasks 1-2, with the pool at a known tail
  offset), `bl2-arm.bin`, `bl2-riscv.bin` (from `fsbl.nix`).
- Produces: `merge_bl2(arm_bl2, riscv_bl2, arm_stub, riscv_stub) -> bytes` (the polyglot BL2)
  with layout:
  ```
  0x000  entry word 0x1400006F (LE: 6f 00 00 14)
  0x004  7 words 0x00000000 (head)
  0x140  (320) riscv stub, pool patched: SRC=0x0C000000+riscv_off, LEN=len(riscv_bl2)
  0x1BC  (444) arm stub,   pool patched: SRC=0x40100000+arm_off,   LEN=len(arm_bl2)
  0x1000 arm  body (arm_off = 0x1000)
  <pad>  riscv body (riscv_off = 0x1000 + round_up(len(arm_bl2), 0x1000))
  ```
  Asserts: entry word at 0; stubs at 320/444 and non-overlapping; total ≤ `0x37000`.

- [ ] **Step 1: Write the failing test.**

```python
# pkgs/firmware/polyglot/test_merge_bl2.py
import struct, unittest
from merge_bl2 import merge_bl2, ARM_BASE, RISCV_BASE, ARM_OFF, entry_word

class TestMerge(unittest.TestCase):
    def test_layout(self):
        arm = b"\xAA" * 0x1234          # stand-in bodies
        rv  = b"\xBB" * 0x2000
        # stubs: 8-word placeholders whose last 2 words are SRC,LEN to patch
        arm_stub = b"\x11" * 24 + struct.pack("<II", 0, 0)
        rv_stub  = b"\x22" * 24 + struct.pack("<II", 0, 0)
        out = merge_bl2(arm, rv, arm_stub, rv_stub)
        # entry word at 0
        self.assertEqual(struct.unpack("<I", out[0:4])[0], 0x1400006F)
        # arm body at 0x1000, matches input
        self.assertEqual(out[0x1000:0x1000+len(arm)], arm)
        # riscv body right after arm body, page-aligned
        rv_off = 0x1000 + ((len(arm) + 0xFFF) & ~0xFFF)
        self.assertEqual(out[rv_off:rv_off+len(rv)], rv)
        # arm stub SRC/LEN patched (last 8 bytes of the 32-byte stub at 444)
        src, ln = struct.unpack("<II", out[444+24:444+32])
        self.assertEqual(src, ARM_BASE + ARM_OFF)
        self.assertEqual(ln, len(arm))
        # riscv stub SRC/LEN patched at 320
        src, ln = struct.unpack("<II", out[320+24:320+32])
        self.assertEqual(src, RISCV_BASE + rv_off)
        self.assertEqual(ln, len(rv))
        self.assertLessEqual(len(out), 0x37000)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it, verify it fails.** `Run: cd pkgs/firmware/polyglot && python3 -m pytest
  test_merge_bl2.py -v` → FAIL (`No module named 'merge_bl2'`).

- [ ] **Step 3: Implement `merge-bl2.py`.** (Adjust the pool offset `24` to the real value
  recorded in Tasks 1-2; the test uses 24 for 6-word stubs — keep test and impl consistent.)

```python
# pkgs/firmware/polyglot/merge_bl2.py
import struct
ENTRY_WORD = 0x1400006F
ARM_BASE   = 0x40100000
RISCV_BASE = 0x0C000000
ARM_OFF    = 0x1000
RISCV_STUB_OFF = 320
ARM_STUB_OFF   = 444
POOL_TAIL = 8   # bytes of (SRC, LEN) at the end of each stub (set from Tasks 1-2)

def entry_word():
    return ENTRY_WORD

def _patch_stub(stub, base, body_off, body_len):
    # replace the trailing (SRC, LEN) words
    return stub[:-8] + struct.pack("<II", base + body_off, body_len)

def merge_bl2(arm_bl2, riscv_bl2, arm_stub, riscv_stub):
    rv_off = 0x1000 + ((len(arm_bl2) + 0xFFF) & ~0xFFF)
    total  = rv_off + len(riscv_bl2)
    assert total <= 0x37000, f"polyglot BL2 {total:#x} exceeds BL2_SIZE 0x37000"
    buf = bytearray(total)
    struct.pack_into("<I", buf, 0, ENTRY_WORD)          # entry
    # words 1..7 stay zero (head)
    rv_s  = _patch_stub(riscv_stub, RISCV_BASE, rv_off, len(riscv_bl2))
    arm_s = _patch_stub(arm_stub,   ARM_BASE,   ARM_OFF, len(arm_bl2))
    assert RISCV_STUB_OFF + len(rv_s) <= ARM_STUB_OFF, "riscv stub overruns arm stub slot"
    assert ARM_STUB_OFF + len(arm_s) <= ARM_OFF, "arm stub overruns body page"
    buf[RISCV_STUB_OFF:RISCV_STUB_OFF+len(rv_s)] = rv_s
    buf[ARM_STUB_OFF:ARM_STUB_OFF+len(arm_s)]    = arm_s
    buf[ARM_OFF:ARM_OFF+len(arm_bl2)]            = arm_bl2
    buf[rv_off:rv_off+len(riscv_bl2)]            = riscv_bl2
    return bytes(buf)

if __name__ == "__main__":
    import sys
    arm, rv, arm_stub, rv_stub, out = sys.argv[1:6]
    data = merge_bl2(open(arm,"rb").read(), open(rv,"rb").read(),
                     open(arm_stub,"rb").read(), open(rv_stub,"rb").read())
    open(out,"wb").write(data)
```

- [ ] **Step 4: Run tests, verify pass.** `Run: python3 -m pytest test_merge_bl2.py -v` → PASS.
  Fix `POOL_TAIL`/pool offset to match the real stubs if Tasks 1-2 recorded a different tail.

- [ ] **Step 5: Commit.**

```bash
git add pkgs/firmware/polyglot/merge_bl2.py pkgs/firmware/polyglot/test_merge_bl2.py
git commit --no-gpg-sign -m "polyglot: BL2 merge tool + layout tests (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: merge-bl2.nix (assemble stubs + run merge)

**Files:**
- Create: `pkgs/firmware/polyglot/merge-bl2.nix`

**Interfaces:**
- Consumes: `fsbl.nix` (core=arm → `bl2.bin`, core=riscv → `bl2.bin`), the two `.S` stubs,
  `merge_bl2.py`.
- Produces: `{ pkgs }: -> derivation` whose `$out` is `polyglot-bl2.bin`.

- [ ] **Step 1: Implement.**

```nix
# pkgs/firmware/polyglot/merge-bl2.nix
{ pkgs }:
let
  armFsbl   = import ../fsbl.nix { inherit pkgs; core = "arm"; };
  riscvFsbl = import ../fsbl.nix { inherit pkgs; core = "riscv"; slot = "secondary"; };
  armCC   = pkgs.pkgsCross.aarch64-embedded.stdenv.cc;
  riscvCC = pkgs.pkgsCross.riscv64-embedded.stdenv.cc;
in
pkgs.runCommand "polyglot-bl2.bin" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${armCC}/bin/${armCC.targetPrefix}gcc -c -o arm.o ${./stub-arm.S}
  ${armCC}/bin/${armCC.targetPrefix}objcopy -O binary arm.o arm-stub.bin
  ${riscvCC}/bin/${riscvCC.targetPrefix}gcc -march=rv64imac -c -o rv.o ${./stub-riscv.S}
  ${riscvCC}/bin/${riscvCC.targetPrefix}objcopy -O binary rv.o rv-stub.bin
  python3 ${./merge_bl2.py} ${armFsbl}/bl2.bin ${riscvFsbl}/bl2.bin arm-stub.bin rv-stub.bin "$out"
''
```

- [ ] **Step 2: Build + inspect.** `Run: nix build --no-link --print-out-paths -f pkgs/firmware/polyglot/merge-bl2.nix ... --max-jobs 0` (or via a flake attr). Then
  `xxd -l 4 $out` → `6f000014`; `stat -c%s $out` ≤ `0x37000` (229376). Confirms it builds.

- [ ] **Step 3: Commit.**

```bash
git add pkgs/firmware/polyglot/merge-bl2.nix
git commit --no-gpg-sign -m "polyglot: nix build for the merged BL2 (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: secondary FSBL variant (`fsbl.nix` slot + bl2_opt.c patch)

**Files:**
- Modify: `pkgs/firmware/fsbl.nix` (add `slot ? "primary"` param + apply the patch when
  `slot == "secondary"`)
- Create: `pkgs/firmware/fsbl-secondary-slots.patch` (bl2_opt.c redirect)

**Interfaces:**
- Consumes: nothing new.
- Produces: `import ./fsbl.nix { inherit pkgs; core = "riscv"; slot = "secondary"; }` builds a
  riscv BL2 that loads its monitor from BLCP_2ND and its u-boot from LOADER_2ND_B (raw).

- [ ] **Step 1: Write the patch.** Redirect the two reads in `plat/cv181x/bl2/bl2_opt.c`.
  `load_monitor`: swap the `monitor_*` fields for `blcp_2nd_*` (verified: `blcp_2nd_runaddr`
  is DRAM-range-checked, so `0x80000000` passes). U-boot: make `load_loader_2nd` read the
  raw `loader_2nd_b_*` payload via the existing `load_uboot()` reader path (`bl2_opt.c:342`),
  bypassing the `loader_2nd_header`/LZMA parse (LOADER_2ND_B is stored raw by fiptool). Pin
  the exact hunk against `29edcfa` when implementing — the redirect is:

```c
/* fsbl-secondary-slots.patch (conceptual — pin exact context at 29edcfa)
 * load_monitor: fip_param2.monitor_*  -> fip_param2.blcp_2nd_*
 * load_loader_2nd: read fip_param2.loader_2nd_b_{loadaddr,size} raw
 *   (reuse load_uboot()); skip the loader_2nd_header magic/decompress branch.
 */
```
  Implement it as a real unified diff generated the same way this repo builds
  `pkgs/kernel/patches/*.patch` (extract source, edit a copy, `diff -u`, `patch -p1 --dry-run`
  to confirm it applies to `29edcfa`).

- [ ] **Step 2: Add the `slot` param to fsbl.nix.**

```nix
# pkgs/firmware/fsbl.nix — add to the function args:
{ pkgs, core ? "arm", dumpRom ? false, slot ? "primary" }:
# ...in postPatch, after the existing core-specific patches:
+ (if slot == "secondary" then ''
+     patch -p1 < ${./fsbl-secondary-slots.patch}
+   '' else "")
```

- [ ] **Step 3: Build test — it compiles.** `Run: nix build --no-link --max-jobs 0 --impure
  --expr 'import ./pkgs/firmware/fsbl.nix { pkgs = import <nixpkgs>{}; core = "riscv"; slot =
  "secondary"; }'` → produces `bl2.bin`. Compare size to the primary riscv bl2 (should differ
  only slightly).

- [ ] **Step 4: Commit.**

```bash
git add pkgs/firmware/fsbl.nix pkgs/firmware/fsbl-secondary-slots.patch
git commit --no-gpg-sign -m "polyglot: secondary FSBL variant reads BLCP_2ND + LOADER_2ND_B (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: fip-polyglot.nix (pack the polyglot fip)

**Files:**
- Create: `pkgs/firmware/fip-polyglot.nix`
- Test: a build-time python check that fiptool re-parses `$out` and the entry word is at BL2 slot start.

**Interfaces:**
- Consumes: `merge-bl2.nix` (BL2), `bl31-blob.nix` (arm monitor), `opensbi-fw-dynamic.nix`
  (riscv monitor), `uboot-duos-arm.nix` (arm u-boot raw, LZMA'd by genfip), `uboot-duos-riscv.nix`
  (riscv u-boot raw → LOADER_2ND_B raw), `fsbl.nix` arm `chip_conf.bin` (shared).
- Produces: `{ pkgs }: -> derivation`, `$out` = `sg2000-fip-polyglot.bin`.

- [ ] **Step 1: Implement** (mirror `fip.nix`'s genfip; add the two secondary slots):

```nix
# pkgs/firmware/fip-polyglot.nix
{ pkgs }:
let
  fsblSrc   = (import ./fip.nix { inherit pkgs; }).fsblSrc or (pkgs.fetchFromGitHub {
    owner = "sophgo"; repo = "fsbl"; rev = "29edcfa0b5f999c8ea8f0759b0dd0038421e6c25";
    hash = "sha256-AzeOovjmxtwswNYpWViUKllKEVI9LLbcyqnOVcYPvGo=";
  });
  bl2       = import ./polyglot/merge-bl2.nix { inherit pkgs; };
  chipConf  = import ./fsbl.nix { inherit pkgs; core = "arm"; };   # shared chip_conf.bin
  armMon    = import ./bl31-blob.nix { inherit pkgs; };
  riscvMon  = import ./opensbi-fw-dynamic.nix { inherit pkgs; };
  armUboot  = import ./uboot-duos-arm.nix { inherit pkgs; };
  riscvUboot= import ./uboot-duos-riscv.nix { inherit pkgs; };
in
pkgs.runCommand "sg2000-fip-polyglot.bin" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${fsblSrc}/plat/cv181x/fiptool.py -v genfip \
    "$out" \
    --MONITOR_RUNADDR=0x80000000 \
    --BLCP_2ND_RUNADDR=0x80000000 \
    --CHIP_CONF=${chipConf}/chip_conf.bin \
    --NOR_INFO=FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF \
    --NAND_INFO=00000000 \
    --BL2=${bl2} \
    --BLCP_IMG_RUNADDR=0x05200200 --BLCP_PARAM_LOADADDR=0 \
    --BLCP=${fsblSrc}/test/empty.bin \
    --BLCP_2ND=${riscvMon} \
    --MONITOR=${armMon} \
    --LOADER_2ND=${armUboot}/u-boot-raw.bin \
    --LOADER_2ND_B=${riscvUboot}/u-boot-raw.bin \
    --compress=lzma
''
```
  (Confirm the exact genfip flag spelling for `--BLCP_2ND_RUNADDR` and `--LOADER_2ND_B` from
  `fiptool.py` `add_argument` calls when implementing; the slots exist, the flags may need the
  precise names.)

- [ ] **Step 2: Build + validate structure off-hardware.**

```bash
nix build --no-link --print-out-paths --max-jobs 0 -f ... fip-polyglot
# BL2 slot's first 4 bytes = the entry word; parse with fiptool or xxd at the BL2 offset.
python3 pkgs/firmware/polyglot/validate_fip.py $out   # asserts: entry word present, both
# monitor slots non-empty, LOADER_2ND + LOADER_2ND_B non-empty, param CRCs self-consistent.
```
  Write `validate_fip.py` to re-read the fip via `fiptool.py`'s parse path (or by offset) and
  assert the slots are populated and CRCs recompute. This is the last off-hardware gate.

- [ ] **Step 3: Commit.**

```bash
git add pkgs/firmware/fip-polyglot.nix pkgs/firmware/polyglot/validate_fip.py
git commit --no-gpg-sign -m "polyglot: pack the unified fip (both cores' monitor+uboot) (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: ship the polyglot as fip.bin (make-boot-dir + deploy), keep split recovery

**Files:**
- Modify: `pkgs/sdcard/make-boot-dir.nix`
- Modify: `modules/duo-s/deploy.nix`

**Interfaces:**
- Consumes: `fip-polyglot.nix`.
- Produces: SD images + deploys where `/boot/fip.bin` = the polyglot, and
  `/boot/fip-arm.bin` + `/boot/fip-riscv.bin` remain (recovery).

- [ ] **Step 1: make-boot-dir.nix** — set `fip.bin` to `${import ../firmware/fip-polyglot.nix
  { pkgs = pkgs.buildPackages; }}`; keep emitting `fip-arm.bin`/`fip-riscv.bin` from `fip.nix`.

- [ ] **Step 2: deploy.nix** — change the `fip` binding to the polyglot for the active
  `fip.bin`; keep refreshing `fip-<core>.bin` from `fip.nix` as recovery. The installer logic
  (write `fip-<core>.bin` + refresh active `fip.bin`) stays; only the `fip.bin` source changes
  to the polyglot (which is core-agnostic — always the same file regardless of the deployed core).

- [ ] **Step 3: Build both SD images** (arm + riscv) `--max-jobs 0`; confirm they realize and
  the `fip.bin` in each equals the polyglot hash and `fip-{arm,riscv}.bin` are the split fips.

- [ ] **Step 4: Commit.**

```bash
git add pkgs/sdcard/make-boot-dir.nix modules/duo-s/deploy.nix
git commit --no-gpg-sign -m "polyglot: ship it as fip.bin, keep split fips as recovery (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: swap-core / bootswap → latch-only

**Files:**
- Modify: `pkgs/sdcard/swap-core.nix`
- Modify: `modules/duo-s/bootswap.nix`
- Modify: nix-badge `core`/`bootswap` command (grep `pkgs/badge/nix-badge/*.zig` for the fip
  copy in the bootswap path)

**Interfaces:**
- Produces: `swap-core <arch>` sets the latch only (no `cp fip-$core.bin fip.bin`); nix-badge
  `bootswap` latches only; the wrong-fip/`E:RESET` guard rationale is removed.

- [ ] **Step 1: swap-core.nix** — drop the `cp -f "$bootdir/fip-$core.bin" "$bootdir/fip.bin"`
  and its `sync`; update the messages to say the polyglot fip serves both cores and only the
  latch changes. Keep the "target core has a kernel" check.

- [ ] **Step 2: nix-badge bootswap** — remove the native fip copy; keep the latch set + reboot.
  Update comments in `modules/duo-s/bootswap.nix` (the "swaps the fip BEFORE latching, reverts
  if the latch fails" rationale no longer applies — a static polyglot always matches).

- [ ] **Step 3: Build nix-badge; run its Zig tests** (`nix build` the badge package). Confirm
  no reference to `fip-$core.bin` copying remains: `grep -rn "fip-" pkgs/badge/nix-badge` is empty.

- [ ] **Step 4: Commit.**

```bash
git add pkgs/sdcard/swap-core.nix modules/duo-s/bootswap.nix pkgs/badge/nix-badge
git commit --no-gpg-sign -m "polyglot: swap-core/bootswap become latch-only (#48)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: bench bring-up (bisecting) — the one on-hardware gate

**Files:** none (verification + a RESULTS note).

**Prereq load (ask the human up front):** SD reader available for recovery; serial console
(ser2net tcp/3333) up; board switch reachable to set AUTO.

- [ ] **Step 1: Deploy the polyglot as fip.bin** (over eth0 per the deploy path) OR flash a
  fresh SD. Keep `fip-arm.bin`/`fip-riscv.bin` present.
- [ ] **Step 2: ARM strap.** `nix-badge core arm`, switch AUTO, reboot. Serial expected: the
  arm FSBL banner (`FSBL <ver>...`, no `E:RESET`), boot to Linux, `readlink /run/booted-system`
  = the arm generation. **Validates:** entry word + arm trampoline + relocation + primary slots.
- [ ] **Step 3: RISC-V strap.** `nix-badge core riscv`, reboot. Serial expected: the riscv
  FSBL banner, boot to Linux. **Validates:** riscv trampoline + the `bl2_opt.c` secondary-slot
  patch + BLCP_2ND/LOADER_2ND_B packing.
- [ ] **Step 4: Confirm no `E:RESET:plat/mars/platform.c` on either strap.** If either fails,
  ROLL BACK: `cp fip-arm.bin fip.bin` (still-booting core or SD reader), then bisect from the
  serial trace (which stage's NOTICE was last printed).
- [ ] **Step 5: Record** the split in the target's RESULTS.md (both cores boot from one
  static fip; core-switch = latch-only, no SD touch). Mark #48 done.

---

## Notes for the executor

- **The only irreversible risk is a bad fip.bin** → SD reflash. Tasks 1-8 are entirely
  off-hardware and must all pass their checks before Task 9 touches the board.
- **If the riscv stub exceeds 124 bytes** (Task 2), the merge tool (Task 3) must place a
  `j`-to-relocator at offset 320 and the relocator body after offset 444 (before 0x1000);
  update `merge_bl2.py` + its test accordingly.
- **Secure boot** is out of scope this round but the design is ready (spec § "Secure-boot
  enablement"); do not add eFuse/signing.
- **Do not remove** `fip-arm.bin`/`fip-riscv.bin` anywhere — they are the recovery path.
