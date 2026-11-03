# Cross-phase acceptance (as built)

`tools/check.sh` runs every phase file alone. That is necessary and not
sufficient: phases pass alone and fail together at the seam. This file is the
**as-built** script for `tests/t_integration.mettle` — what it actually
asserts, with the real API, and the divergences from the original plan.

```
$ tools/check.sh tests/t_integration.mettle
  ok   mbuild.check
  ok   mbuild.test
  ok   t_integration.debug.build / .debug.run / .release.build / .release.run
  ok   mbuild.build / demo.debug.run / mbuild.build.release / demo.release.run

$ tools/check.sh            # everything
42 passed, 0 failed
```

```
$ /tmp/reach-check/t_integration.release
  ok   integration: migration creates the ledger and the schema
  ok   integration: insert binds args and adopts the key
  ok   integration: query builds the statement and binds in order
  ok   integration: changeset yields a two-field update
  ok   integration: relation preloads in one exec for three owners
  ok   integration: delete and a conflict leave no state
  ok   integration: the failure matrix never reaches the store
7 checks passed
```

Every statement is compared with `==` against a literal. The only substring
check is negative: it proves `= NULL` never appears in the generated text
(an absence `==` cannot state).

## Scenario, and the real calls

### 1. Schema (`migration/`)

```
rc_migration_run(adapter, set) emits, in order:
  CREATE TABLE IF NOT EXISTS "_reach_migrations" ("version" INTEGER PRIMARY KEY, "name" TEXT NOT NULL, "applied_at" INTEGER NOT NULL)
  SELECT "version" FROM "_reach_migrations" ORDER BY "version" ASC
  per missing version: BEGIN, CREATE TABLE …, INSERT INTO "_reach_migrations" (…) VALUES (?, ?, ?), COMMIT
```

`rc_migration_create_table(m, RcBuf*) -> int32` fills a buffer; that is why the
test compares buffer text. A second run issues no `CREATE TABLE` for an applied
version (the ledger is read first), and a failing migration rolls its ledger row
back — proven by the transaction counters, not by a comment.

### 2. Insert + auto key (`core/persist` + `adapter/mem`)

AUTO key omitted when its null bit is set; NULL binds as `RcNull`;
`last_id` is adopted into the model; state `NEW → CLEAN`. An explicit key *is*
written (`INSERT_KEYED_SQL`, 8 args).

### 3. Query (`query/builder`)

```
rc_query_select(m)
rc_query_where_in(q, age_index, vals, n)      // no where_gt in this builder
rc_query_order_by(q, name_index, true)
rc_query_limit(q, 10)

SELECT "id", … , "role" FROM "users" WHERE "age" IN (?, ?) ORDER BY "name" ASC LIMIT 10
SELECT "id", … , "role" FROM "users" WHERE "age" IS NULL
```

Field **indexes**, not names. `where_eq(field, RcNull)` does not emit
`= NULL`: NULL is `IS NULL`, a separate call, because three-valued logic is a
property of the predicate constructor, not of the value.

### 4. Changeset (`changeset/`)

`RcChangeset` carries a `changes: uint64` mask plus a value per field. Putting
an identical value sets **no** bit (`rc_value_same`). Two changed fields ⇒
`n_dirty == 2`, and `apply` writes exactly those through `rc_entity_set`, so
range and NOT NULL checks stay in metadata.

There is deliberately **no UPDATE emitter** yet: an `UPDATE … SET` built from
`n_dirty` is the next phase's job, and asserting the mask *is* the assertion
that such an emitter would be correct.

### 5. Relations (`relation/`)

Three owners, one statement:

```
SELECT "id", "user_id", "title", "body", "published_at" FROM "posts" WHERE "user_id" IN (?, ?)
out.n_execs == 1, arg count 2 (NULL owner keys are skipped before the IN list)
```

Belongs-to in one statement keyed by PK; THROUGH is two statements (mapping
rows, then targets by PK) and is still O(1) in owner count. A repeated preload
is a second statement by design — there is no session and no cache yet.

### 6. Delete + conflict

`DELETE FROM "users" WHERE "id" = ?`, one arg, state `DELETED`, second delete
refused. An injected `RC_ERR_CONFLICT` on insert leaves the entity `NEW`,
keyless and unchanged in memory; the retry succeeds.

### 7. Failure matrix

| case | assertion |
|---|---|
| NOT NULL field set to NULL | `RC_ERR_CONSTRAINT` in `rc_entity_set` **and** `rc_changeset_put` |
| unknown changeset field | `RC_ERR_USAGE`, `error_field() == -1`, reason `"unknown field name"` |
| insert a `Doc` (slice field) | `RC_ERR_UNSUPPORTED`, call count unchanged |
| relation key type mismatch | `RC_ERR_CAST` from `rc_relation_check`, before any exec |
| migration duplicate version | refused before any exec |
| empty change set | `n_dirty == 0`; `apply` writes nothing, nothing reaches the store |

## Divergences from the original plan (code won)

Recorded at the assertion that shows each one, and here:

- `rc_migration_create_table` takes `(RcMeta, RcBuf*)`; DDL is
  `CREATE TABLE IF NOT EXISTS`.
- The ledger SELECT reads one column, `ORDER BY "version" ASC`.
- No `rc_query_where_gt`; predicates are `eq / null / not_null / in`.
- `adapter/mem` replays rows and never evaluates SQL, so "the NULL row is not
  in the result" is asserted where the logic lives — the builder's `IS NULL`
  and the entity's null bitmap — not in a result set.
- No UPDATE emitter and no session cache (open seams, not oversights).
- Relation type mismatch is `RC_ERR_CAST`, not `RC_ERR_UNSUPPORTED`.

## Compiler finding (reported, worked around at the call site)

A `@test` that calls all seven `check_*` functions **directly** segfaults head
`8f14c612` in IR lowering (`Function: t_integration`). Small groups are fine.
The file therefore keeps a module-global `(fn() -> int32)[7]` table and walks
it from both `main()` and `@test`; the function-pointer cell keeps each check
its own IR unit. All three runners (interpreter, debug, release) are green.
The comment sits at the table, not in a commit message.
