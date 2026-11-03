# Phase 4 — `relation/` (has-many, belongs-to, many-to-many) — report

Status: **delivered, green in the mbuild gate** (interpreter via `mbuild test`,
debug build + run, release build + run, demo debug + release).

```
tools/check.sh tests/t_relation.mettle  ->  10 passed, 0 failed
tools/check.sh                          ->  38 passed, 0 failed
tools/check.sh tests/t_value.mettle tests/t_meta.mettle tests/t_adapter.mettle \
               tests/t_persist.mettle tests/t_relation.mettle
                                        ->  26 passed, 0 failed
```

Exec-count summary, which is the point of the phase: **1 / 1 / 2 / 0**
(has-many / belongs-to / through / empty owner set), measured with the
adapter's own `rc_mem_call_count` and cross-checked against `out->n_execs`.

---

## 1. Files

| file | lines | what it is |
|---|---|---|
| `src/relation/relation.mettle` | 164 | `RcRelation` metadata, the three kinds, the two constructors, and `rc_relation_check` — every declaration bug refused at startup, no statement emitted. |
| `src/relation/load.mettle` | 560 | `RcRelationResult` and the batch loader: one `WHERE fk IN (?, …)` statement per relation (two for through), in-memory grouping, hydration that borrows the result. |
| `tests/t_relation.mettle` | 814 | Seven `check_*` functions, `main` via `rc_report`/`rc_summary`, one `@test`. Owns `UserPost` (the 2-field mapping model) locally; `tests/models.mettle` is untouched. |

Nothing outside these three files was edited. No new columns on `User`/`Post`:
`user_id`, `id` are int64 fields the models already had.

---

## 2. Exported seam, symbol by symbol

### `src/relation/relation.mettle`

```mettle
export const RC_REL_HAS_MANY: int32 = 0;
export const RC_REL_BELONGS_TO: int32 = 1;
export const RC_REL_HAS_MANY_THROUGH: int32 = 2;

export struct RcRelation {
  name: string;
  kind: int32;
  local_field: int32;
  foreign_table: string;
  foreign_field: int32;
  through_table: string;
  through_local: string;
  through_foreign: string;
}

export fn rc_relation(name: string, kind: int32, local_field: int32,
                      foreign_table: string, foreign_field: int32) -> RcRelation

export fn rc_relation_through(name: string, local_field: int32,
                              foreign_table: string, foreign_field: int32,
                              through_table: string, through_local: string,
                              through_foreign: string) -> RcRelation

export fn rc_relation_check(rel: RcRelation*, owner_meta: RcMeta,
                            target_meta: RcMeta, through_meta: RcMeta*) -> int32
```

`rc_relation_check` refusals (each one has a test in
`tests/t_relation.mettle::check_startup`, the failure codes are asserted with
`==`):

| refusal | code |
|---|---|
| `rel == 0` | `RC_ERR_USAGE` |
| unknown `kind` | `RC_ERR_UNSUPPORTED` |
| empty `name` | `RC_ERR_USAGE` |
| `local_field` outside `[0, owner_meta.n_fields)` | `RC_ERR_USAGE` |
| owner field is not `RC_T_I64` | `RC_ERR_CAST` |
| `foreign_table != target_meta.table` | `RC_ERR_USAGE` |
| `foreign_field` outside `[0, target_meta.n_fields)` | `RC_ERR_USAGE` |
| target field is not `RC_T_I64` | `RC_ERR_CAST` |
| HAS_MANY: local (grouping) field is not `RC_F_NOT_NULL` | `RC_ERR_USAGE` |
| BELONGS_TO / THROUGH: `foreign_field != target_meta.pk` (or no PK) | `RC_ERR_USAGE` |
| THROUGH: `through_meta == 0`, `n_fields != 2`, `table != through_table`, field 0 name `!= through_local`, field 1 name `!= through_foreign`, either field not `RC_T_I64`, or an empty through name | `RC_ERR_USAGE` |
| any `through_*` name set on a non-THROUGH relation | `RC_ERR_USAGE` |

The mapping-table contract is **positional**: field 0 is the owner column,
field 1 the target column. That is what lets the loader project
`SELECT "user_id", "post_id"` without a column list, and what turns a swapped
mapping table into a startup refusal instead of an inverted relation. The
`HAS_MANY` NOT NULL rule is the task brief's "local side NOT NULL where
required": a NULL grouping key is not a key. `BELONGS_TO`/`THROUGH` allow a
nullable local field on purpose — a NULL foreign key means "no relation" and
the loader skips NULL owner keys before building the IN list.

### `src/relation/load.mettle`

```mettle
export struct RcRelationResult {
  kind: int32;
  keys: int64*;        // deduped owner keys, first-seen order
  n_keys: int32;
  res: RcResult;       // ALL target rows, one statement
  idx: int32*;         // row indices into res, grouped
  off: int32*;         // n_keys + 1 prefix offsets; group g = idx[off[g]..off[g+1])
  n_execs: int32;      // 1 for HAS_MANY/BELONGS_TO, 2 for THROUGH, 0 for empty keys
  through: RcResult;   // THROUGH only: the mapping rows
  meta: RcMeta;        // target metadata (see “deviation” below)
}

export fn rc_relation_load(a: RcAdapter*, rel: RcRelation*, owner_meta: RcMeta,
                           target_meta: RcMeta, through_meta: RcMeta*,
                           keys: RcValue*, n_keys: int32,
                           out: RcRelationResult*) -> int32

export fn rc_relation_group(out: RcRelationResult*, key: int64) -> int32
export fn rc_relation_count(out: RcRelationResult*, group: int32) -> int32
export fn rc_relation_hydrate(out: RcRelationResult*, group: int32, i: int32,
                              model: rawptr, nulls: uint64*) -> int32
export fn rc_relation_free(out: RcRelationResult*)
```

One field beyond the directive's list: `meta: RcMeta`. `rc_relation_hydrate`'s
signature (fixed by the contract) carries no meta, so the result must carry the
target metadata or hydration is impossible without a session/identity map —
which this phase must not have. It is metadata only; there is no cache and no
owner pointer. Everything else is exactly the required shape.

---

## 3. Exact statements, and where they are asserted

Every statement comes out of `src/query` (`rc_query_select` +
`rc_query_where_in` + `rc_query_exec`), including the through projection. No
`rc_buf` text is built in `relation/`.

### HAS_MANY — owner `User`, target `Post`

```sql
SELECT "id", "user_id", "title", "body", "published_at" FROM "posts" WHERE "user_id" IN (?, ?, ?)
```

`tests/t_relation.mettle:87` (`POSTS_BY_USER_SQL3`), asserted at `:327`
against `rc_mem_last_sql(a)` for three owners `[7, 9, 11]`, plus
`rc_mem_arg_count(a) == 3` and the three bound values `7, 9, 11`.

### BELONGS_TO — owner `Post`, target `User`

```sql
SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" WHERE "id" IN (?, ?, ?)
```

`:89` (`USERS_BY_PK_SQL3`), asserted at `:445` through `run_sql_is()` for the
three-distinct-key load `[7, 9, 11]`. The dedupe case `[7, 9, 7]` asserts the
two-placeholder form at `:416`:

```sql
SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" WHERE "id" IN (?, ?)
```

`:90` (`USERS_BY_PK_SQL2`), with `rc_mem_arg_count(a) == 2` and both bound
values checked. Both forms are `==`; there is no substring assertion anywhere
in the file.

### HAS_MANY_THROUGH — owner `User`, target `Post`, mapping `user_posts`

Statement 1 (the mapping table; also the projection order the through meta
pins):

```sql
SELECT "user_id", "post_id" FROM "user_posts" WHERE "user_id" IN (?, ?, ?)
```

`:91` (`THROUGH_BY_OWNER_SQL3`), asserted at `:483` against
`rc_mem_last_sql(a1)` in the "empty mapping" sub-case — with no mapping rows
there is no second statement, so the adapter's recorded statement is the
mapping one and can be read back exactly. Arg count 3, values `7, 9, 11`
(`:484-489`).

Statement 2 (the target rows, deduped target keys):

```sql
SELECT "id", "user_id", "title", "body", "published_at" FROM "posts" WHERE "id" IN (?, ?, ?)
```

`:88` (`POSTS_BY_PK_SQL3`), asserted at `:538` against `rc_mem_last_sql(a)`
after the full load, with `rc_mem_arg_count(a) == 3` — four mapping rows
`(7,100) (7,101) (9,101) (11,102)` dedupe to three distinct target keys
`100, 101, 102`, so the second IN list is three placeholders wide, not four.

Why two statements and not a JOIN: the mapping table returns *keys*, not target
rows; one statement would need a JOIN whose grouping and column-name collision
handling is a different feature with a different result shape. Two statements
is still `O(1)` in the owner count — only the IN lists grow with N — which is
the N+1 property this phase exists to have. The mapping rows are also the only
honest representation of a share. (This is stated at the call site in
`src/relation/load.mettle`'s header and above `rc_relation_load_through`.)

---

## 4. Exec-count evidence

`out->n_execs` is the loader's own count of statements that actually ran;
`rc_mem_call_count(a)` is the adapter's counter. Both are asserted, so neither
the loader's bookkeeping nor the seam can lie alone.

| check (`tests/t_relation.mettle`) | shape | `rc_mem_call_count(a)` | `out->n_execs` | asserted at |
|---|---|---|---|---|
| `relation: has many is one exec for three owners` | 3 owners | `1` | `1` | `:325-326` |
| `relation: belongs to dedupes keys` | 3 owners, 1 duplicate → 2 keys | `1` | `1` | `:414-415` |
| `relation: belongs to dedupes keys` (follow-up) | 3 distinct keys (cumulative 2) | `2` | `1` | `:447`, `:444` |
| `relation: through is two statements and shares rows` (empty mapping) | 3 owners, no mapping rows | `1` | `1` | `:481-482` |
| `relation: through is two statements and shares rows` | 3 owners, 4 mapping rows | `2` | `2` | `:536-537` |
| `relation: no owners means no statement` | all-NULL keys | `0` | `0` | `:585`, `:582` |
| `relation: no owners means no statement` | `n_keys == 0` | `0` | `0` | `:594`, `:593` |
| `relation: no owners means no statement` | through + all-NULL keys | `0` | `0` | `:603`, `:602` |
| `relation: no owners means no statement` | non-`RC_T_I64` key (`RC_ERR_CAST`) | `0` | `0` | `:613` |
| `relation: no owners means no statement` | `[NULL, 7]` → 1 key, 1 placeholder | `1` | `1` | `:627`, `:626` |
| `relation: a failing exec changes nothing` | injected `RC_ERR_CONFLICT` | `0` | `0` | `:761-762` |
| `relation: a failing exec changes nothing` | through, first statement fails (`RC_ERR_TX`) | `0` | `0` | `:783-784` |

Grouping is asserted alongside the counts, not instead of them: 2/0/1 across
`[7, 9, 11]` for has-many (`:343-347`), a belongs-to group holding both rows the
statement returned for key 7 (`:426-431`), and the through share — the same
`res` row index appearing in groups 7 and 9 (`:555-556`,
`out.idx[2] == out.idx[1]`).

The **exact `ok` lines**, debug binary
(`/tmp/reach-check/t_relation.debug.run.log`):

```
  ok   relation: startup check refuses bad metadata
  ok   relation: has many is one exec for three owners
  ok   relation: belongs to dedupes keys
  ok   relation: through is two statements and shares rows
  ok   relation: no owners means no statement
  ok   relation: hydrate borrows the result
  ok   relation: a failing exec changes nothing
7 checks passed
```

Release binary (`/tmp/reach-check/t_relation.release.run.log`) — byte-identical:

```
  ok   relation: startup check refuses bad metadata
  ok   relation: has many is one exec for three owners
  ok   relation: belongs to dedupes keys
  ok   relation: through is two statements and shares rows
  ok   relation: no owners means no statement
  ok   relation: hydrate borrows the result
  ok   relation: a failing exec changes nothing
7 checks passed
```

Other behaviours pinned in the same seven checks:

- startup refusals: every row of the §2 table, each with its own code, plus
  "the loader checks too and runs no statement" (`:279`, `call_count == 0`);
- keys: NULL skipped, non-i64 → `RC_ERR_CAST` before any statement, duplicates
  deduped with `rc_value_same` (the dedupe predicate in `load.mettle`), first-
  seen order kept in `out->keys`;
- hydration: `*nulls` zeroed first, cells borrowed from `out->res` (pointer
  identity of `model.title.chars` and the result cell asserted at `:679`), NULL
  sets the null bit, out-of-range group/index → `RC_ERR_USAGE`, and
  `rc_meta_set`'s range check still fires (`age = 5000000000` into an int32 →
  `RC_ERR_RANGE`, `:732`);
- failure: return code unchanged, `n_keys`/`keys` kept (what was decided),
  `idx == 0`, `off == 0`, no rows, no half-filled groups.

---

## 5. Commands and exact output

Working directory: `/home/nox/Projects/mettle/reach`. Compiler:
`METTLE=/home/nox/Projects/mettle/raize/mettle-build/bin/mettle`;
build tool: `/home/nox/Projects/mettle/mbuild/build/bootstrap/mbuild`
(`tools/check.sh` wires both).

```
$ tools/check.sh tests/t_relation.mettle
== mbuild check
  ok   mbuild.check
== mbuild test (interpreter)
  ok   mbuild.test
== tests/t_relation.mettle
  ok   t_relation.debug.build
  ok   t_relation.debug.run
  ok   t_relation.release.build
  ok   t_relation.release.run
== demo bin
  ok   mbuild.build
  ok   demo.debug.run
  ok   mbuild.build.release
  ok   demo.release.run

10 passed, 0 failed (logs in /tmp/reach-check)
```

```
$ tools/check.sh
== mbuild check
  ok   mbuild.check
== mbuild test (interpreter)
  ok   mbuild.test
== tests/t_adapter.mettle      ... 4x ok
== tests/t_changeset.mettle    ... 4x ok
== tests/t_meta.mettle         ... 4x ok
== tests/t_migration.mettle    ... 4x ok
== tests/t_persist.mettle      ... 4x ok
== tests/t_query.mettle        ... 4x ok
== tests/t_relation.mettle     ... 4x ok
== tests/t_value.mettle        ... 4x ok
== demo bin                    ... 4x ok

38 passed, 0 failed (logs in /tmp/reach-check)
```

```
$ tools/check.sh tests/t_value.mettle tests/t_meta.mettle tests/t_adapter.mettle \
                 tests/t_persist.mettle tests/t_relation.mettle
...
26 passed, 0 failed (logs in /tmp/reach-check)
```

```
$ /home/nox/Projects/mettle/raize/mettle-build/bin/mettle test tests/t_relation.mettle
running 1 test (compile-time interpreter, no codegen)
test t_relation ... ok

1 passed (tests/t_relation.mettle)
```

`mbuild test` was never used as the whole gate: the file gate above builds and
runs the debug and release binaries (release is mandatory in this project) and
runs the demo in both profiles.

---

## 6. Layout migration note

The repository moved to the mbuild layout after this phase's files were first
written; the move was done for us, and what changed is mechanical:

- modules moved from `reach/<mod>/` to `src/<mod>/`, so the two source files are
  now `src/relation/relation.mettle` and `src/relation/load.mettle`;
- imports became **file-relative**: `import "reach/core/status"` →
  `import "../core/status"`, `import "../adapter/adapter"`,
  `import "../query/builder"`, and same-directory `import "relation"` from
  `load.mettle`;
- `tests/t_relation.mettle` imports `../src/core/*`, `../src/adapter/*`,
  `../src/relation/*`, and bare `models` / `harness` (the test directory is the
  import root for those);
- the gate became `tools/check.sh` driving `mbuild check`, `mbuild test`, then
  per-file debug/release build+run through `mbuild mettle -- …`, plus the demo
  bin in both profiles. No `[toolchain]` pin was added; `mbuild.toml` is
  untouched and the head compiler is selected via `METTLE`.

Adjustments made to the two source files: header comments that named the old
`reach/relation/…` / `reach/query` paths were updated to `src/relation/…` /
`src/query`, and the owner-key dedupe was changed to call `rc_value_same`
(the contract names it explicitly) instead of comparing the two int64s
directly — for `RC_T_I64` the two are identical, but there is now one
definition of "same key".

---

## 7. What Phase 1/2 would have needed to do differently, and limitations

**Nothing had to change in Phase 1 or Phase 2** — both seams were sufficient as
built:

- `rc_query_where_in` refusing `n <= 0` is exactly what makes "empty owner set →
  zero statements" the only possible behaviour instead of an `IN ()` syntax
  error, and it is why the loader's zero-exec path is not a special case.
- `rc_result_borrow` is what makes zero-copy hydration possible: the model's
  string fields are views into `out->res`, and `rc_relation_free` ends the
  borrow (the same lifetime contract as `rc_persist_load`'s `owner` out-param).
- `rc_query_select` building the column list from `RcMeta` is what lets the
  through projection (`SELECT "user_id", "post_id"`) come out of query rather
  than out of a hand-built buffer.
- `rc_meta_check` accepting a 2-field, keyless table is what makes the mapping
  table a first-class `RcMeta` (no PK is correct for a pair table).

Remaining limitations / deliberate choices:

1. `RcRelationResult` carries `meta: RcMeta` (one field beyond the listed
   shape) because `rc_relation_hydrate` has no meta parameter. Metadata only —
   no cache, no owner pointer, no session.
2. Grouping is a linear scan: `O(rows × keys)` for HAS_MANY/BELONGS_TO and
   `O(mapping rows × (keys + target rows))` for THROUGH. Right for page-sized
   batches; a hash map belongs to the session phase (`docs/01-architecture.md`
   §1.2), not here.
3. THROUGH runs two statements only while the mapping returns rows. An empty
   mapping means there is no target key to bind, and `IN ()` is refused, so the
   second statement is correctly skipped and `n_execs` reports `1`. That is the
   "reports the truth" behaviour, not a missed statement.
4. A NULL inside the owner key set is skipped (never bound). A NULL foreign key
   on a *target* row simply matches no group: the row stays in `res` and is
   unreachable through `off` — no row is dropped from `res`.
5. `idx` may hold the same `res` row index in two groups (a shared/many-to-many
   row). That is by design and the test asserts it.
6. Self-referential relations (e.g. `Post -> Post` via `parent_id`) are
   expressible — different `local_field`/`foreign_field`, same table — but are
   not covered by a test; the grouping is value-based so nothing in the loader
   assumes the two tables differ.
7. No lazy loading, no session, no identity map, no cache keyed by owner: a
   load is one explicit call with explicit keys. Adding caching is a session
   concern and would need the arena / identity map that this phase deliberately
   does not have.
