# fix GC bug: "minor mark not closed — missed edge" under per-frame `applyValue`

A minimal, deterministic reproduction of a garbage-collector correctness panic in
[psyclyx/fix](https://github.com/psyclyx/fix), for the maintainer.

## Symptom

Building fix `ReleaseSafe` (so the `gc_debug` detector in `verifyMinorClosure` is
on) and driving the evaluator in a **compile-once, apply-per-frame** loop panics
deterministically after ~20 iterations:

```
GC MISSED EDGE: thunk 149  -> unmarked young attrs 39783
GC MISSED EDGE: closure 173 -> unmarked young attrs 39783
GC MISSED EDGE: thunk 986  -> unmarked young merge_attrs 36592
...
thread N panic: gc: minor mark not closed — missed edge (see MISSED EDGE lines)
```

An *old* (pre-`track_from`) object references a *young* object that the minor
mark never traced — i.e. an old→young edge that never made it into the
remembered set, so the young child is swept from under a live old parent.

## Reproduce

```
./setup.sh                 # main (2b23db57)
./setup.sh v0.3.0          # also reproduces here
```

`setup.sh` clones fix at the rev, applies `native-apply.patch` (adds
`Engine.applyValue` + `Engine.makeAttrs`), and runs `harness/` under `ReleaseSafe`.
The crash is at ~frame 20 (see `/tmp/repro_prog.txt` for progress — written via a
raw syscall so it survives the abort; a fixed evaluator reaches `DONE`).

## What triggers it

The harness (`harness/fixeval.zig`, test `"gc missed-edge repro"`) does exactly
what our embedded use does:

1. `Engine.init(.{ .worker_count = 0 })`, then `configureMemory(256 MB)` (the
   **lazy-arming budget path** — `enableBudget`/`armTracking`, not the eager
   `FIX_GC_STEP_MB` path).
2. `evaluate` a **draw-heavy** lambda **once** — `battery.nix` here: a
   `scope: { bitmap = [128 ints]; nextMs; }` function that folds a bitmap font over
   glyphs, allocating many young `attrs`/`merge_attrs` per call. Pin it with
   `gcSetExternalRoots(&.{lambda})`.
3. Every "frame": build a fresh scope with `makeAttrs`, `applyValue(lambda, scope)`,
   force `bitmap` + every element + `nextMs`, and `collectNow()` on a cadence.

Heavy young allocation crosses the budget threshold mid-eval, a minor collection
runs at the `forceThunk` safepoint, and `verifyMinorClosure` finds the missed edge.

## Key facts (each verified against this repro)

- **Pure `fix eval` does NOT reproduce it.** A from-scratch baseline at 2b23db57,
  and foldl'/genList-heavy expressions under `--workers 0 --gc-budget 64m`, run
  clean. The bug needs the `applyValue`/`makeAttrs`/`gcSetExternalRoots`
  per-frame path (this patch). fix's own test suite never exercises that path.
- **Cross-version.** Identical crash on `main` (2b23db57, Aug 26) and `v0.3.0`
  (2141010, Aug 2). Not a recent regression.
- The missed parents are the *pinned lambda's own* structure (`thunk 149`,
  `closure 173`); the missed children are *this frame's* fresh young values
  (`39783` etc.). The write barrier records nothing for these edges post-arm
  (instrumented: `POST_ARM_calls=0`, `pre_arm=1` — the barrier fired once
  pre-arm, when `collect_enabled=false` makes it a no-op).

## Ruled out (none change the crash by a single frame)

| Attempted fix / lever | Result |
|---|---|
| `hardening-1-seedArmingRemset.patch` — seed the remset at `armTracking` for resolved thunks that predate the boundary | no change |
| `hardening-2-gcObjectFrontier.patch` — size every GC bitmap from `max(count(), TLAB end)` not `objects.count()` | no change (a no-op at these revs) |
| both hardening patches together | no change |
| `FIX_GC_STEP_MB` (eager tracking) | crashes at frame 0 instead |
| `FIX_GC_NOREUSE=1` (disable object-id recycling) | no change; ids identical |
| `worker_count = 1` | no change |
| re-`gcSetExternalRoots` every frame (prune the `extra_roots` that `applyValue`'s `gcRootCrossingValue` accumulates) | no change (real leak fix, but not this bug) |
| pin back to v0.3.0 | reproduces there too |

The two `hardening-*.patch` files are, we believe, **correct upstream hardening**
regardless — an arming-boundary remset seed and a frontier-vs-`count()` bitmap
sizing fix — they just don't address *this* edge. Included in case they're useful.

## The open question

Is this (a) a genuine fix GC bug that only the `applyValue`-per-frame pattern
triggers, or (b) a contract on `applyValue` / `makeAttrs` / `gcSetExternalRoots`
that we're violating (e.g. holding a compiled lambda across collections and
re-applying it needs additional rooting/barrier calls we're missing)? Either way
we couldn't close it from the source alone; the deterministic cross-version repro
is here so you can.

Contact: NixVegas badge project (embedding fix's `expr` evaluator for per-frame
Nix-defined OLED/LED content).
