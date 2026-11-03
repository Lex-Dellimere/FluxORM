# Directive — reach-relation (Phase 4) — REISSUED for the mbuild layout

Supersedes the earlier revision of this file (which used `reach/<mod>/` paths
and `tools/check.sh`'s mettle-only shape). Everything below is the canonical
layout as it exists on disk **now**.

Context you must know before touching anything:

- The repository moved to the canonical mbuild layout while you were paused.
  Modules live in `src/<mod>/`, imports are **file-relative**:
  from `src/relation/x.mettle`: `import "../core/value";`,
  `import "../adapter/adapter";`, `import "../query/builder";`,
  `import "relation";` (same directory).
  From `tests/t_*.mettle`: `import "../src/relation/load";`,
  `import "models";`, `import "harness";`.
- The build tool is `mbuild` and `tools/check.sh` now drives it. There is **no
  `[toolchain]` pin** and you must not add one; reach needs the head compiler,
  selected with `METTLE` / `--mettle`.
- Your two source files and the test file already exist from the interrupted
  run and **currently pass** the gate (the director ran it):
  `src/relation/relation.mettle`, `src/relation/load.mettle`,
  `tests/t_relation.mettle`. Keep them, fix them, or rewrite them — they are
  yours. They are not accepted until you report the evidence below.

## Files you own (nothing else)

- `src/relation/relation.mettle`
- `src/relation/load.mettle`
- `tests/t_relation.mettle`
- `reports/relation.md`

Do not edit `src/core/`, `src/adapter/`, `src/query/`, `src/changeset/`,
`src/migration/`, `cmd/`, `docs/`, `mbuild.toml`, `tools/check.sh`,
`tests/models.mettle`, `tests/harness.mettle`, or any `tests/t_*.mettle` other
than `t_relation.mettle`. Models get no new columns.

## Seam you may use

Phase 1 (`docs/02-seams.md`, unchanged symbols, new paths): `src/core/status`,
`src/core/value`, `src/core/meta`, `src/core/buf`, `src/adapter/adapter`,
`src/adapter/mem` (tests), `tests/models`, `tests/harness`.

Phase 2 as built (verified green): `src/query/builder` —
```
RC_JOIN_INNER, RC_JOIN_LEFT, RcQuery
rc_query_select(m) -> RcQuery
rc_query_where_eq(q*, field, v) / rc_query_where_in(q*, field, vals, n)
rc_query_sql(q*) / rc_query_args(q*) / rc_query_n_args(q*)
rc_query_exec(q*, a*, out*) / rc_query_free(q*)
```
`rc_query_where_in` refuses `n <= 0` (so an empty owner set runs **zero**
statements), `q->args` is borrowed, `rc_query_free` never releases a cell.

## Required surface (already implemented — keep the names)

```
RC_REL_HAS_MANY / RC_REL_BELONGS_TO / RC_REL_HAS_MANY_THROUGH
RcRelation { name, kind, local_field, foreign_table, foreign_field,
             through_table, through_local, through_foreign }
rc_relation(...) / rc_relation_through(...) / rc_relation_check(...)
RcRelationResult { kind, keys, n_keys, res, idx, off, n_execs, through }
rc_relation_load(a*, rel*, owner_meta, target_meta, through_meta*,
                 keys*: RcValue*, n_keys, out*)
rc_relation_group(out*, key) / rc_relation_count(out*, group)
rc_relation_hydrate(out*, group, i, model, nulls*)
rc_relation_free(out*)
```

## Exact statements that must be emitted (assert with `==`)

```
HAS_MANY    SELECT "id", "user_id", "title", "body", "published_at" FROM "posts" WHERE "user_id" IN (?, ?, ?)
BELONGS_TO  SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" WHERE "id" IN (?, ?, ?)
THROUGH#1   SELECT "user_id", "post_id" FROM "user_posts" WHERE "user_id" IN (?, ?, ?)
THROUGH#2   SELECT "id", "user_id", "title", "body", "published_at" FROM "posts" WHERE "id" IN (?, ?, ?)
```
All of them out of `src/query`, including the through projection (the caller
supplies a 2-field `RcMeta` for the mapping table; `tests/t_relation.mettle`
owns that model). No hand-built SQL with `rc_buf`.

## Non-negotiable behaviours

1. **One statement per relation for N owners**: 1 exec for HAS_MANY and
   BELONGS_TO, 2 for THROUGH, **0** for an empty/all-NULL key set. Nothing
   loops per owner; `out->n_execs` reports the truth.
2. Keys: `RcNull` skipped, non-`RC_T_I64` is `RC_ERR_CAST` before any
   statement, exact duplicates deduped with `rc_value_same`, first-seen order
   preserved.
3. `rc_relation_check` refuses bad metadata at startup (unknown kind, empty
   name, field index out of range, non-integer field, `foreign_table` mismatch,
   BELONGS_TO/THROUGH where `foreign_field` is not the target PK, bad
   `through_meta`: null / not 2 fields / wrong table / wrong column order /
   non-integer, and `through_*` set on a non-THROUGH relation).
4. `rc_relation_load` calls `rc_relation_check` itself and runs no statement if
   it fails.
5. `rc_relation_hydrate` zeroes `*nulls` and copies borrowed cells through
   `rc_meta_set` (the model borrows `out->res`); out-of-range group/index is
   `RC_ERR_USAGE`.
6. No lazy loading, no session, no cache, no identity map in this phase.

## Definition of done (mbuild gate)

```
$ cd /home/nox/Projects/mettle/reach
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

`mbuild test` alone is **not** the gate: it is the interpreter only. Release is
mandatory. Also run the full `tools/check.sh` (no arguments) and paste its final
line — every other phase file must stay green (currently `34 passed, 0 failed`
with 7 files; expect the same plus your file's four cases).

`tests/t_relation.mettle` keeps its shape: `export fn main() -> int32` through
`rc_report`/`rc_summary` plus exactly one `@test`. The seven check names stay as
they are; each assertion on SQL text is `==`.

## The report you owe (`reports/relation.md`)

This is the only deliverable missing from the interrupted run. It must contain:

1. files, with line counts, and a one-line statement of what each does;
2. the exported seam symbol by symbol (as above, with the actual signatures);
3. the exact statements per relation kind, pasted, and where they are asserted;
4. **the exec-count evidence**: for each case the check name, the asserted
   `rc_mem_call_count(a)` and `out->n_execs` value — 1 / 1 / 2 / 0 — and the
   exact `ok` lines from the debug and release binaries;
5. the commands run and their exact pass/fail lines (file gate + full gate);
6. the layout migration note: what changed when imports went file-relative, and
   anything you had to adjust in the two source files because of it;
7. anything Phase 2 or Phase 1 would have needed to do differently, and any
   remaining limitation (e.g. a self-join, a NULL inside an IN list).
