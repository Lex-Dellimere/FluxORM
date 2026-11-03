# flux_orm

An ORM for the [MeoSQL](../meosql) database (formerly dacor), written in Mettle.

Status: core+adapter, query, changeset, relation, migration, and the
cross-phase acceptance test (`tests/t_integration.mettle`) are implemented and
green in the interpreter, debug and release. The MeoSQL bridge
(`src/adapter/meosql.mettle`) is a stub until MeoSQL exposes a statement/row
API; tests run against the in-memory recording adapter.

```
  src/core/       value status meta entity buf persist   Phase 1
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
$MB check && $MB test
```

`mbuild test` runs every `@test` in the interpreter. Each test file also has a
`main`; build and run it in debug **and** release (head miscompiles have shown
up in release only):

```
$METTLE --build tests/t_query.mettle -o /tmp/t_query && /tmp/t_query
$METTLE --release --build tests/t_query.mettle -o /tmp/t_query.r && /tmp/t_query.r
```

Imports are file-relative (`import "../core/value";`), so the compiler can be
run from anywhere.
