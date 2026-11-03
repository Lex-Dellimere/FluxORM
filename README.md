# reach

An ORM for the dacor storage engine, written in Mettle.

Status: **the planned build order is complete and green** — core+adapter,
query, changeset, relation, migration, and the cross-phase acceptance test
(`tests/t_integration.mettle`). `tools/check.sh` → 42 passed, 0 failed.
Open seams are listed in `docs/00-index.md`.

```
cd /home/nox/Projects/mettle/reach
export METTLE=/home/nox/Projects/mettle/raize/mettle-build/bin/mettle  # head
MB=/home/nox/Projects/mettle/mbuild/build/bootstrap/mbuild
tools/check.sh        # mbuild check + test, then debug/release builds and runs
$MB run               # the demo: insert + load through the recording adapter
```

```
  src/core/       value status meta entity buf persist   Phase 1
  src/adapter/    adapter mem dacor                      Phase 1
  src/query/      dialect builder                        Phase 2
  src/changeset/  cast changeset                         Phase 3
  src/relation/   relations + batch loaders              Phase 4
  src/migration/  ddl version                            Phase 5
  cmd/reachdemo/  end-to-end demo bin
```

- Architecture critique and the impedance mismatches: `docs/01-architecture.md`
- Frozen seams between phases: `docs/02-seams.md`
- Phase-1 implementation guide + the five tests: `docs/03-phase1.md`
- Cross-phase acceptance, as built: `docs/04-integration.md`
- Orchestration state: `reports/director.md`

## The one design decision worth knowing

Mettle reflects at compile time only. `typeof(T).fields` gives each field's
name, offset and type kind while compiling and leaves nothing behind, so model
metadata is *generated* (`comptime for`) into a static table and field access
is a typed load at the compiler-reported offset. No macros, no build step, no
hand-maintained offset table, and no struct overlays.

## Toolchain

mbuild project. `mbuild.toml` has no `[toolchain]` pin on purpose: reach needs
the head compiler, selected with `METTLE` (or `mbuild --mettle`).

```
MB=/home/nox/Projects/mettle/mbuild/build/bootstrap/mbuild
export METTLE=/home/nox/Projects/mettle/raize/mettle-build/bin/mettle
$MB check && $MB test && $MB build -r && build/linux/release/reachdemo
```

Imports are file-relative (`import "../core/value";`), so the compiler can be
run from anywhere.
