#!/usr/bin/env bash
# Reproduce the fix GC panic: "gc: minor mark not closed — missed edge".
#
# Reproduces IDENTICALLY on main (2b23db57) and v0.3.0 (2141010). Pick either:
set -euo pipefail
REV="${1:-2b23db57bfe4e1ae498ca4f841358a5c52752699}"   # or: v0.3.0
here="$(cd "$(dirname "$0")" && pwd)"

# 1. fetch fix at REV
rm -rf "$here/fix-src"
git clone --quiet https://github.com/psyclyx/fix "$here/fix-src"
git -C "$here/fix-src" checkout --quiet "$REV"

# 2. fetch-less fetcher stubs — NOT required for the bug, only so the build has no
#    libcurl/libgit2 C closure. (The bug is purely in eval/GC.)
cp "$here/stub_root.zig"  "$here/fix-src/src/fetchers/stub_root.zig"
cp "$here/stub_cache.zig" "$here/fix-src/src/fetchers/stub_cache.zig"

# 3. native-apply.patch — adds Engine.applyValue + Engine.makeAttrs: apply a
#    compile-once lambda to a fresh arg per call with NO recompile. This is the
#    per-frame path the bug needs (pure `fix eval` does NOT reproduce it).
patch -p1 -d "$here/fix-src" < "$here/native-apply.patch"

# 4. build + run the repro. ReleaseSafe => fix's gc_debug detector is ON, so the
#    missed edge panics loudly instead of silently corrupting.
cd "$here/harness"
# On v0.3.0 add -Dsha-hw=false (it lacks src/base/sha256_hw.zig).
SHA_HW_FLAG=""
[ -f "$here/fix-src/src/base/sha256_hw.zig" ] || SHA_HW_FLAG="-Dsha-hw=false"
echo ">>> zig build test -Dfix-src=$here/fix-src $SHA_HW_FLAG -Doptimize=ReleaseSafe"
zig build test -Dfix-src="$here/fix-src" $SHA_HW_FLAG -Doptimize=ReleaseSafe

# EXPECTED (the bug): the test 'gc missed-edge repro' crashes at ~frame 20 with
#   thread N panic: gc: minor mark not closed — missed edge
#   GC MISSED EDGE: thunk 149 -> unmarked young attrs 39783   (and similar)
# A FIXED evaluator instead reaches "DONE" (see /tmp/repro_prog.txt for progress;
# it survives the abort because it is written via a raw syscall).
