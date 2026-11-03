# Architecture critique

The proposed tree — `core/ query/ changeset/ migration/ relation/ adapter/` —
is the right *decomposition* and the right *build order*. What is missing is
not a seventh feature; it is the vertical slice that owns a connection, a
transaction and a row's lifetime. Everything below is either that slice or a
consequence of Mettle and dacor's actual constraints.

---

## 1. Missing lifecycle

### 1.1 There is no session / unit of work
`core/` is metadata. `adapter/` is a vtable. Nothing owns "this transaction,
this connection, these loaded rows". Every ORM has this object (Repo, client,
session); the tree has no home for it, so it will appear three times — once in
each of query/, changeset/ and migration/ — and they will disagree.

Add `core/session.mettle`:

```
RcSession { adapter, tx_depth, owner_arena, identity_map, hooks }
```

It owns: checkout, begin/commit/rollback, the statement cache, the arena that
loaded text points into, and the hook list. It is *not* a global; a caller
passes it. Phase 1 reserves the struct and the transaction state machine; the
arena and identity map land with Phase 2/4.

Evidence this is not theoretical: the Phase-1 loader cannot copy text because
a plain Mettle struct has nowhere to own it, so `rc_persist_load` hands the
caller the `RcResult` its strings are borrowed from (`docs/03-phase1.md §5`).
That owner has a name — the session arena — and it should exist before there
are ten call sites instead of one.

### 1.2 No identity map
Load the same row twice and you get two structs. Update both and the second
write wins silently; there is no stale-write detection. dacor gives you
`write_version` in the meta page (PHASE1 §4) — that is the optimistic-lock
token, and it is useless without one in-memory instance per key.

A hand-rolled open-addressing table (`int64 key -> rawptr`), the same shape as
dacor's own pager frame index, is the implementation. `std/collections`
`HashMap<K,V>` is not usable here: generics through pointers are rejected on
this compiler, and the map stores `rawptr`.

### 1.3 Dirty tracking is one bit too coarse
`RcEntity.state` answers "does this row differ from the store". UPDATE needs
"which fields", and the null bitmap already establishes the pattern: one
`uint64` per 64 fields, in Phase 3. The 64-field ceiling is a real limit —
document it, and make `rc_meta_check` refuse `n_fields > 64` (it does).

### 1.4 No hooks, and hooks belong in exactly one place
`before_insert`, `after_load`, `before_delete`, plus the two the tree cannot
express: auto-timestamps and soft delete. These are not changeset concerns (a
changeset runs before persistence exists) and not query concerns. Put an
`RcHooks` list on the session and call it from the single persistence choke
point; otherwise `created_at` is set in six places and wrong in two.

Consequence for this ORM: `RC_F_TIMESTAMP` and `RC_F_READ_ONLY` exist in
metadata now, but nothing fills them yet. That is deliberate — the flags are
the seam for the hook pass, and they are validated at startup.

### 1.5 No batch or preload path
`INSERT ... VALUES (?, ?), (?, ?)` and `WHERE fk IN (?, ?, ?)` are what keep
importer and association code from being N+1. `relation/` cannot implement
preloading alone: it needs query/ to emit an IN list and the adapter to accept
many rows at once. Freeze that in Phase 2, not Phase 4.

### 1.6 No statement cache / prepared-statement lifecycle
dacor prepares, binds, steps, resets, finalizes. Rebuilding statement text per
call is correct first and slow second, and the *cache key* (sql + dialect +
schema version) is a design decision that belongs to the session, not to the
text builder. Reserve `prepare`/`reset`/`finalize` on the vtable now as
optional entries (zero pointer = unsupported), so adding them is not a
signature change.

### 1.7 Errors carry no context
`int32` tells you `CONFLICT`, not which constraint or column. dacor's
`DkStatus { code, arg }` (PHASE1 §5.1) has the same shape and the same
weakness. Add `RcDiagnostic { code; sql; column; arg }` that the adapter fills
best-effort; the ORM can then map a unique violation onto the offending field
instead of printing a number.

### 1.8 No schema introspection
`migration/` diffs "what the models say" against "what the store says". The
store side must come from dacor's catalog (`dk_master` as a normal b-tree table
in its design), not from parsing DDL text. Until the catalog is queryable, the
honest Phase-5 scope is: up-only migrations recorded in a `_reach_migrations`
table, no down, no auto-diff.

### 1.9 Casting policy has no owner
Three places can coerce: adapter (wire → RcValue), metadata (RcValue → field),
changeset (user input → RcValue). If all three are permissive, type bugs become
data corruption. The split this project uses:

| Layer | May do | May not do |
|---|---|---|
| adapter | produce the canonical arm for the column's declared type | guess from bytes |
| `core/meta` | narrow with a range check, refuse on mismatch | coerce text to number |
| `changeset` | parse and cast user input explicitly | bypass `core/meta`'s range check |

---

## 2. Connection pooling, for an embedded engine

A connection here is not a socket. It is a `DkPager*`: a file handle, an
exclusive file lock, and a frame cache of `n_frames × 4096` bytes
(PHASE1 §5.9). That changes the whole design:

1. **Capacity is memory, not file descriptors.** 256 frames = 1 MiB per
   handle. Eight read handles plus one writer is 9 MiB before a query runs.
   Make it a fixed, documented number (`RC_DACOR_N_FRAMES`), not a growth
   policy.
2. **There is exactly one writer.** dacor Phase 1 evicts by writing dirty
   pages with no journal (PHASE1 §6), so two concurrent writers are corruption,
   not a lock wait. The pool is N read-only handles + one writer handle, or a
   process-wide write mutex. Do not offer "concurrent write" as a setting.
3. **Acquire must be bounded.** Mettle here has mutexes and 32-bit seq-cst
   atomics, and no condition variables in the documented surface. A blocking
   acquire on the single writer, from a thread that already holds it, is a
   deadlock with no timeout. Acquire is try-acquire with a spin budget, then
   `RC_ERR_BUSY`; the caller retries or fails the request.
4. **Never pool a pinned cursor.** A leaked dacor cursor pins frames; when the
   frame table is exhausted every later `alloc` returns `DK_ERR_BUSY` and the
   handle is effectively dead while looking healthy. This is why `exec`
   materialises rows (`adapter.mettle`, header comment) and why no statement
   object escapes a unit of work.
5. **Checkout scope = transaction scope.** Hooks run inside the transaction,
   with the same connection. A hook that acquires a second connection to the
   same file is the classic pool deadlock; the session must refuse nested
   checkout outright.
6. **A corrupt handle is destroyed, not returned.** `DK_ERR_CORRUPT` means the
   pager's cache can no longer be trusted. `close` it, drop it from the pool,
   and surface the error; recycling it turns one corrupt page into a stream of
   them.
7. **Threads are joined, never detached.** `thread_close` on a running thread
   leaks 1 MiB (project notes). A pool that grows threads that are not joined
   leaks the pool.

Implementation note: none of this is in Phase 1. `rc_adapter_empty()` and the
gated dacor bridge exist so the pool has somewhere to land without changing
`RcAdapter`.

---

## 3. Impedance mismatches

### 3.1 Type system
dacor has no BOOL, no DATE/TIME, no DECIMAL, no UUID, no JSON. Every one of
those is a mapping decision that must be made once, in metadata, not per call
site:

| Mettle | wire | why |
|---|---|---|
| `bool` | INTEGER 0/1 | dacor has no BOOL; decode back through the declared type |
| `int64` + `RC_F_TIMESTAMP` | INTEGER unix micros, UTC | sortable, arithmetic works, no timezone in the store |
| money | INTEGER minor units | `float64` cannot represent 0.10; never store money in REAL |
| `enum` (plain) | INTEGER | it already is an integer; do not store the name |
| `uint64` > 2^63-1 | none | no INTEGER arm fits; refuse at `rc_meta_check` unless mapped to BLOB |
| tagged enum / slice / struct / pointer | none | no owned representation; refused at startup |
| `string` | TEXT | UTF-8 bytes, length-prefixed by the store |

`RC_T_*` is the canonical vocabulary; `rc_kind_type` is the only place that
knows the compiler's `Kind` enum. When dacor's `types/` lands, only
`rc_dacor_affinity` changes.

### 3.2 Layout is the compiler's
Never `memcpy` a model to a row. Offsets come from `typeof(T).fields` at
compile time; the access functions do a *typed* load/store at that offset, so
the compiler's layout is used, not assumed. This also means a model must be a
plain struct of scalars, `string`, and plain enums — enforced at startup by
`rc_meta_check`, not by a comment.

### 3.3 NULL
Mettle has no null for a scalar, and `Option<T>` in a field is a
`TaggedEnum` — which the wire cannot carry. Nullability therefore lives beside
the struct as a bitmap (`RcEntity.nulls`). Two consequences that must be
written down because they are surprising:

- `set(f, RcNull)` clears the storage **and** sets the bit; `get` returns
  `RcNull` from the bit, so a zero value and a NULL are distinguishable.
- SQL generation must derive `IS NULL` from the bitmap, never from `== 0`.

### 3.4 Ownership
`string` is a 16-byte borrowed view. Three rules, and the API enforces them:

1. A value handed *to* the ORM is borrowed; the caller keeps the buffer alive.
2. A result handed *back* is owned; `rc_result_free` releases it.
3. A model loaded from a result borrows that result; the result must outlive
   the model. Phase 2 replaces this with a session arena, at which point the
   rule becomes "the model borrows the session".

### 3.5 No exceptions
Every call returns `int32`. A transaction body written as straight-line code
with three early returns needs three rollbacks; `defer` cannot know whether the
function is returning an error. The fix is structural — `rc_uow_run(session,
body, ud)` with one return path — and belongs in the session, not in each
caller.

### 3.6 dacor's SQL surface does not exist yet
PHASE1 is a pager. `sql/` and `api/` come later. Building an ORM against
guessed SQL is the largest schedule risk in this project, so the guessed part
is isolated:

- `adapter/dacor.mettle` returns `RC_ERR_UNSUPPORTED` from every entry point
  and `rc_dacor_supported()` is `false`. Nothing can accidentally "succeed".
- The SQL subset the ORM emits is small and asserted verbatim in tests
  (`INSERT INTO "t" (cols) VALUES (?, ...)`, `SELECT cols FROM "t" WHERE "pk"
  = ? LIMIT 1`, `DELETE FROM "t" WHERE "pk" = ?`).
- Quoting is `rc_buf_ident` (double quotes, embedded quote doubled) and
  arguments are always placeholders. When a `RcDialect` lands it replaces those
  three strings in one file.

### 3.7 Ordering and collation belong to dacor
dacor's b-tree compares order-preserving byte strings; SQL `ORDER BY` and
comparison semantics are its `types/` module. The ORM must not sort rows in
memory and call it ordering, and must not invent an index key encoding. It
emits DDL and trusts the store — which also means Phase 2's `ORDER BY` is
mostly string building, not logic.

---

## 4. What the tree should become (final layout)

```
core/       value status meta entity buf persist session hooks arena
adapter/    adapter mem dacor dialect
query/      builder expr order join preload
changeset/  cast validate dirty
relation/   has_many belongs_to many_to_many
migration/  ddl version runner
```

Two additions to the proposed tree are load-bearing now: `session` (owns the
unit of work) and `dialect` (owns the SQL text, so a dialect change is one
file). `arena` is the Phase-2 answer to §3.4. Everything else is where the
proposal put it.
