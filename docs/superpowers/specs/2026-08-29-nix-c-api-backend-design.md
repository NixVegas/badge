# Design: a second per-frame evaluator backend (upstream Nix C API) alongside fix

- Date: 2026-08-29
- Status: design, pending implementation-plan
- Repo: badgeos (nix-badge)

## Goal

Add a second per-frame Nix evaluator backend to `nix-badge` that uses the **upstream
Nix C API** (`libnixexpr` via `nix_api_*`), selectable at runtime, so we can compare
fix vs upstream Nix head-to-head on the badge for **both** the OLED screens and the LED
patterns. Metrics: sustained **fps**, **per-frame eval time**, and **RSS**.

Two motivations:
1. **Comparison** — is fix's lean Zig evaluator actually faster / lighter than upstream
   Nix on this workload, or not?
2. **Workaround** — fix has a GC "minor mark not closed — missed edge" bug (see
   `fix-gc-repro/`) that aborts on draw-heavy screens (the Gallant/Spleen info screens).
   Upstream Nix does not have that bug, so the nix backend is also a candidate fallback
   for those screens while the fix bug is open.

## Feasibility (already proven — spike 2026-08-29)

- Static-musl aarch64 upstream Nix **links** (C++23 + boost + boehm-gc + nix{util,store,
  expr} + openssl/sqlite/curl), producing a **33 MB** binary for an eval-a-lambda test.
- The **compile-once / apply-per-frame** pattern **runs** (binfmt-verified): eval a lambda
  with `nix_expr_eval_from_string`, then per frame build a `BindingsBuilder` scope →
  `nix_value_call` → `nix_value_force` → `nix_get_list_byidx`/`nix_get_int`. A `dummy://`
  store means no real Nix store is needed for pure eval.
- The C API is a **separable component** (`nix-expr-c` + `nix-store-c` + `nix-util-c`), so
  we skip `nix-cmd`/`nix-flake`/`nix-main`/editline/lowdown/manual.
- `pkg-config --static` omits 4 transitive `-L`s (acl, bz2, unistring, llhttp); adding all
  aarch64-musl static lib dirs from the build closure resolves the link.

## Non-goals

- Replacing fix. This adds a *second* backend for comparison; the winner is decided later.
- riscv support for the nix backend in this iteration (see Risks). fix stays the riscv path.
- Any change to the content contract (`scope: { bitmap; nextMs; delta?; n? }`) — both
  backends evaluate the *same* pure-Nix screens/patterns.
- Fixing the fix GC bug (tracked separately in `fix-gc-repro/`).

## Architecture

Only the **eval** differs between backends. **Decode, flush, pacing, `Fields`, `Dirty`**
are shared, so the A/B measures the evaluator and not the harness. The seam moves from
"backend hands back fix `Value`s" to "backend hands back a plain `[]const i64` bitmap".

```
                       ┌───────────────── eval.zig (backend-agnostic) ─────────────────┐
render loop (nix-badge.zig)                                                            │
  Fields ──► Backend.applyFrame(fields) ──► Frame { bitmap:[]const i64, next_ms,       │
                    │                                delta, n }                        │
                    │                          │                                       │
        ┌───────────┴───────────┐              ▼                                       │
        ▼                       ▼        decodeOled / decodeOledDelta / decodeLeds ──► out
   fixeval.FixBackend    nixeval.NixBackend      (shared; operate on []i64)            │
   (compile lambdas,     (nix_expr_eval...,                                            │
    applyValue,           nix_value_call,     flushDirty (shared) ──► panel            │
    extract ints→[]i64)   get_list→[]i64)                                              │
                                                                                       │
                       └───────────────────────────────────────────────────────────────┘
```

### Modules

- **`eval.zig` (new)** — the backend-agnostic core:
  - `Fields` (moved from fixeval), `Dirty`, `OledFrame` (moved from fixeval).
  - `Frame { bitmap: []const i64, next_ms: i64, delta: bool, n: u32 }` — **no fix `Value`**.
  - Shared `decodeLeds(ints, brightness, out)`, `decodeOled(ints, out, width) Dirty`,
    `decodeOledDelta(ints, n, out, width) Dirty` — operate on `[]const i64`.
  - `Backend = union(enum) { fix: fixeval.FixBackend, nix: nixeval.NixBackend }` with
    `open`, `applyFrame(fields) !Frame`, `applyFrameOled(idx, fields) !Frame`, `collect`,
    `deinit`, plus per-screen playback state where relevant.
  - `Pattern` (LED, one lambda) and `ScreenSet` (OLED, N lambdas) hold a `Backend` and the
    shared decode + pacing (frameIndex, keyframe-snap, collect cadence, timing counters).

- **`fixeval.zig`** — slimmed to `FixBackend`:
  - `open(paths)` compiles each source to a lambda once, pins via `gcSetExternalRoots`.
  - `applyFrame`: `makeAttrs` scope (incl. `frameIndex`), `applyValue`, read `delta`/`n`,
    **force + extract the bitmap list into a caller-provided `[]i64` buffer** (this is the
    change: decode no longer forces `Value`s; the backend produces `[]i64`).
  - `collect` = `collectNow` on cadence (with the collect-timing accumulator).

- **`nixeval.zig` (new)** — `NixBackend` via `@cImport({ nix_api_util.h; nix_api_store.h;
  nix_api_expr.h; nix_api_value.h; })`:
  - `open`: `nix_libexpr_init`, `nix_store_open("dummy://")`, `nix_state_create`, then
    `nix_expr_eval_from_string(src)` per screen/pattern → a pinned `nix_value*` lambda
    (incref to keep across frames).
  - `applyFrame`: build scope with `nix_make_bindings_builder` + `nix_init_int`/`_bool`/
    `_float` + `nix_bindings_builder_insert` + `nix_make_attrs`; `nix_value_call(lambda,
    scope)`; `nix_value_force`; read `bitmap` via `nix_get_attr_byname` +
    `nix_get_list_byidx`/`nix_get_int` into the same `[]i64`; read `nextMs`/`delta`/`n`.
  - GC: Boehm is automatic; `nix_gc_decref` per-frame temporaries, or rely on Boehm. No
    explicit `collect` (Boehm runs on alloc pressure); expose a no-op `collect` and let
    `nix_gc_now()` be an option for a fair "force a collect" comparison.
  - Only compiled when `have_nix` (build option); a stub struct otherwise so the module
    type-checks on the fix-only / riscv build (same pattern as `have_fix`).

### Backend selection (runtime)

- `nixbadge.oled.backend` and `nixbadge.bling.backend` options: `"fix"` (default) | `"nix"`.
- `nix-badge oled --backend nix|fix` and `nix-badge bling --backend nix|fix` CLI flags
  override. The service passes the option through.
- The loop constructs the `Backend` union variant from the flag at startup; everything
  downstream (Pattern/ScreenSet/decode/flush/pacing) is backend-agnostic.
- If `--backend nix` is requested but `have_nix` is false (fix-only build / riscv), log
  once and fall back to fix.

## Data flow (per frame, unchanged shape)

1. `oledGather` on the 500 ms tick → `Fields` (now_ms fresh per frame).
2. `Backend.applyFrameOled(idx, fields)` → `Frame { bitmap:[]i64, next_ms, delta, n }`.
   - fix: makeAttrs + applyValue + force→[]i64.
   - nix: BindingsBuilder + nix_value_call + get_list→[]i64.
3. Shared `decodeOled`/`decodeOledDelta(frame.bitmap, ...)` → persistent framebuffer + `Dirty`.
4. Shared `flushDirty` → panel (run-coalesced partial flush).
5. Shared pacing (`oledWait(now_ms + next_ms)`), timing/RSS logged on the 3 s window.

The `[]i64` buffer is reused across frames (one alloc at `open`). Its length is the max
bitmap-list length the content can emit: for OLED, `fbLen` i64s is a safe upper bound (a
keyframe is `fbLen/4` ints, a delta is `ceil(n/2) <= fbLen/2` ints, both `<= fbLen`); for
LEDs, the pixel count. Sized once at `open` from the panel/ring geometry.

## The C++ link (the real integration work)

nix-badge is built by Zig; the Nix libs are C++/libstdc++. The C API boundary returns
`nix_err` (exception-safe), so Zig never sees C++ exceptions — but the **link** must pull
libstdc++ + the transitive static `.a`s.

**Chosen: direct Zig link (option a).** `pkgs/badge/nix-badge.nix` gains a `nixEval` path
(gated, like `fixSrc`):
- Adds the `nix-expr-c` static package (out + dev) for the target; `@cImport` uses the dev
  headers (`-I` the three `nix_api_*` include dirs).
- Feeds Zig the **full set of aarch64-musl static lib dirs** from the `nix-expr-c` build
  closure (as `nix-store -q --requisites --include-outputs` filtered to `*-static-*/lib`),
  plus `-lstdc++`, wrapped so the circular nix libs resolve (link group / repeated libs).
- Passed to `build.zig` via a build option (e.g. `-Dnix-libdirs=...` + `-Dnix-include=...`),
  which `linkSystemLibrary`/`addLibraryPath`/`addObjectFile`s them onto the exe.

**Fallback: a C++ shim TU (option b).** If Zig's LLD + gcc-built libstdc++ ABI mixing
misbehaves, compile a small `nixeval_shim.cpp` with the nix cross-`g++` exposing our eval
glue as plain C (`nb_nix_open`, `nb_nix_apply`, ...), and link that `.o` + libstdc++ into
nix-badge. Isolates the C++ toolchain to one TU. Only adopt if (a) fails.

**Gating:** `nixEval` defaults to enabled on aarch64 (where the badge runs the evaluator),
null elsewhere; when null, `have_nix=false` and the build is byte-for-byte the current one.
Both `fixSrc` and `nixEval` can be on together (the fat comparison binary).

## Comparison harness

Reuse the existing loop instrumentation (`oled: N fps eval~ (collect~) flush~` every 3 s):
- Tag the backend: `oled: 60 fps [nix] eval~1ms (collect~0ms) flush~2ms rss~NNMB`.
- Add **RSS**: read `/proc/self/statm` (resident pages × page size) on the same 3 s tick.
- Same for the LED loop (`bling`), tagged `[fix]`/`[nix]`.
- To compare: same Bad Apple + info screens, flip `--backend`, read the journal. The
  interesting cells: fps + eval-ms + RSS per backend, and **whether nix survives the
  draw-heavy Gallant/Spleen screens fix aborts on**.

## Error handling

- nix backend: every `nix_*` call checks `nix_err`; a fault at `open` (compile) skips that
  screen (logged once), matching fix's per-screen skip. A fault mid-run drops the screen /
  falls back, same as fix's `renderOled` error path.
- Boehm GC reserves a large virtual heap; the service already runs under `MemoryMax`
  (per `fix-repro-memory-caps` lessons). RSS — not virtual — is the compared number.
- If `--backend nix` on a build without `have_nix`: warn once, use fix.

## Testing

- **Host `zig test`** for the shared decode on `[]const i64`: `decodeOled` full-frame,
  `decodeOledDelta` (2-entries/int unpack + run bitmap), `decodeLeds` — backend-independent,
  no evaluator needed. This is the highest-value unit test (the seam we're introducing).
- **A tiny `nix-badge fix-selftest`-style `nix-selftest`** that evals a trivial lambda via
  the nix backend and checks the result (smoke test the link + API at runtime).
- **On-badge integration**: the fps/eval/RSS harness IS the test — both backends drive the
  real screens; success = both render correctly + we get comparable numbers, and nix
  renders the screens fix crashes on.

## Risks / open questions

- **RSS unknown** — the headline comparison metric; Boehm GC could make nix heavier than
  fix's ~72–81 MB, or not. Measured, not predicted.
- **Binary size** — +~33 MB for the fat (both-backends) binary. Trivial on the SD; noted.
- **LLD + libstdc++ ABI** — the direct-link risk; shim fallback covers it.
- **riscv** — the nix C++ static build for riscv-musl is unverified; nix backend gated to
  aarch64 this round, riscv stays fix. riscv nix feasibility is a follow-up spike.
- **`dummy://` store limits** — pure eval only (no `import`, no fetch). Our screens are
  self-contained, so this is fine; it matches fix's fetch-less constraint.

## Rollout (phasing for the implementation plan)

1. Extract the shared seam: `eval.zig` with `Frame{[]i64}` + shared decode; refactor
   `fixeval.zig` to `FixBackend` producing `[]i64`; keep fix working (deploy + verify 60fps
   unchanged). No nix yet.
2. `nixeval.zig` + the `nix-badge.nix` C++ link (direct); `have_nix` gate; `nix-selftest`.
3. Wire the `--backend`/option selection through oled + bling; the RSS + backend-tagged log.
4. On-badge A/B: fps/eval/RSS for fix vs nix on Bad Apple + info screens; record results.
