# reach — an ORM for dacor, in Mettle

Status: **complete for the planned build order** — core+adapter, query,
changeset, relation, migration, and the cross-phase acceptance test are all
implemented and green in the compile-time interpreter, debug and release.
Build and test run through **mbuild** (`mbuild.toml`).

```
$ tools/check.sh
42 passed, 0 failed
```

Open seams (deliberately not started): `core/session`, `core/arena`,
lifecycle hooks + auto-timestamps, identity map / stale-write detection, the
UPDATE emitter fed by the changeset mask, the dacor bridge, the
prepared-statement cache, `RcDiagnostic`, `where_gt`/`where_lt`.

Read in this order:

| File | What |
|---|---|
| `00-index.md` | this map, toolchain, gate, state |
| `01-architecture.md` | the critique: what the proposed tree is missing, pooling, impedance mismatches |
| `02-seams.md` | frozen interfaces: what each phase may rely on from the previous one |
| `03-phase1.md` | Phase-1 implementation guide, value mapping, the five tests and their evidence |
| `04-integration.md` | the cross-phase acceptance test, as built |
| `reports/director.md` | live orchestration state (the director agent owns this file) |

## Layout

```
reach/                    <- mbuild project root (mbuild.toml lives here)
  src/core/               value, status, meta, entity, buf, persist   (Phase 1)
  src/adapter/            adapter (vtable), mem (test double), dacor  (Phase 1)
  src/query/              dialect, fluent builder                     (Phase 2)
  src/changeset/          cast, validate, dirty mask                  (Phase 3)
  src/relation/           associations + batch loaders                (Phase 4)
  src/migration/          ddl, versioned up-migrations                (Phase 5)
  tests/                  models.mettle, harness.mettle + t_*.mettle per phase
                          (including t_integration.mettle, the seam test)
  cmd/reachdemo/          the end-to-end demo bin (`mbuild run`)
  tools/check.sh          the gate (mbuild check/test + debug/release runs)
  docs/  reports/  .pi/agents/
```

## Toolchain: mbuild

```
MB=/home/nox/Projects/mettle/mbuild/build/bootstrap/mbuild
export METTLE=/home/nox/Projects/mettle/raize/mettle-build/bin/mettle
```

`mbuild.toml` deliberately has **no `[toolchain]` pin**. reach needs the head
compiler (compile-time reflection, `Kind`, `comptime for`); pinning `v0.17.0`
selects the release compiler from `~/.mbuild/toolchains/` and the build fails.
mbuild's compiler order puts `METTLE` (host target) above the newest installed
toolchain, so exporting it is the supported way to say "head".

`Mettle/bin/mettle` does not exist. Do not mix the two stdlibs.

Imports are **file-relative**, because the compiler resolves a non-`std`
import against the importing file:

```mettle
// src/core/persist.mettle
import "value";                 // src/core/value.mettle
import "../adapter/adapter";    // src/adapter/adapter.mettle
// tests/t_persist.mettle
import "../src/core/persist";
```

A root-relative `src/core/value` also works (the compiler falls back to the
working directory), but file-relative does not depend on where a tool runs the
compiler from.

## The gate

```
tools/check.sh                          # everything
tools/check.sh tests/t_query.mettle     # one phase
```

which is:

```
mbuild check            # type-check the package (src/ + the demo bin graph)
mbuild test             # every @test in the project, in the interpreter, cached
mbuild mettle -- --build tests/t_X.mettle -o ...   ; run it      (debug)
mbuild mettle -- --release --build tests/t_X.mettle -o ... ; run it
mbuild build [-r]       # the demo bin, then actually run it
```

Every test file defines `check_*` functions, a `main` that runs them (built
binary) and one `@test` that runs the same functions (interpreter). Both are
needed: the interpreter cannot reach every extern, and `--release` is where the
head miscompiles in `tools/repros/` surface. Release is **not** optional.

## House rules (Mettle, hard-won)

- `export` on every declaration a module wants seen, and nothing else. Every
  module here uses explicit exports: a no-export module that imports
  `std/mem` or `std/conv` hides everything (head bug C).
- One flat namespace: `Rc*` types, `rc_` functions, `RC_*` constants.
- Every `var` and local `const` gets a written type.
- `defer free(p)` immediately after the null check; the leak analyser only
  quiets when the free covers every exit.
- 2-space indent, brace on the same line, `} else {`.
- No `?:`, no `null` (write `0`), no ternaries, `switch` does not fall through.
- Integer literals are `int32`: `(int64)1 << 40`, and every unix-micros
  literal needs a cast.
- Never overlay a struct on database bytes. Metadata offsets come from
  `typeof(T).fields`; access is a typed load at that offset.
- `--safe` is not usable with `std/arena`/`std/strbuf` (runtime trap); we do
  not use them.
