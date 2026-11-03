# Directive — cross-phase integration test (Phase 6 acceptance)

You are a fresh worker. Your single deliverable is **`tests/t_integration.mettle`**.
You may create that one file and nothing else (no report file, no source edits).
Report in your final message instead.

The script is `docs/04-integration.md`. Read it, then read the code — **where
the document and the code disagree, the code wins.** The document was written
before phases 2–5 existed and it names at least six things that are not in the
tree. You must not invent symbols, and you must not weaken an assertion to make
the script fit. Instead: implement the scenario with the real seam, and list
every divergence in your final message under "doc vs code".

## Repository reality (verified by the director)

Canonical mbuild layout. Modules in `src/<mod>/`, imports are **file-relative**:

- from `tests/t_integration.mettle`: `import "../src/core/value";`,
  `import "../src/query/builder";`, `import "models";`, `import "harness";`,
  `import "std/mem";`, `import "std/io";`
- build tool `mbuild`; `tools/check.sh` drives it. No `[toolchain]` pin; the
  head compiler comes from `METTLE`.

Frozen seams, all green today (`tools/check.sh` → 34 passed, 0 failed with 7
files; `tools/check.sh tests/t_relation.mettle` → 10 passed, 0 failed):

| module | what you may call |
|---|---|
| `src/core/value` | `RcValue` arms, `RC_T_*`, `rc_value_same`, `rc_value_type`, `rc_value_is_null`, `rc_text_dup/free` |
| `src/core/meta` | `RcMeta`, `rc_meta_field/find/pk/get/set/check`, `rc_nulls_has`, `RC_F_*`, `RC_MAX_FIELDS` |
| `src/core/entity` | `RcEntity`, `RC_ST_*`, `rc_entity_new/get/set/pk/has_pk/state_name` |
| `src/core/buf` | `RcBuf`, `rc_buf_new/free/clear/put/putc/put_i64/ident/text` |
| `src/core/persist` | `rc_persist_insert(a*, e*)`, `rc_persist_load(a*, m, pk, model, nulls*, owner*)`, `rc_persist_delete(a*, e*)` |
| `src/adapter/adapter` | `RcAdapter`, `RcResult`, `rc_adapter_exec/begin/commit/rollback/open/close`, `rc_result_*` |
| `src/adapter/mem` | `rc_mem_adapter/free/push_rows/push_ok/fail_next/last_sql/last_args/arg_count/call_count/tx_depth/commits/rollbacks` |
| `src/query/builder` | `rc_query_select(m)`, `rc_query_where_eq/where_null/where_not_null/where_in`, `rc_query_order_by/limit/offset/join`, `rc_query_insert_batch`, `rc_query_push_arg`, `rc_query_sql/args/n_args/exec/free` |
| `src/changeset/changeset` | `rc_changeset_new/free/reset/bind/put/put_name/put_text/put_null/has/n_dirty/apply/valid/error_field/error_code/error_reason` |
| `src/changeset/cast` | `RC_CS_MAX_TEXT`, `rc_cast_text`, `rc_cast_fits` (internal cast seam, callable) |
| `src/migration/ddl` | `rc_migration_create_table(m, b: RcBuf*)` — **buffer, not string** |
| `src/migration/version` | `RC_MIG_LEDGER`, `RcMigration`, `RcMigrationSet`, `RcMigrationReport`, `rc_migration_set/check/ledger_ddl/ledger_select/ledger_insert/now_micros/set_clock/run/down` |
| `src/relation/relation` | `RC_REL_*`, `RcRelation`, `rc_relation`, `rc_relation_through`, `rc_relation_check` |
| `src/relation/load` | `RcRelationResult`, `rc_relation_load/group/count/hydrate/free` |
| `tests/models` | `user_meta()`, `post_meta()`, `doc_meta()`, models `User`, `Post`, `Doc` |
| `tests/harness` | `rc_report(name, code)`, `rc_summary(failures, total)` |

## Doc vs code — the divergences you must handle, not paper over

1. `docs/04-integration.md` §1 says `rc_migration_create_table(user_meta()) ==
   <string>`. In code it is `rc_migration_create_table(m, b: RcBuf*) -> int32`
   and the emitted text starts with `CREATE TABLE IF NOT EXISTS`.
2. §1's ledger read is documented as `SELECT "version", "name" FROM ...`. The
   code emits `SELECT "version" FROM "_reach_migrations" ORDER BY "version" ASC`.
3. §3 uses `rc_query_where_gt`, which **does not exist** in the builder (only
   `eq`, `null`, `not_null`, `in`). Do not invent it: build the scenario with
   `where_in` / `where_eq`, and say so.
4. §3's "the `age IS NULL` row is excluded from the result" cannot be asserted
   through `adapter/mem`: it replays scripted rows, it does not evaluate SQL.
   Assert the *three-valued logic* where it lives — `where_eq(f, RcNull)` emits
   `IS NULL` and binds no argument, the string `= NULL` never appears, and a
   NULL field is distinguishable from `0` via `rc_entity_get` returning
   `RcNull` while the storage byte is `0`.
5. §4's `UPDATE "users" SET ...` **has no emitter yet** (changeset produces the
   mask and the values; no phase emits UPDATE). Assert the mask: exactly the two
   changed bits, `n_dirty == 2`, the values in field order, `age = 0` sets a bit
   and binds `RcInt(0)` while `age = NULL` binds `RcNull`, and an unchanged put
   sets no bit. State the missing emitter in your divergence list.
6. §5's "second preload hits the session cache: exec count does not change"
   describes a session that does not exist and was explicitly out of scope.
   Omit it; do not fake a cache.
7. §7's "relation load with mismatched field types → `RC_ERR_UNSUPPORTED`" is
   `RC_ERR_CAST` in the code (`rc_relation_check`). Assert the real code.
8. §7's "changeset with unknown field name → field name in the diagnostic" is
   `RC_ERR_USAGE` with `error_field() == -1` and the static reason string
   `"unknown field name"`. Assert that.

Anything else that disagrees: follow the code, list it.

## What the test must prove (one `check_*` function each)

Shape: `export fn main() -> int32` running the checks through `rc_report`, plus
exactly one `@test fn t_integration()`. Every SQL/DDL assertion is `==` against a
literal; every failure case also asserts `rc_mem_call_count` did not move. The
mem adapter replays a FIFO, so **assert the text at the same index as the rows
you push** — a test that pushes rows in the wrong order passes for the wrong
reason.

1. `integration: migration creates the ledger and the schema` — ledger DDL,
   ledger SELECT, per-migration transaction (commits/rollbacks/tx_depth), ledger
   INSERT args `[RcInt(v), RcText(name), RcTime(injected)]` with
   `rc_migration_set_clock`, `CREATE TABLE IF NOT EXISTS "users" (...)` exact,
   and a re-run over a full ledger emits no `CREATE TABLE` and no commit.
2. `integration: insert binds args and adopts the key` — `rc_persist_insert`
   with NULL `age`: exact INSERT text (AUTO pk omitted), 7 args in declaration
   order with `RcNull` at age, `last_id` adopted, `NEW → CLEAN`; then an
   explicit-key insert writes the key.
3. `integration: query builds the statement and binds in order` — exact SELECT
   text with `WHERE "age" IN (?, ?) ORDER BY "name" ASC LIMIT 10`,
   `rc_mem_arg_count`, arg order, and that `where_eq(f, RcNull)` gives
   `IS NULL` with no argument (no `= NULL`).
4. `integration: changeset yields a two-field update` — as §4 above.
5. `integration: relation preloads in one exec for three owners` — exact
   `SELECT ... FROM "posts" WHERE "user_id" IN (?, ?, ?)`, `n_execs == 1`,
   `rc_mem_call_count == 1`, groups 2/2/2 plus a fourth owner with zero posts
   (empty list, not a null pointer), and belongs-to from the other side in one
   exec.
6. `integration: delete and a conflict leave no state` — exact DELETE text and
   one key argument; then `rc_mem_fail_next(RC_ERR_CONFLICT)` on an insert:
   entity still `NEW`, keyless, unchanged in memory, retry succeeds.
7. `integration: the failure matrix never reaches the store` — each row of §7
   above with the *real* codes: NULL into NOT NULL, unknown changeset field,
   inserting `Doc` (`RC_ERR_UNSUPPORTED`), empty change set (`n_dirty == 0` →
   refuse to build), mismatch types (`RC_ERR_CAST`), duplicate migration version
   (`RC_ERR_USAGE`); each with `rc_mem_call_count` unchanged.

## Acceptance (run these yourself, paste the lines)

```
$ cd /home/nox/Projects/mettle/reach
$ tools/check.sh tests/t_integration.mettle
== mbuild check
  ok   mbuild.check
== mbuild test (interpreter)
  ok   mbuild.test
== tests/t_integration.mettle
  ok   t_integration.debug.build
  ok   t_integration.debug.run
  ok   t_integration.release.build
  ok   t_integration.release.run
== demo bin
  ok   mbuild.build
  ok   demo.debug.run
  ok   mbuild.build.release
  ok   demo.release.run

10 passed, 0 failed (logs in /tmp/reach-check)
```
and then the full gate, which must stay green:
```
$ tools/check.sh
<n> passed, 0 failed (logs in /tmp/reach-check)
```

`mbuild test` alone is not the gate — it is the interpreter only; release is
mandatory. Do not use `--safe`, do not add a toolchain pin, 2-space indent,
explicit type on every `var`/local `const`, `export` on every declaration,
`Rc`/`rc_`/`RC_` prefixes only.

## Hard limits

- You may create **only** `tests/t_integration.mettle`.
- You may not edit `src/`, `tests/models.mettle`, `tests/harness.mettle`,
  `tests/t_*.mettle` (any other), `tools/check.sh`, `mbuild.toml`, `cmd/`,
  `docs/`.
- If a check cannot be written honestly with the seam that exists, do not
  weaken it and do not fabricate the symbol: leave it out and put it in your
  divergence list with the reason.
