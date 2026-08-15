#!/usr/bin/env python3
# Decode a captured FSBL mask-ROM dump (see fsbl.nix dumpRom) into a binary.
#
# The dump-enabled BL2 prints, early in boot:
#   ROMDUMP_BEGIN
#   <96 KiB of the boot ROM as hex bytes, in address order, newline-wrapped>
#   ROMDUMP_END
# Capture the full boot serial log to a file, then:
#   python3 romdump-decode.py boot.log rom.bin
#
# Everything between the markers that is not a hex digit (newlines, any stray
# console bytes) is stripped, so a leading timestamp/prefix per line is fine.
import re
import sys

if len(sys.argv) != 3:
    sys.exit("usage: romdump-decode.py <captured-serial.log> <out.bin>")

raw = open(sys.argv[1], "r", errors="replace").read()
m = re.search(r"ROMDUMP_BEGIN(.*?)ROMDUMP_END", raw, re.S)
if not m:
    sys.exit("no ROMDUMP_BEGIN..ROMDUMP_END block found (capture incomplete?)")

hx = re.sub(r"[^0-9a-fA-F]", "", m.group(1))
if len(hx) % 2:
    print("warning: odd hex length, dropping last nibble (likely dropped bytes)")
    hx = hx[:-1]

out = bytes.fromhex(hx)
open(sys.argv[2], "wb").write(out)

EXPECTED = 0x18000  # ROM_SIZE
note = "" if len(out) == EXPECTED else (
    f"  WARNING: expected {EXPECTED} bytes; serial capture likely dropped data."
)
print(f"wrote {len(out)} bytes ({len(out) / 1024:.1f} KiB) to {sys.argv[2]}{note}")
