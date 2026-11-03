# reach-query — Phase 2 report (`reach/query`)


> Paths below predate the mbuild restructure: `reach/<mod>/` is now
> `src/<mod>/`, and imports are file-relative. The behaviour and symbol names
> are unchanged.
Worker: reach-query. Contract: `reports/directives/query.md`.
Status: **done, green** — `5 passed, 0 failed` for `tests/t_query.mettle`
(interp / debug build / debug run / release build / release run), and the
Phase-1 suite still prints `20 passed, 0 failed`.

---

## 1. Files added

| file | why |
|---|---|
| `reach/query/dialect.mettle` | `RcDialect` + the four dialect entry points. Owns quoting/placeholder/LIMIT spelling for the whole tree, so there is exactly one definition (no `adapter/dialect.mettle` this wave). |
| `reach/query/builder.mettle` | `RcQuery`, the SELECT/JOIN/WHERE/ORDER/LIMIT/OFFSET builder, the batch INSERT builder, and the thin `rc_query_exec`. |
| `tests/t_query.mettle` | 11 checks, `main` + exactly one `@test`, relayed through `rc_report`/`rc_summary`. |
| `reports/query.md` | this file. |

Not created: `expr.mettle`, `insert.mettle` (batch INSERT fits in the builder;
an `expr.mettle` would have been a second name for "append a term"). Nothing
outside the list above was touched — `core/`, `adapter/`, `changeset/`,
`migration/`, `docs/`, `tests/models.mettle`, `tests/harness.mettle`,
`tools/check.sh` and the other `t_*.mettle` files keep their 15:46–15:49
mtimes; my two sources are 15:54/15:56.

---

## 2. Exported seam, symbol by symbol

`reach/query/dialect.mettle`

| symbol | behaviour |
|---|---|
| `RcDialect { name, quote, placeholder, has_limit }` | value, not a vtable: `"dacor"`, `"\""`, `"?"`, `true`. |
| `rc_dialect_default() -> RcDialect` | the one dialect that ships. |
| `rc_dialect_name(d) -> string` | `"dacor"`. |
| `rc_dialect_ident(d, b, name) -> int32` | writes `"name"` into `b`, doubling an embedded `quote`. **Byte-identical to `rc_buf_ident` for the default dialect** (asserted on 4 names). |
| `rc_dialect_placeholder(d, b) -> int32` | writes `?`. |

`reach/query/builder.mettle`

| symbol | behaviour |
|---|---|
| `RC_JOIN_INNER = 0`, `RC_JOIN_LEFT = 1` | join flavours. |
| `RcQuery { meta, dial, buf, args, n_args, n_cap, kind, phase, tail, n_order, n_rows, n_cols, err }` | text + borrowed argv + clause state. `phase` is clause order, `tail` is the JOIN insertion point, `err` is a sticky construction failure. |
| `rc_query_select(m) -> RcQuery` | `SELECT <cols in RcMeta order> FROM "t"`. Validates the table (`rc_meta_check`); on failure returns an inert query (`err` set, `rc_query_sql == ""`, mutations/`exec` return the code). |
| `rc_query_insert_batch(m, n_rows) -> RcQuery` | one column list (AUTO PK omitted), `n_rows` placeholder groups. `n_rows <= 0`, zero emitted columns, or argv overflow → inert query with `RC_ERR_USAGE`. |
| `rc_query_push_arg(q, v) -> int32` | appends one **borrowed** cell to a batch INSERT; refuses once `n_args == n_rows * n_cols` and on any non-INSERT query. |
| `rc_query_where_eq(q, field, v) -> int32` | `"col" = ?` / `AND "col" = ?`; `v` NULL → `IS NULL` with no argument. |
| `rc_query_where_null(q, field)` | `"col" IS NULL`. |
| `rc_query_where_not_null(q, field)` | `"col" IS NOT NULL`. |
| `rc_query_where_in(q, field, vals, n)` | `"col" IN (?, ?, ?)`, n placeholders in array order; `n <= 0` or `vals == 0` → `RC_ERR_USAGE`, nothing appended. |
| `rc_query_order_by(q, field, asc)` | `ORDER BY "col" ASC` / `DESC`, repeats append `, "col2"`. |
| `rc_query_limit(q, n)` | `LIMIT <literal>` via `rc_buf_put_i64`; negative → `RC_ERR_USAGE`; `!dial.has_limit` → `RC_ERR_UNSUPPORTED`; a second LIMIT → `RC_ERR_USAGE`. |
| `rc_query_offset(q, n)` | `OFFSET <literal>`; negative → `RC_ERR_USAGE`; a second OFFSET → `RC_ERR_USAGE`. |
| `rc_query_join(q, target, local_field, foreign_field, kind)` | `JOIN` / `LEFT JOIN` with `"local"."col" = "foreign"."col"`; no placeholders; spliced after the FROM clause regardless of call order. |
| `rc_query_sql(q) -> string` | borrowed view into the text buffer; no copy, valid until the next mutation/free. |
| `rc_query_args(q) -> RcValue*` | borrowed argv cells. |
| `rc_query_n_args(q) -> int32` | placeholder count. |
| `rc_query_exec(q, a, out) -> int32` | one guarded `rc_adapter_exec`. |
| `rc_query_free(q)` | frees the text buffer and the argv array; **never** releases an `RcValue`. |

No other export exists in `reach/query/` (checked: `grep '^export '`). No new
status code: only `RC_OK`, `RC_ERR_{USAGE,NOMEM,RANGE,UNSUPPORTED}` from
`core/status` are returned.

---

## 3. Exact SQL emitted (pasted from the running binary)

Transcript from a throwaway program (built with the same compiler, run in the
project cwd, deleted afterwards — not part of the tree). `user_meta()` is the
8-column `users` table, `post_meta()` the 5-column `posts` table.

```
SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users"

SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" WHERE "email" = ? AND "age" IN (?, ?, ?) AND "role" = ?
  args=5

SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" WHERE "age" IS NULL
  args=0

SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" WHERE "age" IS NOT NULL
  args=0

SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" ORDER BY "name" DESC, "email" ASC LIMIT 10 OFFSET 5
  args=0

SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" LEFT JOIN "posts" ON "users"."id" = "posts"."user_id"
  args=0

SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" JOIN "posts" ON "users"."id" = "posts"."user_id" WHERE "email" = ?
  args=1          <-- built where-then-join; byte-identical to join-then-where

INSERT INTO "users" ("email", "name", "age", "active", "score", "created_at", "role") VALUES (?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?)
  args=0 (14 pushed by the caller)

INSERT INTO "users" ("email", "name", "age", "active", "score", "created_at", "role") VALUES (?, ?, ?, ?, ?, ?, ?)
  args=0 (7, for n_rows = 1)
```

Phase-1 parity: `rc_query_select(user_meta()) + where_eq(0, RcInt(42)) +
limit(1)` equals the literal `SELECT_SQL` from `tests/t_persist.mettle`:

```
SELECT "id", "email", "name", "age", "active", "score", "created_at", "role" FROM "users" WHERE "id" = ? LIMIT 1
```

No DDL is emitted by this phase (migration owns `CREATE TABLE`).

---

## 4. Decisions, and the test that pins each

1. **Values are always placeholders; identifiers always through the dialect.**
   `rc_dialect_ident` is the only spelling path for `m.table` / `f.column`;
   `rc_dialect_placeholder` is the only spelling path for `?`. No string
   concatenation of a table/column anywhere in `reach/query/`. Exceptions are
   deliberately literal: `LIMIT`/`OFFSET` numbers (`rc_buf_put_i64`) and the
   fixed SQL keywords.

2. **Three-valued logic.** `where_eq(field, RcNull)` does **not** bind and does
   **not** emit `= NULL`; it emits `"col" IS NULL` (delegating to the same code
   path as `where_null`, so the two are byte-identical by construction).
   `= NULL` is unproducible by the module. Pinned by
   `query: null never becomes = NULL`, which asserts the full text with `==`,
   asserts `n_args == 0`, and scans for the literal bytes `= NULL`.

3. **Argument order.** Rule, documented in the module header:

   > JOIN emits no placeholders, so `q->args` is exactly the order of the
   > `rc_query_*` calls that appended a placeholder, which is also the order of
   > the `?` characters in the text.

   So there is no "WHERE before JOIN or vice versa" ambiguity to guess at.
   `rc_query_join` is additionally **call-order independent**: the clause is
   spliced immediately after the FROM clause (an in-place three-reversal byte
   rotation, no scratch allocation), so `where → join` and `join → where`
   produce the *same* bytes. Pinned twice: `query: where args bind in order`
   (eq, IN(3), eq → exactly 5 args, exact text, exact values, and
   `rc_mem_arg_count == 5` after exec) and `query: join emits no placeholders`
   (both call orders compared with `==` to one literal, 1 arg, `arg_count == 0`
   for the join-only query).

4. **Identifiers are quoted, and routing through the dialect changed nothing.**
   `rc_dialect_ident(default, b, s) == rc_buf_ident(b, s)` byte-for-byte for
   `users`, `weird "name"`, `""`, `back\slash`; plus the exact escaping
   `"weird ""name"""`. (`query: dialect ident equals buf ident`.)

5. **IN lists and batch INSERT are frozen here**, for `relation/` preloading and
   bulk import: `"col" IN (?, ?, ?)` with `", "` separators and array order;
   `INSERT INTO "t" (cols) VALUES (?, ?), (?, ?)` with the AUTO primary key
   **always** omitted (batch rows share one column list — unlike
   `rc_persist_insert`, which consults a per-entity null bitmap). `n == 0` is
   `RC_ERR_USAGE` (`IN ()` is a syntax error, and "match nothing" is the
   caller's decision), `n == 1` still emits `IN (?)`.

6. **Clause order is enforced, not hoped for.** `phase` is monotonic:
   `where_*` after `ORDER BY`/`LIMIT`/`OFFSET` → `RC_ERR_USAGE`;
   `order_by` after `LIMIT` → `RC_ERR_USAGE`; `limit` twice → `RC_ERR_USAGE`;
   `offset` twice → `RC_ERR_USAGE`; `join` after `LIMIT`/`OFFSET` →
   `RC_ERR_USAGE`; `push_arg`/`where_*` on the wrong statement kind →
   `RC_ERR_USAGE`; field indices are bounds-checked on the right meta
   (including the join's *other* table). Every refusal is checked to leave the
   text and `rc_mem_call_count` unchanged (`query: misuse is refused`).

7. **Ownership: borrowed in, never released.** `q->args` holds borrowed
   `RcValue` cells; `rc_query_free` frees the argv array and the buf and never
   calls `rc_value_release`. Pinned by `query: args are borrowed`: a
   `malloc`'d text is bound with `where_eq`, the query is freed, and the text is
   compared (`"borrowed"`) and byte-read afterwards, then freed exactly once.

8. **No allocation per method call beyond buffer/argv growth.**
   `rc_buf_reserve` returns early while `len + extra <= cap`; the argv reserve
   returns early while `n_args + need <= n_cap`. Construction pre-sizes 256 text
   bytes and 8 cells, and `query: no growth after construction` builds an
   8-column SELECT + 3 predicates + ORDER BY + LIMIT + OFFSET and asserts
   `q.buf.cap` and `q.n_cap` **did not move** (capacity only changes on a
   realloc). Mutation was verified: shrinking `Q_TEXT_CAP` to 64 makes that
   check fail.

9. **Executing is the adapter's job.** `rc_query_exec` = arity/validity guard +
   one `rc_adapter_exec(a, rc_buf_text(&q->buf), q->args, q->n_args, out)`.
   No retry, no status translation, no state. Pinned by
   `query: exec is a thin call` (`RC_ERR_CONFLICT` injected with
   `rc_mem_fail_next` comes back unchanged, call count still 0).

### Documented non-goals / known limits (deliberate, stated in the header)

- A NULL element inside an `IN` list binds as a NULL placeholder (SQL: UNKNOWN).
  The builder does not rewrite it into `(... OR "col" IS NULL)`; that needs
  equality analysis this layer does not have.
- `OFFSET` without `LIMIT` is allowed and the caller's problem (dacor may not
  accept it); no dialect flag was invented for it.
- A self-join would produce the same table name on both sides
  (`"users"."id" = "users"."id"`) because `rc_query_join` has no alias
  parameter. Fine for Phase 4's `posts`/`users` preload; see §6.

---

## 5. Commands run and exact output lines

```
$ cd /home/nox/Projects/mettle/reach
$ ../raize/mettle-build/bin/mettle test tests/t_query.mettle
running 1 test (compile-time interpreter, no codegen)
test t_query ... ok

1 passed (tests/t_query.mettle)

$ tools/check.sh tests/t_query.mettle
== tests/t_query.mettle
  ok   t_query.interp
  ok   t_query.debug
  ok   t_query.debug.run
  ok   t_query.release
  ok   t_query.release.run

5 passed, 0 failed (logs in /tmp/reach-check)
```

Per-check lines from the debug binary (`/tmp/reach-check/t_query.debug.run.log`;
identical in the release binary):

```
  ok   query: select text matches persist
  ok   query: where args bind in order
  ok   query: null never becomes = NULL
  ok   query: order limit offset are literal
  ok   query: join emits no placeholders
  ok   query: batch insert rows
  ok   query: dialect ident equals buf ident
  ok   query: misuse is refused
  ok   query: args are borrowed
  ok   query: exec is a thin call
  ok   query: no growth after construction
11 checks passed
```

Phase-1 regression, same tree:

```
$ tools/check.sh
...
20 passed, 0 failed (logs in /tmp/reach-check)

$ tools/check.sh tests/t_value.mettle tests/t_meta.mettle tests/t_adapter.mettle tests/t_persist.mettle tests/t_query.mettle
...
25 passed, 0 failed (logs in /tmp/reach-check)
```

Interpreter, debug build, debug run, release build **and** release run are all
green; nothing was worked around for release (no `call_indirect` ICE: no
function-pointer field is ever folded — `rc_query_exec` calls only the frozen
guarded wrapper `rc_adapter_exec`).

Sanity that the assertions bite (temporary mutations, reverted):

| mutation | observed |
|---|---|
| skip the JOIN splice rotation | `test t_query ... FAILED (returned 5)` (join check) |
| let `where_eq(..., RcNull)` take the `= ?` path | `FAILED (returned 3)` (null check) |
| `Q_TEXT_CAP` 256 → 64 | `FAILED (returned 11)` (no-growth check) |

On-disk check: only `reach/query/{dialect,builder}.mettle` and
`tests/t_query.mettle` were written (plus this report); `grep '^export '`
returns exactly the 24 symbols of §2 and nothing else.

---

## 6. Seams I needed and could not have / things for the director

Nothing was blocked; no frozen file was edited. Notes for the next wave:

1. **`rc_query_select` / `rc_query_insert_batch` have no error out-parameter**
   (the directive's signatures are fixed), so a failed construction is carried
   in `RcQuery.err`: `rc_query_sql` returns `""`, every mutation returns the
   sticky code, and `rc_query_exec` returns it without touching the adapter.
   Callers that build a query and immediately exec cannot observe the error in
   between except through `rc_query_sql == ""`. If `relation/` wants an explicit
   check, the ask is `rc_query_error(q) -> int32`; **not** added, because it is
   not in the seam.
2. **No test-side `rc_text_dup`/`rc_value_clone`** in the frozen symbol list, so
   the borrow test builds its heap string with `malloc` + `str_from_bytes`
   (language builtin) instead. No seam change needed — just noting that the
   obvious helper was out of scope.
3. **For `relation/` (Phase 4):** `where_in` + `where_eq` + `join` are enough
   for a non-N+1 preload of a `posts` → `users` association. Two gaps to know
   about *before* writing the directive: no SELECT-column projection (the
   builder always emits every column) and no table alias (self-joins are
   ambiguous). Neither is needed for the one-level preload the docs describe.
4. **`RcDialect` ownership** is resolved as the directive says: it lives in
   `reach/query/dialect.mettle`, `adapter/` was not touched, and there is one
   definition in the tree.
5. **`core/persist` is untouched** and remains the Phase-1 straw man; Phase 2
   supersedes its SELECT text (proved by the `SELECT_SQL` parity check), it does
   not delete it.

---

## 7. Test inventory (`tests/t_query.mettle`, 11 checks, 1 `@test`)

| check | what it pins |
|---|---|
| `query: select text matches persist` | exact SELECT prefix, exact `SELECT_SQL` parity after where_eq(pk)+limit(1), 1 arg, dialect name |
| `query: where args bind in order` | eq + IN(3) + eq → exact text, 5 args, exact values, adapter sees the same 5 in the same order |
| `query: null never becomes = NULL` | `IS NULL` for `RcNull`, `IS NOT NULL`, no argument bound, `= NULL` absent, NULL term followed by a placeholder term shifts no slot |
| `query: order limit offset are literal` | `ORDER BY "email" ASC LIMIT 10 OFFSET 5`, repeated ORDER BY, negative/duplicate/late refusals |
| `query: join emits no placeholders` | exact LEFT/INNER text, 0 args, both call orders byte-identical, refusals (kind, both field ranges, after LIMIT) |
| `query: batch insert rows` | exact 2-row text, 14 args in order after exec, 15th push refused, half-filled and `n_rows == 0` never reach the store, `push_arg` on SELECT refused |
| `query: dialect ident equals buf ident` | byte equality on 4 names + exact escaping + placeholder |
| `query: misuse is refused` | empty/negative/zero-array IN, out-of-range fields, where/order/join after LIMIT, kind mismatches, invalid table (`Doc`) — each `RC_ERR_USAGE`/`RC_ERR_UNSUPPORTED` with text and call count unchanged |
| `query: args are borrowed` | heap text survives `rc_query_free`, freed exactly once afterwards |
| `query: exec is a thin call` | injected `CONFLICT` passes through, call count 0, then a real call records 1 arg |
| `query: no growth after construction` | `buf.cap` and `n_cap` unchanged while building a typical statement |
