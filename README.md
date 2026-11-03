# flux_orm

An ORM for the [MeoSQL](../meosql) database (formerly dacor), written in Mettle.

Status: core+adapter, query, changeset, relation, migration, and the
cross-phase acceptance test (`tests/t_integration.mettle`) are implemented and
green in the interpreter, debug and release. The MeoSQL bridge
(`src/adapter/meosql.mettle`) is a stub until MeoSQL exposes a statement/row
API; tests run against the in-memory recording adapter.

```
  src/core/       value status meta entity buf persist   Phase 1
                  session (connection + flat transaction)
  src/adapter/    adapter mem meosql                     Phase 1
  src/query/      dialect builder                        Phase 2
  src/changeset/  cast changeset                         Phase 3
  src/relation/   relations + batch loaders              Phase 4
  src/migration/  ddl version                            Phase 5
  tests/          models.mettle (the model template) + t_*.mettle per phase
```

## The one design decision worth knowing

Mettle reflects at compile time only. `typeof(T).fields` gives each field's
name, offset and type kind while compiling and leaves nothing behind, so model
metadata is *generated* (`comptime for`) into a static table and field access
is a typed load at the compiler-reported offset. No macros, no build step, no
hand-maintained offset table, and no struct overlays.

## Toolchain

mbuild project. `mbuild.toml` has no `[toolchain]` pin on purpose: flux_orm
needs the head compiler, selected with `METTLE` (or `mbuild --mettle`).

```
MB=/home/nox/Projects/mettle/mbuild/build/bootstrap/mbuild
export METTLE=/home/nox/Projects/mettle/Mettle/bin/mettle
$MB check             # type-check every test program and what it imports
$MB test              # every @test, in the interpreter
$MB build && $MB build -r
for t in build/linux/{debug,release}/t_*; do $t || echo "FAIL $t"; done
```

Each `tests/t_*.mettle` is declared as a bin in `mbuild.toml`, so
`$MB run t_query` builds and runs one. Run release as well as debug: head
miscompiles have shown up in release only.

Imports are file-relative (`import "../core/value";`), so the compiler can be
run from anywhere.
