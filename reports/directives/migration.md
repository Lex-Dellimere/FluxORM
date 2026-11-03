# Directive — reach-migration (Phase 5)

Issued: wave A. Contract you are judged against. `docs/02-seams.md` is
authoritative for what you may rely on; this file is the narrower task.

## Files you may create

- `reach/migration/ddl.mettle`      (required — CREATE TABLE from RcMeta, quoting)
- `reach/migration/version.mettle`  (required — RcMigration/Set/Report, run)
- `tests/t_migration.mettle`        (required)
- `reports/migration.md`            (required report)

Nothing else. **Do not** create or edit: `core/`, `adapter/`, `query/`,
`changeset/`, `relation/`, `docs/`, `tests/models.mettle`,
`tests/harness.mettle`, `tools/check.sh`, or any `tests/t_*.mettle` other than
`tests/t_migration.mettle`. In particular **do not import `reach/query`** —
that worker is running in parallel and coupling to it would deadlock the wave.
Quote with `rc_buf_ident` from `core/buf` (its output is byte-identical to
query's default dialect, which query's own test pins).

## Frozen symbols you may use (and only these)

From `reach/adapter/adapter`: `RcAdapter`, `RcResult`, `RcRow`,
`rc_adapter_exec`, `rc_adapter_begin`, `rc_adapter_commit`,
`rc_adapter_rollback`, `RC_TX_IMMEDIATE`, `RC_TX_DEFAULT`, `rc_result_init`,
`rc_result_free`, `rc_result_get`, `rc_result_i64`, `rc_result_text`.

From `reach/core/meta`: `RcMeta`, `RcField`, `rc_meta_field`, `rc_meta_pk`,
`rc_meta_is_auto`, `rc_meta_check`, `RC_F_PK`, `RC_F_AUTO`, `RC_F_NOT_NULL`,
`RC_F_UNIQUE`, `RC_F_TIMESTAMP`.

From `reach/core/value`: `RcValue`, `RcNull`, `RcInt`, `RcText`, `RcTime`,
`rc_value_int`, `rc_value_text`, `rc_value_time`,
`RC_T_I64`, `RC_T_F64`, `RC_T_BOOL`, `RC_T_TEXT`, `RC_T_BLOB`, `RC_T_TIME`,
`RC_T_U64`, `RC_T_UNSUPPORTED`.

From `reach/core/buf`: `RcBuf`, `rc_buf_new`, `rc_buf_free`, `rc_buf_clear`,
`rc_buf_put`, `rc_buf_putc`, `rc_buf_put_i64`, `rc_buf_ident`, `rc_buf_text`.

From `reach/core/status`: `RC_OK` and the existing `RC_ERR_*` codes. **Never
invent a status code.**

From `reach/adapter/mem` (tests only): `rc_mem_adapter`, `rc_mem_free`,
`rc_mem_push_ok`, `rc_mem_push_rows`, `rc_mem_fail_next`, `rc_mem_last_sql`,
`rc_mem_last_args`, `rc_mem_arg_count`, `rc_mem_call_count`, `rc_mem_tx_depth`,
`rc_mem_commits`, `rc_mem_rollbacks`.

From `tests/models` (tests only): `user_meta()`, `post_meta()`, models `User`,
`Post`, `Doc` (Doc fails `rc_meta_check` — use it for the refusal test).
From `tests/harness`: `rc_report`, `rc_summary`.

## Required shape — exact names

```
export const RC_MIG_LEDGER: string = "_reach_migrations";

export struct RcMigration { version: int64; name: string; up_sql: string; }
export struct RcMigrationSet { items: RcMigration*; n: int32; }

export struct RcMigrationReport {
  applied: int32;         // applied this run
  up_to: int64;           // highest version applied after this run
  failed_version: int64;  // 0 when no failure
  code: int32;            // failing RC_*, RC_OK on success
}

export fn rc_migration_set(items: RcMigration*, n: int32) -> RcMigrationSet
export fn rc_migration_check(s: RcMigrationSet) -> int32
export fn rc_migration_ledger_ddl(b: RcBuf*) -> int32
export fn rc_migration_ledger_select(b: RcBuf*) -> int32
export fn rc_migration_ledger_insert(b: RcBuf*) -> int32
export fn rc_migration_create_table(m: RcMeta, b: RcBuf*) -> int32
export fn rc_migration_now_micros() -> int64
export fn rc_migration_set_clock(us: int64)
export fn rc_migration_run(a: RcAdapter*, s: RcMigrationSet*, out: RcMigrationReport*) -> int32
export fn rc_migration_down(a: RcAdapter*, s: RcMigrationSet*, version: int64) -> int32
```

Note: the DDL builders take an `RcBuf*` and return `RC_*` — the agent blurb's
`rc_migration_create_table(m) -> string` cannot return a status code and would
leak an owner; this shape is the directive and overrides the blurb. No other
exports. One flat namespace, `Rc`/`rc_`/`RC_` prefixes.

## Exact statement text (asserted verbatim, no "close enough")

Ledger DDL:
```
CREATE TABLE IF NOT EXISTS "_reach_migrations" ("version" INTEGER PRIMARY KEY, "name" TEXT NOT NULL, "applied_at" INTEGER NOT NULL)
```
Ledger read:
```
SELECT "version" FROM "_reach_migrations" ORDER BY "version" ASC
```
Ledger record:
```
INSERT INTO "_reach_migrations" ("version", "name", "applied_at") VALUES (?, ?, ?)
```

`rc_migration_create_table(user_meta(), b)` must produce exactly:
```
CREATE TABLE IF NOT EXISTS "users" ("id" INTEGER PRIMARY KEY, "email" TEXT NOT NULL UNIQUE, "name" TEXT NOT NULL, "age" INTEGER, "active" INTEGER NOT NULL, "score" REAL, "created_at" INTEGER NOT NULL, "role" INTEGER NOT NULL)
```
and for `post_meta()`:
```
CREATE TABLE IF NOT EXISTS "posts" ("id" INTEGER PRIMARY KEY, "user_id" INTEGER NOT NULL, "title" TEXT NOT NULL, "body" TEXT, "published_at" INTEGER)
```

Column spelling rules, in this order: quoted column, one space, affinity, then
` PRIMARY KEY` (only on `meta.pk`), then ` UNIQUE` (when `RC_F_UNIQUE`), then
` NOT NULL` (when `RC_F_NOT_NULL` and not already implied by PRIMARY KEY).
Affinity: `RC_T_I64`/`RC_T_BOOL`/`RC_T_TIME`/`RC_T_U64` → `INTEGER`,
`RC_T_F64` → `REAL`, `RC_T_TEXT` → `TEXT`, `RC_T_BLOB` → `BLOB`,
`RC_T_UNSUPPORTED` → refuse the whole call with `RC_ERR_UNSUPPORTED` before
writing anything into the buffer (no partial text; test with `doc_meta()` and
assert the buffer is empty). `RC_F_AUTO` adds no keyword — `INTEGER PRIMARY KEY`
is the whole story; put that sentence in a comment. A failing `rc_meta_check`
means `RC_ERR_UNSUPPORTED`/the meta code and an untouched buffer.

## `rc_migration_run` — the sequence you must implement

1. `rc_migration_check` the set first. Malformed set → return the code with
   `out->code` set, `out->applied == 0`, and **no exec at all** (assert
   `rc_mem_call_count == 0`).
2. `exec` the ledger DDL (no transaction — a DDL that creates a table needs no
   unit of work and `mem`'s `begin` refuses nesting anyway).
3. `exec` the ledger SELECT, read column 0 of every row as `int64`. Zero rows
   is normal. `n_cols != 1` → `RC_ERR_ADAPTER`.
4. If the ledger contains a version **not present** in the set → the store is
   ahead of the code: return `RC_ERR_CONFLICT`, `out->failed_version` = that
   version, no transaction started.
5. For each set entry not already applied, ascending: `begin(RC_TX_IMMEDIATE)`
   → `exec(up_sql)` → `exec(ledger INSERT)` with args
   `RcInt(version), RcText(name), RcTime(applied_at)` → `commit`. **One
   transaction per migration**, so a failure mid-run leaves the ledger and the
   schema agreeing.
6. On any failure inside the transaction: `rollback`, set
   `out->code`/`out->failed_version`, `out->applied` = how many *did* apply,
   and return the code. Do not swallow it, do not continue.
7. Success: `out->code = RC_OK`, `out->failed_version = 0`,
   `out->up_to` = highest version now applied.

`applied_at`: `rc_migration_now_micros()`. There is **no `std/time` in this
stdlib**, and an `extern clock_gettime` is not guaranteed in the compile-time
interpreter. So:

- `rc_migration_set_clock(us)` injects the value the ledger uses (test seam);
  `0` means "no injection".
- `rc_migration_now_micros()` returns the injected value when non-zero,
  otherwise `0` — **unless** you get a real clock working in all five gate runs
  (interp, debug, debug-run, release, release-run); then keep it and still
  return the injected value when set.
- Either way: a comment at that function stating exactly which of the two
  shapes shipped and why, and a line in your report. A test must never depend
  on the real clock; it asserts the injected value.

## Definition of done

1. `cd /home/nox/Projects/mettle/reach && tools/check.sh tests/t_migration.mettle`
   prints `5 passed, 0 failed (logs in /tmp/reach-check)` — interpreter,
   debug build, debug run, release build, release run. Release is mandatory.
2. `tests/t_migration.mettle` follows `tests/t_persist.mettle`'s shape:
   `export fn main() -> int32` running `check_*()` through `rc_report`, plus
   one `@test fn t_migration() -> int32` running the same functions. Required
   checks:
   - `migration: ledger statements are exact` — all three strings above, `==`.
   - `migration: create table matches metadata` — User and Post strings above,
     `==`; `doc_meta()` refused with an empty buffer.
   - `migration: applies only missing versions` — ledger replay reports
     version 1 applied, set = {1,2}: exactly one migration runs, `applied == 1`,
     `up_to == 2`, `rc_mem_commits == 1`, `rc_mem_rollbacks == 0`,
     `rc_mem_tx_depth == 0`, `rc_mem_last_sql` == the ledger INSERT,
     `rc_mem_arg_count == 3`, args `[RcInt(2), RcText("..."), RcTime(1700000000000123)]`
     after `rc_migration_set_clock(1700000000000123)`, and `rc_mem_call_count`
     equal to the exact number of execs your sequence performs (count it from
     the code, do not guess).
   - `migration: each migration commits its own transaction` — two pending
     versions → `rc_mem_commits == 2`, `rollbacks == 0`, tx_depth 0.
   - `migration: failure rolls back and reports the version` — armed
     `rc_mem_fail_next(a, RC_ERR_ADAPTER)` on the first pending migration:
     `RC_ERR_ADAPTER` returned, `out->failed_version == 1`, `out->code ==
     RC_ERR_ADAPTER`, `out->applied == 0`, `rc_mem_rollbacks == 1`,
     `rc_mem_commits == 0`, `tx_depth == 0`, and the ledger INSERT text never
     became `rc_mem_last_sql`.
   - `migration: store ahead of code is refused` — ledger replays version 9,
     set = {1,2} → `RC_ERR_CONFLICT`, `failed_version == 9`,
     `rc_mem_commits == 0`.
   - `migration: invalid sets are refused` — duplicate version, descending
     versions, empty name, empty `up_sql`, `version == 0`: `RC_ERR_USAGE`
     each and `rc_mem_call_count == 0`.
   - `migration: down is unsupported` — `rc_migration_down(...)` returns
     `RC_ERR_UNSUPPORTED` and `rc_mem_call_count` is unchanged.
3. No edit outside your file list. 2-space indent, explicit type on every
   `var`/local `const`, `export` on every public declaration, `defer` cleanup so
   the leak analyser is quiet, no `--safe`, no `std/strbuf`.
4. Report in `reports/migration.md`: files, exported seam symbol by symbol, the
   exact DDL/ledger text pasted, the exec sequence with its call counts, the
   clock decision with its justification, the commands run, the exact pass/fail
   lines.
