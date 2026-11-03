# Directive — reach-query (Phase 2)

Issued: wave A. Contract you are judged against. `docs/02-seams.md` remains
authoritative for what you may rely on; this file is the narrower task.

## Files you may create

- `reach/query/builder.mettle`   (required)
- `reach/query/dialect.mettle`   (required — see §Dialect)
- `reach/query/expr.mettle`      (optional, only if it earns its keep)
- `reach/query/insert.mettle`    (optional; batch INSERT may live in builder)
- `tests/t_query.mettle`         (required)
- `reports/query.md`             (required report)

Nothing else. In particular **do not** create or edit: `core/`, `adapter/`,
`changeset/`, `relation/`, `migration/`, `docs/`, `tests/models.mettle`,
`tests/harness.mettle`, `tools/check.sh`, `tests/t_value.mettle`,
`tests/t_meta.mettle`, `tests/t_adapter.mettle`, `tests/t_persist.mettle`.
`core/persist.mettle` stays exactly as it is; you supersede its SELECT text
generation, you do not delete it.

## Frozen symbols you may use (and only these)

From `reach/core/value` (import `"reach/core/value"`):
`RcValue` + its arms, `RcNull`, `RcInt`, `RcText`, `rc_value_type`,
`rc_value_is_null`, `rc_value_same`, `rc_value_type_name`, `RC_T_*`.

From `reach/core/meta`: `RcMeta`, `RcField`, `rc_meta_field`, `rc_meta_find`,
`rc_meta_pk`, `rc_meta_is_auto`, `rc_meta_check`, `rc_nulls_has`, `RC_F_*`,
`RC_MAX_FIELDS`.

From `reach/core/buf`: `RcBuf`, `rc_buf_new`, `rc_buf_free`, `rc_buf_clear`,
`rc_buf_put`, `rc_buf_putc`, `rc_buf_put_i64`, `rc_buf_ident`, `rc_buf_text`.

From `reach/core/status`: `RC_OK` and the `RC_ERR_*` codes. **Never invent a
status code.** New negative numbers are a stop condition.

From `reach/adapter/adapter`: `RcAdapter`, `RcResult`, `rc_adapter_exec`,
`rc_result_init`, `rc_result_free`, `rc_result_borrow`, `rc_result_get`.

From `reach/adapter/mem` (tests only): `rc_mem_adapter`, `rc_mem_free`,
`rc_mem_push_rows`, `rc_mem_push_ok`, `rc_mem_fail_next`, `rc_mem_last_sql`,
`rc_mem_last_args`, `rc_mem_arg_count`, `rc_mem_call_count`.

From `tests/models` (tests only): `user_meta()`, `post_meta()`,
`user_meta_status()`, `post_meta_status()`. Models: `User`, `Post`, `Doc`.
From `tests/harness` (tests only): `rc_report(name, code)`, `rc_summary(f, t)`.

You may **not** add to `core/`. If something is missing there, say so in your
report as a needed seam and work around it without editing `core/`.

## Dialect — ownership decision (resolves a doc conflict)

`docs/02-seams.md` gives `RcDialect` to Phase 2, and `.pi/agents/reach.adapter.md`
also mentions a `adapter/dialect.mettle`. For this wave **`RcDialect` lives in
`reach/query/dialect.mettle`** and `adapter/` is not being written (no second
writer, no duplicate export). Do not edit `adapter/`.

Required shape (exact names):

```
export struct RcDialect {
  name: string;        // "dacor"
  quote: string;       // "\""
  placeholder: string; // "?"
  has_limit: bool;     // true
}
export fn rc_dialect_default() -> RcDialect
export fn rc_dialect_name(d: RcDialect) -> string
export fn rc_dialect_ident(d: RcDialect, b: RcBuf*, name: string) -> int32
export fn rc_dialect_placeholder(d: RcDialect, b: RcBuf*) -> int32
```

`rc_dialect_default()` must satisfy: `rc_dialect_ident(default, b, s)` produces
**byte-identical** text to `rc_buf_ident(b, s)` for `users`, `weird "name"`,
empty string, and a name with a backslash. Assert that equality in the test —
that is what proves routing buf through the dialect changed nothing. One
dialect is enough; do not invent a second SQL flavour.

## Statement shapes you freeze (relation/ will call these verbatim)

SELECT base, `q = rc_query_select(m)`:

```
SELECT "id", "email", ... FROM "users"
```
Column list in `RcMeta.fields` order, `", "` separators, exactly like
`core/persist.mettle`'s column helper.

Clauses append in this order, single spaces, no trailing space:

| call | text appended |
|---|---|
| `rc_query_where_eq(q, field, v)` | ` WHERE "col" = ?` (first) / ` AND "col" = ?` (later) |
| `rc_query_where_eq(q, field, RcNull)` | ` WHERE "col" IS NULL` / ` AND "col" IS NULL` |
| `rc_query_where_null(q, field)` | same as the RcNull case |
| `rc_query_where_not_null(q, field)` | `... "col" IS NOT NULL` |
| `rc_query_where_in(q, field, vals, n)` | `... "col" IN (?, ?, ?)` (n placeholders, `", "` separated) |
| `rc_query_order_by(q, field, asc)` | ` ORDER BY "col" ASC` / ` DESC`; repeated calls append `, "col2"` |
| `rc_query_limit(q, n)` | ` LIMIT 10` — the number is **literal**, via `rc_buf_put_i64` |
| `rc_query_offset(q, n)` | ` OFFSET 5` — literal |
| `rc_query_join(q, target: RcMeta, local_field: int32, foreign_field: int32, kind: int32)` | ` JOIN "posts" ON "users"."id" = "posts"."user_id"` / ` LEFT JOIN ...`; `kind` is `RC_JOIN_INNER` / `RC_JOIN_LEFT` |

Hard rules, each asserted by a test that compares the **whole** SQL string
with `==` (not `contains`, not a length check):

1. Values are always placeholders. The string `= NULL` must never appear.
   Test it for `where_eq(f, RcNull)`.
2. JOIN adds **no** placeholders, so `q->args` order is exactly the order of
   the `where_*` calls. Document that sentence in the module header.
3. `where_in` with `n == 0` returns `RC_ERR_USAGE` and appends nothing.
   `n == 1` still emits `IN (?)`.
4. `limit`/`offset` refuse negative values with `RC_ERR_USAGE`.
5. Identifiers go through `rc_dialect_ident` only. No string concatenation of
   `m.table` / `f.column` anywhere.
6. Clause-order violations are `RC_ERR_USAGE`, not garbage text: `where_*`
   after `order_by`/`limit`/`offset`, `order_by` after `limit`, `limit` twice.

## Batch INSERT shape you freeze

```
export fn rc_query_insert_batch(m: RcMeta, n_rows: int32) -> RcQuery
export fn rc_query_push_arg(q: RcQuery*, v: RcValue) -> int32
```

Emits, for `m = user_meta()` and `n_rows = 2`:

```
INSERT INTO "users" ("email", "name", "age", "active", "score", "created_at", "role") VALUES (?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?)
```

Rule: an `RC_F_AUTO` primary key is **always** omitted from the column list
(same rule as `rc_persist_insert`, and unlike persist it does not consult a
null bitmap — batch rows share one column list). `n_rows <= 0` is
`RC_ERR_USAGE`. `rc_query_push_arg` appends one borrowed `RcValue`; it must
refuse (with `RC_ERR_USAGE`) once `n_args` equals `n_rows * n_cols_emitted`,
so a half-filled batch cannot be executed. Assert exact text, exact
`rc_query_n_args`, and the arg values in order after `rc_query_exec`.

## Exported seam — the complete list, no additions

```
RcDialect, rc_dialect_default, rc_dialect_name, rc_dialect_ident,
rc_dialect_placeholder
RC_JOIN_INNER, RC_JOIN_LEFT
RcQuery { meta, dial, buf, args: RcValue*, n_args, n_cap, ... }
rc_query_select(m: RcMeta) -> RcQuery
rc_query_insert_batch(m: RcMeta, n_rows: int32) -> RcQuery
rc_query_push_arg(q: RcQuery*, v: RcValue) -> int32
rc_query_where_eq(q: RcQuery*, field: int32, v: RcValue) -> int32
rc_query_where_null(q: RcQuery*, field: int32) -> int32
rc_query_where_not_null(q: RcQuery*, field: int32) -> int32
rc_query_where_in(q: RcQuery*, field: int32, vals: RcValue*, n: int32) -> int32
rc_query_order_by(q: RcQuery*, field: int32, asc: bool) -> int32
rc_query_limit(q: RcQuery*, n: int64) -> int32
rc_query_offset(q: RcQuery*, n: int64) -> int32
rc_query_join(q: RcQuery*, target: RcMeta, local_field: int32,
              foreign_field: int32, kind: int32) -> int32
rc_query_sql(q: RcQuery*) -> string          // borrowed, valid until next mutation
rc_query_args(q: RcQuery*) -> RcValue*       // borrowed cells
rc_query_n_args(q: RcQuery*) -> int32
rc_query_exec(q: RcQuery*, a: RcAdapter*, out: RcResult*) -> int32
rc_query_free(q: RcQuery*)
```

One flat namespace: every export is prefixed `Rc`/`rc_`/`RC_`. A duplicate
export on the other workers' files is a hard build error, so do not export
anything else.

Ownership rule to document and test: `q->args` holds **borrowed** `RcValue`
cells; `rc_query_free` frees the arg array and the buf, never `rc_value_release`
a cell. Test: `where_eq` with a heap text, `rc_query_free`, then the text is
still readable (no double free / no use-after-free).

## Not your job

- No UPDATE/DELETE statement builder beyond what is listed. `changeset/`
  emits UPDATE in Phase 3, `core/persist` keeps DELETE.
- No session, arena, hooks, identity map, prepared-statement cache, or row
  hydration into a model. Those are later/other phases.
- No sorting in memory, no index-key encoding, no collation guessing.

## Definition of done

1. `cd /home/nox/Projects/mettle/reach && tools/check.sh tests/t_query.mettle`
   prints `5 passed, 0 failed (logs in /tmp/reach-check)` — interpreter,
   debug build, debug run, release build, release run. Release is mandatory.
2. `tests/t_query.mettle` follows the shape of `tests/t_persist.mettle`: an
   `export fn main() -> int32` that calls `check_*()` through `rc_report`, and
   one `@test fn t_query() -> int32` that calls the same functions. At least
   these checks, each with an exact-string assertion where SQL is involved:
   - `query: select text matches persist` — for `user_meta()`, your SELECT
     prefix + WHERE + LIMIT equals the string `core/persist` produces
     (compare against the literal `SELECT_SQL` from `tests/t_persist.mettle`).
   - `query: where args bind in order` — eq, in (3 values), eq → 5 args, exact
     values and exact text, `rc_mem_arg_count == 5`.
   - `query: null never becomes = NULL` — `where_eq(f, RcNull)` emits
     `IS NULL`; assert the string `"= NULL"` does not occur.
   - `query: order limit offset are literal` — ` ORDER BY "email" ASC LIMIT 10 OFFSET 5`.
   - `query: join emits no placeholders` — exact LEFT JOIN text, arg count 0.
   - `query: batch insert rows` — exact text above, arg count 14, exec passes
     them through in order.
   - `query: dialect ident equals buf ident` — byte equality on all four names.
   - `query: misuse is refused` — empty IN, negative limit, where-after-limit,
     over-filled batch: `RC_ERR_USAGE` each, and `rc_mem_call_count` unchanged.
3. No edit outside your file list (§Files). `git`-less check: the director
   will diff the tree.
4. No `--safe`, no `std/strbuf` on the hot path, 2-space indent, explicit type
   on every `var` and local `const`, `export` on every public declaration,
   `defer rc_buf_free(&q->buf)` style cleanup so the leak analyser is quiet.
5. Report in `reports/query.md`: files, the exported seam symbol by symbol, the
   **exact SQL text pasted** for every shape above, the commands run, the exact
   pass/fail lines, and any seam you needed but could not have.
