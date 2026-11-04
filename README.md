# flux_orm

An ORM for the [MeoSQL](../meosql) database, written in Mettle.

Status: models, queries, inserts, loads, updates of changed fields, deletes,
relations without N+1, up-only migrations, sessions with transactions and
stale-write detection and automatic timestamps all work and are tested in the interpreter, debug and
release. The MeoSQL adapter (`src/adapter/meosql.mettle`) is a stub until
MeoSQL has its network server; the tests run against an in-memory adapter that
records statements.

## Layout

```
src/core/       values, status codes, model metadata, entities, sessions,
                single-row insert/load/delete
src/adapter/    the adapter interface, the in-memory test adapter, MeoSQL
src/query/      SELECT/INSERT/UPDATE builder and SQL dialect
src/changeset/  casting user input, dirty fields, save
src/relation/   has-many / belongs-to / through, loaded in batches
src/migration/  CREATE TABLE from metadata, versioned migrations
tests/          models.mettle (the model template) and one t_*.mettle per area
```

## Models

Mettle reflects at compile time only, so a model's metadata is generated with
`comptime for` over `typeof(T).fields`: field names, offsets and types come
from the compiler, with no hand-written offset table. An override table adds
what a struct cannot say (column names, keys, NOT NULL, a version column,
`RC_F_CREATED`/`RC_F_UPDATED` timestamps).
Copy the shape in `tests/models.mettle`.

```mettle
export struct Note {
  id: int64;
  text: string;
  version: int64;
}

const NOTE_COLS: RcColumn[3] = [
  { index: 0, column: "id", ty: RC_T_I64, flags: RC_F_PK | RC_F_AUTO | RC_F_NOT_NULL },
  { index: 1, column: "text", ty: RC_T_TEXT, flags: RC_F_NOT_NULL },
  { index: 2, column: "version", ty: RC_T_I64, flags: RC_F_VERSION | RC_F_NOT_NULL },
];
```

## Use

```mettle
rc_clock_set(&rc_clock_realtime_us);  // once, if any model has timestamps
var s: RcSession = rc_session_new(adapter);
var a: RcAdapter* = rc_session_adapter(&s);

// Insert: the store assigns the id, the version starts at 1.
var n: Note;
memset((rawptr)&n, 0, (int64)sizeof(Note));
var e: RcEntity = rc_entity_new(note_meta(), (rawptr)&n);
rc_entity_set(&e, 1, RcText("draft"));
rc_persist_insert(a, &e);

// Change one field and save it. Only "text" is sent, keyed by id and version.
var cs: RcChangeset = rc_changeset_new(note_meta());
rc_changeset_bind(&cs, (rawptr)&n, e.nulls);
rc_changeset_put_text(&cs, 1, "final");
var rc: int32 = rc_changeset_save(a, &cs, &e);
// RC_ERR_CONFLICT: someone else changed the row first; nothing was written.
rc_changeset_free(&cs);

// Query.
var q: RcQuery = rc_query_select(note_meta());
rc_query_where_cmp(&q, 2, RC_CMP_GT, RcInt(1));
rc_query_order_by(&q, 0, true);
var res: RcResult;
rc_query_exec(&q, a, &res);
rc_result_free(&res);
rc_query_free(&q);
```

Every call returns an `RC_*` code (`src/core/status.mettle`). Wrap related
writes in `rc_session_begin`/`rc_session_commit`, or `rc_session_transaction`.

## Build and test

flux_orm needs the head Mettle compiler. `mbuild.toml` has no toolchain pin,
so select it with `METTLE`.

```
MB=/home/nox/Projects/mettle/mbuild/build/bootstrap/mbuild
export METTLE=/home/nox/Projects/mettle/Mettle/bin/mettle
$MB check             # type-check every test program and what it imports
$MB test              # every @test, in the interpreter
$MB build && $MB build -r
for t in build/linux/{debug,release}/t_*; do $t || echo "FAIL $t"; done
```

`$MB run t_query` builds and runs one test. Run release as well as debug:
compiler bugs have shown up in release only. Imports are file-relative, so the
compiler can be run from anywhere.
