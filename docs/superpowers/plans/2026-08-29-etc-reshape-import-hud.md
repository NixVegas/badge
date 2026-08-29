# /etc/nixbadge Reshape + fix import + backend HUD — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** Give the fix evaluator local `import`/`readFile`, move badge content into a drop-in `/etc/nixbadge/{oled.d,bling.d,lib}` layout the runtime scans, and use a shared importable `lib/font.nix` to draw a `[backend] fps` HUD over Bad Apple (finishing Phase-3 Task 3.1d).

**Architecture:** fix already implements `import`/`readFile` through a `FileCache` gated on a null `std.Io`; passing the `std.Io` that `main` already holds into `Engine.init(.{ .io = … })` enables local reads while the vendored fetch-less `stub_root.zig` keeps network fetchers erroring. The upstream Nix backend does `import` natively. Content therefore uses ABSOLUTE imports of `/etc/nixbadge/lib/*.nix` (the runtime hands the evaluator source text, not a path, so there is no relative base). The oled/bling daemons take `--eval-dir DIR` and scan `*.nix` sorted by filename (numeric prefix = cycle order); a NixOS module writes the dir via `environment.etc`.

**Tech Stack:** Zig 0.16 (nix-badge), psyclyx/fix `expr` (`Engine.Config.io: ?std.Io`), the upstream Nix C API, NixOS `environment.etc`, pure-Nix content.

**Spec:** design captured inline here + the Phase-3 spec `docs/superpowers/specs/2026-08-29-nix-c-api-backend-design.md` (overlay contract).

## Global Constraints

- **fix IO = local reads ONLY.** Passing `.io` also hands the fetchers + store-realization an io, but `stub_root.zig` still returns `error.FetchUnsupported`, so `fetchurl`/`fetchGit`/IFD stay disabled. Only `import`/`readFile` of on-disk paths become live. No network in the closure.
- **Import base:** the runtime currently does `readFile` + `evaluate(text)`, which gives imports NO relative base — so content would need absolute imports (`import /etc/nixbadge/lib/font.nix`). BETTER (decide in B.2): have the backends evaluate **`import <abspath>`** of the screen instead, so each evaluator reads the file itself and relative imports inside resolve against the file's dir (`import ../lib/font.nix`) — natural content, no rewrite, works on both fix (FileCache) and nix (native, `path` arg). Absolute imports remain the fallback if the `import <abspath>` switch is deferred.
- **riscv unaffected:** eval is not built into the riscv core (it runs computed Zig screens), so import support is aarch64-only in effect; the module/tool changes must stay no-ops there.
- **Both backends must resolve the same imports** — the fix path via `Engine.Config.io`, the nix path natively (default `nix_state`, no `restrict-eval`).
- **Don't regress 60fps Bad Apple or the fix/nix A/B** shipped in `5dd3230`.
- Commits: `--no-gpg-sign`, trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Heavy nix builds under `systemd-run --user --scope -p MemoryMax=12G`, one at a time. Flakes only see git-tracked files — `git add` new files before building.

---

## Phase A — fix local file-IO (`import`/`readFile`)

### Task A.1: thread `std.Io` into the fix Engine

**Files:** `pkgs/badge/nix-badge/fixeval.zig`, `pkgs/badge/nix-badge/backend.zig`, `pkgs/badge/nix-badge/nix-badge.zig`.

**Interfaces:**
- `fixeval.FixBackend.open(gpa, io: std.Io, paths) ?FixBackend` — passes `.io = io` to `Engine.init`.
- `backend.Backend.open(gpa, io, which, paths)`, `backend.ScreenSet.open(gpa, io, which, paths)`, `backend.Pattern.open(gpa, io, which, path)` — thread `io` through (nix ignores it).
- `nixeval.NixBackend.open(gpa, io, paths)` — accepts + ignores `io` (uniform signature).

- [ ] **Step 1:** `FixBackend.open` takes `io: std.Io`, passes `.io = io` in `Engine.init` config. `selftest` + tests build an `std.Io` (host: `std.testing` provides one, or `std.Io.Threaded`).
- [ ] **Step 2:** Give `nixeval.NixBackend.open` a matching `io: std.Io` param (ignored) so the union dispatch is uniform.
- [ ] **Step 3:** `backend.Backend/ScreenSet/Pattern.open` thread `io`.
- [ ] **Step 4:** `nix-badge.zig` `main` passes `init.io` into `cmdOled`/`cmdBling`; those pass it to the holders. `fixeval.selftest`/`fix-selftest` gets an io so it still runs.
- [ ] **Step 5 (host test):** a `FixBackend` test writes `/tmp/nbio-lib.nix` = `{ x = 7; }` and a screen `scope: { bitmap = [ (import /tmp/nbio-lib.nix).x ]; nextMs = 10; }`, opens with a real io, asserts `bitmap[0] == 7`. Proves runtime import works (previously `FileIoUnavailable`).
- [ ] **Step 6:** `zig build test` (host) green; build the arm toplevel; `fix-selftest` + `nix-selftest` still OK on the built binary.
- [ ] **Step 7: Commit** (`nix-badge: enable fix local import/readFile via Engine .io (network still stubbed)`).

---

## Phase B — `/etc/nixbadge` reshape + `--eval-dir`

### Task B.1: `--eval-dir DIR` runtime scan

**Files:** `pkgs/badge/nix-badge/nix-badge.zig` (+ maybe a small dir-list in `linux.zig`).

**Interfaces:** `nix-badge oled --eval-dir DIR` and `nix-badge bling run --eval-dir DIR` scan `DIR/*.nix`, sort ascending by filename, and use that as the screen/pattern list (equivalent to N `--eval-screen`). Filename numeric prefix = cycle order. `--eval-screen` stays supported (explicit paths win / append).

- [ ] **Step 1:** add a bounded directory lister to `linux.zig` (`listDir(path, buf) []entry` or reuse std) that returns the `*.nix` basenames.
- [ ] **Step 2:** in `cmdOled`/`cmdBlingRun`, on `--eval-dir`, read + sort the `.nix` entries and append their full paths to the eval path list (cap `max_eval_screens`). Log the discovered order.
- [ ] **Step 3 (host test):** `listDir` returns sorted `*.nix` only (ignores other files), factored parse tested on a temp dir.
- [ ] **Step 4:** build; commit (`nix-badge: --eval-dir scans a content dir for *.nix screens (sorted)`).

### Task B.2: write `/etc/nixbadge` + point the services at it; retire inlining

**Files:** `modules/duo-s/oled.nix`, `modules/duo-s/bling.nix`, `modules/duo-s/common.nix`, `pkgs/badge/bling-content/*` (screens no longer inlined), `flake.nix` (package outputs).

- [ ] **Step 1:** a content package assembles `oled.d/NN-*.nix`, `bling.d/NN-*.nix`, `lib/*.nix` (plain screens with real `import /etc/nixbadge/lib/...`; NOT inlined). `environment.etc."nixbadge/…"` (or `systemd.tmpfiles`) installs them at `/etc/nixbadge/`.
- [ ] **Step 2:** `oled.nix`/`bling.nix` ExecStart uses `--eval-dir /etc/nixbadge/oled.d` (resp. `bling.d`); keep the `evalScreens`/`evalPattern` escape hatch.
- [ ] **Step 3:** update `screens-install.nix` (or replace it) to emit plain screens importing `/etc/nixbadge/lib/draw.nix` + font, with the self-test now doing an import-based eval (stock nix, reads the installed lib) instead of the no-imports-remain check.
- [ ] **Step 4:** build + `nix eval` self-tests green; commit (`badge: /etc/nixbadge dir-based content + lib; drop screen inlining`).

---

## Phase C — shared `lib/font.nix` + the backend/fps HUD

### Task C.1: `lib/font.nix`

**Files:** `pkgs/badge/bling-content/lib/font.nix` (new; reuse `screens/spleen-5x8-font-data.nix`).

**Interfaces:** `font = { glyph = ch: [rows]; renderText = { text, x, y, width } : [ packedOverlayEntries ]; }` producing `E = offset*256+byte` entries (page-major, 2/int packing is done by the caller or a `pack` helper) for the runtime `overlay` field.

- [ ] **Step 1:** author `lib/font.nix` (5×8 glyphs for `0-9`, `[`, `]`, `f`, `i`, `x`, `n`, `p`urpose letters; `renderText` → overlay `(offset,byte)` entries at a corner). Pure; testable via `nix eval`.
- [ ] **Step 2 (build test):** `nix eval` renders `"[nix] 60fps"` → a non-empty entry list within the panel bounds.
- [ ] **Step 3:** commit (`badge: lib/font.nix — importable 5x8 font -> overlay entries`).

### Task C.2: Bad Apple HUD

**Files:** `pkgs/badge/bling-content/badapple-live.nix` (+ `emit_delta.c` emits the tail that imports the font and appends `overlay`/`overlayN`).

- [ ] **Step 1:** the emitted `badapple-live.nix` ends with `overlay = font.renderText { text = hud scope.backend scope.fps; … }; overlayN = …;` where `hud` maps `scope.backend` (0/1) → `"fix"/"nix"` and formats `fps`.
- [ ] **Step 2:** build; deploy; camera-verify `[fix] Nfps` renders in the corner over clean Bad Apple, updates each ~3 s, and a >5 s hold flips it to `[nix] …`.
- [ ] **Step 3:** commit (`badge: Bad Apple backend/fps HUD via lib/font overlay (Task 3.1d)`).

---

## Self-Review

- **fix IO** (A.1) enables `import`/`readFile` with the network still stubbed (Global Constraints).
- **Absolute imports** are forced by the source-text eval path; both backends resolve them (fix via `.io`, nix native).
- **Dir-scan** (B.1) gives drop-in `oled.d`/`bling.d`; explicit `--eval-screen` retained.
- **Reshape** (B.2) retires the inlining hack that only existed because fix lacked IO.
- **HUD** (C) uses the overlay contract already shipped in `5dd3230`; no further runtime contract work.
- riscv stays computed-screens (eval not built in); the module changes are no-ops there.
