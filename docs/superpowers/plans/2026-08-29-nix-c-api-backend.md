# Nix C API Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second, runtime-selectable per-frame Nix evaluator backend to `nix-badge` using the upstream Nix C API (`libnixexpr`/`nix_api_*`), alongside the existing fix backend, so fix vs upstream Nix can be A/B'd on the badge for the OLED screens and the LED patterns (fps, per-frame eval time, RSS).

**Architecture:** Introduce a backend-agnostic seam (`eval.zig`) whose `Frame.bitmap` is a plain `[]const i64` and whose `decodeOled`/`decodeOledDelta`/`decodeLeds` are shared. `fixeval.zig` slims to a `FixBackend` that produces `[]i64`; a new `nixeval.zig` `NixBackend` produces `[]i64` via the C API. A `Backend` union selects at runtime (`--backend fix|nix`). The C++ Nix static libs link directly into the Zig binary via `nix-badge.nix`, gated on `have_nix` (aarch64 only this round).

**Tech Stack:** Zig 0.16 (static-musl cross to aarch64), the upstream Nix C API (`nix-expr-c` static component, nix 2.34.8 from nixpkgs 26.05), fix (`psyclyx/fix` `expr`, already vendored), boehm-gc, `@cImport`.

**Spec:** `docs/superpowers/specs/2026-08-29-nix-c-api-backend-design.md`

## Global Constraints

- **Static musl aarch64** target; the fix-only build (and riscv) must be **byte-for-byte unchanged when `nixEval` is off** (`have_nix=false`). Same discipline as `fixSrc`/`have_fix`.
- **nix backend gated to aarch64 this round**; riscv stays fix. `have_nix` is false on riscv.
- **Content contract is frozen**: `scope: { bitmap = [ints]; nextMs; delta?; n? }`. Both backends evaluate the *same* screens/patterns. Do not change the contract or the delta codec.
- **The 60fps fix path must not regress**: after Phase 1, deploy and confirm `oled: ~60 fps` on Bad Apple before adding nix.
- **Shared decode operates on `[]const i64`**; the A/B is only fair if both backends feed the identical decode.
- **Pure eval only** (`dummy://` store, no `import`/fetch) — matches fix's fetch-less constraint.
- Commits: `--no-gpg-sign`, trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Heavy nix builds run under `systemd-run --user --scope -p MemoryMax=12G`; one at a time.
- Branch: `nix-c-api-backend`.

---

## Phase 1 — Extract the shared `[]i64` decode seam (fix keeps working)

Goal: move the decode + frame types out of fix's `Value` world into `eval.zig` operating on `[]const i64`, refactor `fixeval.zig` to a `FixBackend` that produces `[]i64`, and prove the fix 60fps path is unchanged. **No nix yet.**

### Task 1.1: `eval.zig` — backend-agnostic types + shared decode on `[]const i64`

**Files:**
- Create: `pkgs/badge/nix-badge/eval.zig`
- Test: `pkgs/badge/nix-badge/eval.zig` (in-file `test` blocks; run with `zig test`)

**Interfaces:**
- Produces: `eval.Fields` (struct, fields identical to the current `fixeval.Fields` incl. `frame_index`), `eval.Frame { bitmap: []const i64, next_ms: i64, delta: bool = false, n: u32 = 0 }`, `eval.Dirty` (identical to current `fixeval.Dirty`: `full: bool`, `changed: [8]u128`, `max_pages=8`), `eval.OledFrame { next_ms: u32, dirty: Dirty }`, and:
  - `pub fn decodeLeds(bitmap: []const i64, brightness: u8, out: []Rgb) void`
  - `pub fn decodeOled(bitmap: []const i64, out: []u8, width: u32) Dirty`  (full-frame: 4 page-bytes/int LE; delta path split by caller)
  - `pub fn decodeOledFrame(frame: Frame, out: []u8, width: u32) Dirty` (dispatches full vs delta on `frame.delta`)
  - `pub const collect_every: u64 = 64;`

- [ ] **Step 1: Write the failing tests** (append to `eval.zig`)

```zig
const std = @import("std");
const Rgb = @import("ws2812.zig").Rgb;

test "decodeOled full frame: 4 page-bytes/int LE, zero tail" {
    var out: [8]u8 = undefined;
    // two ints -> 8 bytes: 0x04030201, 0x08070605
    const bm = [_]i64{ 0x04030201, 0x08070605 };
    const d = decodeOled(&bm, &out, 8);
    try std.testing.expect(d.full);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &out);
}

test "decodeOledFrame delta: 2 entries/int, applies to persistent fb + marks columns" {
    var out = [_]u8{0} ** 8; // width=8 => 1 page of 8 columns (page-major)
    // change col 2 -> 0xAB and col 5 -> 0xCD, packed 2/int: E=offset*256+byte
    const e0: i64 = 2 * 256 + 0xAB;
    const e1: i64 = 5 * 256 + 0xCD;
    const packed_int: i64 = e0 * 262144 + e1; // E0 high 18 bits
    const f = Frame{ .bitmap = &.{packed_int}, .next_ms = 16, .delta = true, .n = 2 };
    const d = decodeOledFrame(f, &out, 8);
    try std.testing.expect(!d.full);
    try std.testing.expectEqual(@as(u8, 0xAB), out[2]);
    try std.testing.expectEqual(@as(u8, 0xCD), out[5]);
    // page 0 changed cols 2 and 5
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 2) != 0);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 5) != 0);
    try std.testing.expect(d.changed[0] & (@as(u128, 1) << 3) == 0);
}

test "decodeLeds: 0xRRGGBB per int, brightness-scaled, dark tail" {
    const ws = @import("ws2812.zig");
    var out: [2]Rgb = undefined;
    decodeLeds(&.{0xFF8040}, 255, &out);
    try std.testing.expectEqual(ws.scaleChannel(0xFF, 255), out[0].r);
    try std.testing.expectEqual(ws.scaleChannel(0x80, 255), out[0].g);
    try std.testing.expectEqual(ws.scaleChannel(0x40, 255), out[0].b);
    try std.testing.expectEqual(@as(u8, 0), out[1].r); // tail dark
}
```

- [ ] **Step 2: Run the tests, verify they fail** (types/functions undefined)

Run: `cd pkgs/badge/nix-badge && zig test eval.zig`
Expected: FAIL (Fields/Frame/Dirty/decode* undefined).

- [ ] **Step 3: Implement the types + decode**, porting the bodies verbatim from the current `fixeval.zig` but reading `i64` from `bitmap[i]` instead of `(try ev.forceValue(p)).asInt()`. Full frame:

```zig
pub const Fields = struct {
    t_ms: u64 = 0, width: u32 = 0, height: u32 = 0,
    battery_mv: u32 = 0, battery_pct: u8 = 0, on_usb: bool = false,
    load1: f64 = 0, cpu_pct: u8 = 0, mem_pct: u8 = 0, uptime_s: u32 = 0,
    brightness: u8 = 255, frame_index: u64 = 0,
};
pub const Dirty = struct {
    pub const max_pages = 8;
    full: bool = true,
    changed: [max_pages]u128 = .{0} ** max_pages,
};
pub const OledFrame = struct { next_ms: u32, dirty: Dirty };
pub const Frame = struct { bitmap: []const i64, next_ms: i64, delta: bool = false, n: u32 = 0 };
pub const collect_every: u64 = 64;

pub fn decodeOled(bitmap: []const i64, out: []u8, width: u32) Dirty {
    _ = width;
    const words = out.len / 4;
    const n = @min(bitmap.len, words);
    for (bitmap[0..n], 0..) |v, i| {
        out[i * 4 + 0] = @intCast(v & 0xff);
        out[i * 4 + 1] = @intCast((v >> 8) & 0xff);
        out[i * 4 + 2] = @intCast((v >> 16) & 0xff);
        out[i * 4 + 3] = @intCast((v >> 24) & 0xff);
    }
    for (out[n * 4 ..]) |*b| b.* = 0;
    return .{ .full = true };
}

pub fn decodeOledFrame(frame: Frame, out: []u8, width: u32) Dirty {
    if (!frame.delta) return decodeOled(frame.bitmap, out, width);
    var d: Dirty = .{ .full = false };
    if (width == 0) return d;
    const entry_mask: i64 = 0x3ffff;
    var i: u32 = 0;
    while (i < frame.n) : (i += 1) {
        const int_idx = i / 2;
        if (int_idx >= frame.bitmap.len) break;
        const v = frame.bitmap[int_idx];
        const e: i64 = if (i & 1 == 0) (v >> 18) & entry_mask else v & entry_mask;
        const offset: usize = @intCast(e >> 8);
        if (offset >= out.len) continue;
        out[offset] = @intCast(e & 0xff);
        const page = offset / width;
        const col = offset % width;
        if (page < Dirty.max_pages and col < 128) d.changed[page] |= @as(u128, 1) << @intCast(col);
    }
    return d;
}

pub fn decodeLeds(bitmap: []const i64, brightness: u8, out: []Rgb) void {
    const ws2812 = @import("ws2812.zig");
    const n = @min(bitmap.len, out.len);
    for (bitmap[0..n], 0..) |v, i| {
        out[i] = .{
            .r = ws2812.scaleChannel(@intCast((v >> 16) & 0xff), brightness),
            .g = ws2812.scaleChannel(@intCast((v >> 8) & 0xff), brightness),
            .b = ws2812.scaleChannel(@intCast(v & 0xff), brightness),
        };
    }
    for (out[n..]) |*px| px.* = .{ .r = 0, .g = 0, .b = 0 };
}
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `cd pkgs/badge/nix-badge && zig test eval.zig`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add pkgs/badge/nix-badge/eval.zig
git commit --no-gpg-sign -m "nix-badge: eval.zig -- backend-agnostic []i64 decode seam

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 1.2: Refactor `fixeval.zig` to a `FixBackend` producing `[]i64`

**Files:**
- Modify: `pkgs/badge/nix-badge/fixeval.zig` (whole file — retarget onto `eval.zig`)
- Modify: `pkgs/badge/nix-badge/nix-badge.zig` (the loop: use `eval.decodeOledFrame`/`eval.OledFrame`/`eval.Fields` where it currently uses `fixeval.*`; `flushDirty` takes `eval.Dirty`)

**Interfaces:**
- Consumes: `eval.Fields`, `eval.Frame`, `eval.Dirty`, `eval.OledFrame`, `eval.decodeOledFrame`, `eval.decodeLeds`, `eval.collect_every`.
- Produces: `fixeval.FixBackend` with:
  - `pub fn open(gpa, paths: []const []const u8, bitmap_cap: usize) ?FixBackend` — compiles lambdas, pins roots, allocs the reusable `[]i64` of length `bitmap_cap`.
  - `pub fn applyFrame(self: *FixBackend, idx: usize, fields: eval.Fields) !eval.Frame` — builds scope (incl. `frameIndex`), `applyValue`, reads `delta`/`n`, forces the bitmap list and writes ints into `self.ints[0..len]`, returns `eval.Frame{ .bitmap = self.ints[0..len], ... }`. `idx` selects among N lambdas (LED = single lambda at idx 0).
  - `pub fn collect(self: *FixBackend) void`, `pub fn deinit`, `pub fn count`, `pub fn name(idx)`.
  - Keep `have_fix`.

- [ ] **Step 1: Write a failing host-buildable smoke** — extend `fixeval.zig`'s existing `test` (or add one gated behind `have_fix`) that, when `have_fix`, compiles a trivial pattern `scope: { bitmap = [ 1 2 ]; nextMs = 10; }`, calls `applyFrame(0, .{})`, and asserts `frame.bitmap` == `.{1,2}` and `frame.next_ms == 10`. If `have_fix` is false at host `zig test`, skip (the real test is the on-badge build).

Note: `applyFrame` extracts ints via `for (list) |v| self.ints[k] = (try ev.forceValue(v)).asInt();` — this is the ONLY place fix `Value`s are touched now.

- [ ] **Step 2: Verify current fix references compile against the new seam** — build the whole aarch64 toplevel (the real compile of `have_fix`):

Run:
```bash
systemd-run --user --scope -p MemoryMax=12G nix build \
  '.#nixosConfigurations."duo-s-arm-x86_64".config.system.build.toplevel' --print-build-logs 2>&1 | tail
```
Expected initially: FAIL — `nix-badge.zig`/`fixeval.zig` still reference removed `fixeval.Fields`/`decodeOled`/`Dirty`/`OledFrame`.

- [ ] **Step 3: Do the refactor.** In `fixeval.zig`: delete the moved types (`Fields`,`Dirty`,`OledFrame`,`Frame`) and the decode fns (`decodeOled`,`decodeOledDelta`,`decodeLeds`), `const eval = @import("eval.zig");`, and reshape `Pattern`/`ScreenSet` into one `FixBackend` per the Produces block — `applyFrame` fills `self.ints`. In `nix-badge.zig`: replace `fixeval.Fields`→`eval.Fields`, `fixeval.OledFrame`→`eval.OledFrame`, `fixeval.Dirty`→`eval.Dirty`, and the eval-screen render to `const f = try set.applyFrame(idx, evalFields(...)); const dirty = eval.decodeOledFrame(f, b, panel.width); const want = set.finishFrame(f.next_ms);` (keep the per-screen playback reset + collect-cadence inside `FixBackend`/a small `ScreenSet`-like holder — see Task 3.1 for where the union lands; in this task keep it fix-only and working).

- [ ] **Step 4: Rebuild the toplevel, verify it compiles**

Run: same as Step 2. Expected: exit 0.

- [ ] **Step 5: Deploy + verify 60fps fix path unchanged**

```bash
nix run github:serokell/deploy-rs -- '.#nixbadge-duos-arm' --hostname 10.8.3.134 --ssh-user badge --skip-checks
ssh badge@10.8.3.134 'journalctl -u nixbadge-oled --since "-30s" -o cat | grep "fps ("'
```
Expected: `oled: ~60 fps (badapple-live) ...`, no render faults. Camera-verify clean Bad Apple.

- [ ] **Step 6: Commit**

```bash
git add pkgs/badge/nix-badge/fixeval.zig pkgs/badge/nix-badge/nix-badge.zig
git commit --no-gpg-sign -m "nix-badge: fix evaluator behind FixBackend ([]i64 seam); 60fps unchanged

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase 2 — `nixeval.zig` NixBackend + direct Zig↔C++ static link

### PROVEN LINK RECIPE (spike 2026-08-29, `zig cc` end-to-end: links + runs 36.7 MB aarch64-musl)

- Component attr: `pkgs.pkgsStatic.nixVersions.nixComponents_2_34."nix-expr-c"` (out=libs, dev=headers+.pc); siblings `nix-store-c`, `nix-util-c` for the other `nix_api_*.h`.
- Link line (inside `-Wl,--start-group ... -Wl,--end-group`, `-static`):
  - `pkg-config --libs --static nix-expr-c` **with `-Wl,--wrap=*` filtered out** (zig cc: `unsupported linker arg: --wrap`; drops nix's `__assert_fail` wrap, harmless).
  - 4 extra `-L` that `--static` omits: `pkgsStatic.{acl, bzip2, libunistring, llhttp}`/lib.
  - `libstdc++.a` FULL PATH: `<pkgsStatic.stdenv.cc.cc.lib>/aarch64-unknown-linux-musl/lib/libstdc++.a`.
  - `libgcc.a` FULL PATH (has `_Unwind_*`): `<pkgsStatic.stdenv.cc.cc>/lib/gcc/aarch64-unknown-linux-musl/<ver>/libgcc.a`.
- `linkLibC` (musl), NOT `linkLibCpp` (LLVM libc++ is ABI-incompatible with gcc libstdc++).
- Includes: the three `*-c` dev `/include` dirs.
- All the transitive `-L` from `nix-store -q --requisites --include-outputs <nix-expr-c.drv> | grep static-aarch64.../lib` (build closure) — in Nix, derive via `pkgs.closureInfo` on the C-API components' dev+out, or enumerate.

### Task 2.1: `nix-badge.nix` — link the Nix C API static libs (gated `nixEval`)

**Files:**
- Modify: `pkgs/badge/nix-badge.nix`
- Modify: `pkgs/badge/nix-badge/build.zig` (add `-Dnix-include` / `-Dnix-libdirs` options, mirror the `-Dfix-src` handling)

**Interfaces:**
- Produces: a build where `have_nix` (a `build_options` bool) is true on aarch64, false elsewhere; when true, the exe links `libnixexprc` + all transitive aarch64-musl static libs + `libstdc++`, and `@cImport` can find `nix_api_*.h`.

- [ ] **Step 1:** In `nix-badge.nix`, add a param `nixEval ? true` and compute (aarch64 only):
  - `nixExprC = pkgs.pkgsStatic.<nix-expr-c>` — obtain the static `nix-expr-c` (out+dev). If not a clean attr, derive it from the `nix` package's build graph (the spike used the drv directly: `pkgsCross.aarch64-multiplatform-musl.pkgsStatic.nix`'s `nix-expr-c-static` input). Prefer exposing it via `pkgs.nixVersions` or an overlay; document the exact attr found.
  - `nixIncludes` = the three `nix_api_*` include dirs (nix-expr-c-dev, nix-store-c-dev, nix-util-c-dev).
  - `nixLibDirs` = every `*-static-*/lib` in `nix-store -q --requisites --include-outputs` of the `nix-expr-c` derivation (compute with `pkgs.lib`/`closureInfo` at build time, or a small `runCommand` that emits the `-L` list).
- [ ] **Step 2:** Pass `-Dnix-include=<colon-list>` and `-Dnix-libdirs=<colon-list>` (+ `-Dhave-nix=true`) to `zig build`, gated on `hp.isAarch64 && nixEval != null`. In `build.zig`, when `have-nix`, `exe.addIncludePath` each include, `exe.addLibraryPath` each libdir, `exe.linkSystemLibrary("nixexprc")` (+ the transitive `-l` names from `pkg-config --libs --static nix-expr-c`, or `linkSystemLibrary` each), `exe.linkLibCpp()` (libstdc++), and set `build_options.have_nix`.
- [ ] **Step 3:** Add a temporary `have_nix` probe in `nix-badge.zig` main: `if (build_options.have_nix) std.log.info("nix backend available", .{});` — just to force the link without real usage yet.
- [ ] **Step 4:** Build the toplevel (capped). Expected: links; the exe grows ~30 MB. If LLD + libstdc++ ABI errors appear (unresolved C++ symbols / ABI mismatch), switch to the **shim fallback**: add `nixeval_shim.cpp` compiled by the nix cross-`g++` in `nix-badge.nix` (a `runCommand` producing `nixeval_shim.o`), pass its path via `-Dnix-shim-obj=`, `exe.addObjectFile` it, and drop the direct C++ link. Record which path worked.
- [ ] **Step 5:** Confirm the **fix-only build is unchanged**: build with `nixEval = null` (or on riscv) and diff `have_nix=false`; the toplevel drv hash must match the pre-Phase-2 fix build.
- [ ] **Step 6: Commit** (`nix-badge: link upstream Nix C API static libs (gated have_nix, aarch64)`).

### Task 2.2: `nixeval.zig` NixBackend + `nix-selftest`

**Files:**
- Create: `pkgs/badge/nix-badge/nixeval.zig`
- Modify: `pkgs/badge/nix-badge/nix-badge.zig` (add a hidden `nix-selftest` subcommand)

**Interfaces:**
- Produces: `nixeval.NixBackend` mirroring `FixBackend`'s surface: `open(gpa, paths, bitmap_cap) ?NixBackend`, `applyFrame(idx, fields) !eval.Frame`, `collect`, `deinit`, `count`, `name(idx)`, and `have_nix`. Also `pub fn selftest() bool` (evals `scope: scope.t + 1` applied to `{t=41;}`, returns `got == 42`).

- [ ] **Step 1:** `@cImport` the four headers (guarded by `have_nix`; a stub struct otherwise so the file type-checks on fix-only builds — mirror `have_fix`). Implement `open`: `nix_c_context_create`, `nix_libexpr_init`, `nix_store_open(ctx,"dummy://",null)`, `nix_state_create`, then per path `readPattern` + `nix_expr_eval_from_string(ctx,state,src,".",lambda)` and `nix_gc_incref(lambda)` to pin. Store the `nix_value*` lambdas + a reused `[]i64`.
- [ ] **Step 2:** Implement `applyFrame(idx, fields)` from the spike's proven sequence: `nix_make_bindings_builder(ctx,state,11)`, `nix_init_int/bool/float` + `nix_bindings_builder_insert` for each `Fields` member (camelCase names matching the contract: `t`,`frameIndex`,`width`,`height`,`batteryMv`,`batteryPct`,`onUsb`,`load1`,`cpuPct`,`memPct`,`uptimeS`), `nix_make_attrs(scope, bb)`, `nix_value_call(ctx,state,lambda,scope,res)`, `nix_value_force(res)`. Read `bitmap` via `nix_get_attr_byname(res,"bitmap")` + `nix_value_force` + `nix_get_list_size`/`nix_get_list_byidx` + `nix_get_int` into `self.ints`; read `nextMs`, optional `delta` (`nix_get_bool`), optional `n` (`nix_get_int`). Return `eval.Frame`. `nix_gc_decref` the per-frame temporaries. Check every `nix_err`; on error return the Zig error (caller drops the screen).
- [ ] **Step 3:** Add `nix-selftest` subcommand to `nix-badge.zig` dispatch: `if (nixeval.have_nix) { if (nixeval.selftest()) { print OK; exit 0 } else exit 1 } else print "nix backend not built" exit 2`.
- [ ] **Step 4:** Build the toplevel; run the selftest under qemu/binfmt on the built binary (the store path), or on the badge after deploy:

Run (host, binfmt): `qemu-aarch64 $(find result -name nix-badge) nix-selftest` → Expected: `OK: nix c-api ... 42`.

- [ ] **Step 5: Commit** (`nix-badge: nixeval.zig NixBackend via the Nix C API + nix-selftest`).

---

## Phase 3 — Wire runtime `--backend` selection + backend-tagged fps/eval/RSS harness

### Task 3.1: `Backend` union + `Pattern`/`ScreenSet` over it; `--backend` flag + options

**Files:**
- Modify: `pkgs/badge/nix-badge/eval.zig` (add the `Backend` union + `Pattern`/`ScreenSet` holders)
- Modify: `pkgs/badge/nix-badge/nix-badge.zig` (parse `--backend`, construct the chosen variant)
- Modify: `modules/duo-s/oled.nix`, `modules/duo-s/bling.nix` (add `backend` option → `--backend` arg)

**Interfaces:**
- Consumes: `fixeval.FixBackend`, `nixeval.NixBackend`.
- Produces: `eval.Backend = union(enum) { fix: fixeval.FixBackend, nix: nixeval.NixBackend }` with `open`, `applyFrame(idx,fields) !Frame`, `collect`, `deinit`, `count`, `name`; `eval.ScreenSet`/`eval.Pattern` hold a `Backend` + the per-screen playback state (frame_index, active_ix, play_idx, collect cadence) and expose `renderOled(idx,fields,out) !OledFrame` (applyFrame → `decodeOledFrame` → finishFrame) and `render(fields,out) !u32` (LED).

- [ ] **Step 1:** Add the union + holders to `eval.zig`; `Backend.open(gpa, which: enum{fix,nix}, paths, cap)` returns the requested variant, falling back to fix (logged once) if `which==.nix and !nixeval.have_nix`. Move the per-screen playback + collect cadence out of `FixBackend` into `eval.ScreenSet` so it's shared by both backends.
- [ ] **Step 2:** In `nix-badge.zig`, parse `--backend fix|nix` (default fix) in the oled + bling arg loops; pass the enum to `eval.Backend.open`. Replace the `fixeval.ScreenSet`/`Pattern` construction with `eval.ScreenSet`/`eval.Pattern`.
- [ ] **Step 3:** In `oled.nix`/`bling.nix`, add `nixbadge.oled.backend`/`nixbadge.bling.backend` (enum `"fix"`/`"nix"`, default `"fix"`), append `--backend ''${cfg.backend}` to the ExecStart.
- [ ] **Step 4:** Build + deploy; verify `nix-badge oled --backend fix` still 60fps, and `--backend nix` renders Bad Apple (camera + journal). Expected: both render; nix fps/RSS TBD.
- [ ] **Step 5: Commit** (`nix-badge: runtime --backend fix|nix selection over an eval.Backend union`).

### Task 3.1b: `scope.backend` + `scope.fps` into `Fields` (on-panel stats)

**Files:** `eval.zig` (Fields), `fixeval.zig` + `nixeval.zig` (scope build), `nix-badge.zig` (feed last-window fps + active backend name into Fields each frame).

**Interfaces:** `Fields` gains `backend: []const u8 = "fix"` and `fps: u32 = 0`. Both backends add `backend` (string) + `fps` (int) to the per-frame scope attrset (fix: intern via the Engine's string API in `makeAttrs`; nix: `nix_init_string`/`nix_init_int` + `nix_bindings_builder_insert`). The loop sets `Fields.fps = <last 3s-window fps>` and `Fields.backend = <active backend name>` before each `applyFrame`.

- [ ] **Step 1:** Add the two fields to `eval.Fields` (host `zig test` still green — no decode change).
- [ ] **Step 2:** fix `applyFrame` adds `{ backend = <string>; fps = <int>; }` to `makeAttrs`; nix `applyFrame` the equivalent. The info screens can now read `scope.backend`/`scope.fps`.
- [ ] **Step 3:** Loop threads the measured fps (already computed in the 3s window; carry it forward each frame) + the backend name into `Fields`.
- [ ] **Step 4:** Update one info screen (e.g. `currentsystem.nix` or a new `stats.nix`) to draw `scope.backend` + `scope.fps`; deploy + camera-verify it renders on both backends.
- [ ] **Step 5: Commit** (`nix-badge: expose scope.backend + scope.fps to screens`).

### Task 3.1c: >5s button hold switches the backend live

**Files:** `nix-badge.zig` (`oledWait` press tiers + a `want_switch_backend` flag + the loop's swap).

**Interfaces:** a third press tier: release with `held >= backend_switch_ms (5000)` sets `want_switch_backend`. The loop, on that flag, `deinit`s the active `eval.ScreenSet`/`Pattern` and re-`open`s the OTHER backend (recompiles the chunk; a few-second freeze is acceptable). Persist the chosen backend to `/var/lib/nix-badge/*.backend` so it survives a service restart (like the screen-index persistence).

- [ ] **Step 1:** Extend the `oledWait` release logic: `held >= 5000` -> `want_switch_backend.store(true)`, else the existing 400ms next-screen / next-pattern tiers.
- [ ] **Step 2:** In the loop, on `want_switch_backend.swap(false)`, rebuild the eval holder with the toggled backend enum; log the switch; persist it.
- [ ] **Step 3:** Deploy; on the badge, hold the button >5s and confirm the backend flips (journal `oled: backend -> nix`, and the on-panel `scope.backend` stat changes).
- [ ] **Step 4: Commit** (`nix-badge: >5s button hold switches the evaluator backend live`).

### Task 3.1d: contract `overlay` field — Nix overwrites arbitrary framebuffer bytes on top of any frame

**Contract extension (backward-compatible):** a frame may carry, in addition to `bitmap`,
an optional `overlay = [ packed (offset,byte) entries ]` (+ `overlayN = count`), packed
exactly like a delta (2 entries/int, `E = offset*256+byte`, high 18 bits first). The
runtime, AFTER decoding the main `bitmap` (full frame OR delta) into the framebuffer,
applies the `overlay` entries on top (same apply as `decodeOledFrame`'s delta path) and
ORs the touched columns into the returned `Dirty`. So a screen can overwrite arbitrary
bytes on top of any frame -- keyframe, delta, or full frame -- from Nix. Absent `overlay`
-> no-op (info screens/LED patterns unaffected).

`badapple-live.nix` computes the overlay each frame from `scope.backend`/`scope.fps` via a
small INLINED font (screens are self-contained; reuse the draw.nix/Spleen 5x8 glyph table
shape) rendering `[<backend>] <fps>fps` into (offset,byte) entries at a fixed corner
region. Corruption-safety: outside the corner the main delta accumulates cleanly; inside
the corner the accumulator collects garbage from the main delta but the overlay re-stamps
it every frame before flush.

**Files:** `eval.zig` (`Frame` gains `overlay: []const i64 = &.{}`, `overlay_n: u32 = 0`;
a shared `applyOverlay(bitmap, out, width, dirty) void` that applies + OR's into `dirty`),
`fixeval.zig`/`nixeval.zig` (`applyFrame` reads `overlay`/`overlayN` into a SECOND reused
`[]i64`), `nix-badge.zig` (call `applyOverlay` after `decodeOledFrame`), and a new
`pkgs/badge/bling-content/overlay-font.nix` (5x8 digits + a few letters) inlined into
`badapple-live.nix` + a `renderStats scope` helper.

- [ ] **Step 1: Host test** in `eval.zig`: `applyOverlay` writes the overlay entries over a
  framebuffer and marks exactly those columns dirty (mirror the delta decode test).
- [ ] **Step 2:** `Frame` + `applyFrame` (both backends) read the optional `overlay`/`overlayN`
  into a second `[]i64` buffer; `nix-badge.zig` applies it after the main decode.
- [ ] **Step 3:** `overlay-font.nix` (open-licensed 5x8, or reuse Spleen 5x8 already vendored)
  + `renderStats scope` in `badapple-live.nix` -> overlay entries from `scope.backend`/`scope.fps`.
- [ ] **Step 4:** Deploy; confirm `[fix] 60fps` renders in the corner over clean Bad Apple, the
  number updates each 3 s, and >5s hold flips it to `[nix] ...`.
- [ ] **Step 5: Commit** (`nix-badge: contract overlay field -- Nix draws arbitrary bytes over any frame`).

### Task 3.2: RSS + backend-tagged window log

**Files:**
- Modify: `pkgs/badge/nix-badge/nix-badge.zig` (the 3s window log)
- Create: `pkgs/badge/nix-badge/sysfs.zig` helper `readSelfRssKb() u64` (or inline)

**Interfaces:**
- Produces: `readSelfRssKb()` reads `/proc/self/statm` field 2 (resident pages) × page size / 1024.

- [ ] **Step 1: Failing test** for the parse: feed a fixed `statm` string `"1000 234 ..."`, assert `rss_kb == 234 * page_kb`. (Factor the parse to take the string.)
- [ ] **Step 2:** Implement `readSelfRssKb`; extend the window log to `oled: {d} fps [{s}] eval~{d}ms (collect~{d}ms) flush~{d}ms rss~{d}MB` where `[{s}]` is the backend name (`fix`/`nix`).
- [ ] **Step 3:** Build + deploy both backends; capture the journal lines for fix and nix on the same Bad Apple.
- [ ] **Step 4: Commit** (`nix-badge: log backend tag + RSS in the fps window`).

---

## Phase 4 — On-badge A/B (measurement, not code)

### Task 4.1: Run and record the comparison

- [ ] **Step 1:** Deploy with `nixbadge.oled.backend = "fix"`; on the badge cycle Bad Apple + each info screen; record fps/eval/flush/RSS per screen. Note whether the Gallant/Spleen info screens abort (the fix GC bug).
- [ ] **Step 2:** Redeploy (or `nix-badge oled --backend nix` if the service is stopped) with `backend = "nix"`; record the same. Confirm nix renders the draw-heavy screens fix crashes on.
- [ ] **Step 3:** Same for the LED patterns (`bling --backend fix|nix`).
- [ ] **Step 4:** Write the results table into `docs/superpowers/specs/2026-08-29-nix-c-api-backend-design.md` (append a "Results" section: fps, eval-ms, RSS, and screen-survival per backend) and commit (`docs: record fix vs nix backend A/B results`).

---

## Self-Review

**Spec coverage:** shared `[]i64` seam (T1.1), FixBackend refactor keeping 60fps (T1.2), C++ link + gate (T2.1), NixBackend + selftest (T2.2), runtime selection + options (T3.1), RSS + tagged log (T3.2), on-badge A/B + results (T4.1), riscv gating (Global Constraints + T2.1), Boehm/MemoryMax (Global Constraints), shim fallback (T2.1 Step 4). All spec sections map to a task.

**Placeholder scan:** the one deliberate unknown is the exact `nix-expr-c` static **attr path** (T2.1 Step 1) — the spike used the derivation directly; the task instructs deriving/exposing it and documenting the found attr, which is a real investigation step, not a hand-wave. No other TBDs.

**Type consistency:** `eval.Frame{bitmap:[]const i64,next_ms:i64,delta,n}`, `eval.Dirty{full,changed:[8]u128}`, `eval.OledFrame{next_ms:u32,dirty}`, `Backend.applyFrame(idx,fields)!Frame`, `decodeOledFrame(frame,out,width)Dirty` — used identically across T1.1/T1.2/T2.2/T3.1. `FixBackend`/`NixBackend` expose the same surface (`open`/`applyFrame`/`collect`/`deinit`/`count`/`name`).
