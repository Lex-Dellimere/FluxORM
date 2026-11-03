# Phase 1 — core + adapter

Implemented and green. This file is the implementation guide: the decisions,
the exact data structures, and the five tests that pin them.

```
$ tools/check.sh tests/t_value.mettle tests/t_meta.mettle \
                 tests/t_adapter.mettle tests/t_persist.mettle
20 passed, 0 failed     # 4 files x debug build/run + release build/run
                        # (plus mbuild check + mbuild test for the whole project)
```

These are the Phase-1 numbers. The full gate, with every phase and the
integration test, is `42 passed, 0 failed`.

---

## 1. Reflection: metadata is generated, not written

Mettle reflects at compile time only. `typeof(T).fields` gives, per field:
`name`, `offset`, `type.kind`, `type.size`, `type.align`, `type.name`, `index`,
and leaves nothing at run time. There is no `reflect` call to make, no
descriptor blob, no build script.

That makes the registry a *generated static table* (`tests/models.mettle` is
the template):

```mettle
fn user_fields(out: RcField*) -> int32 {
  var i: int32 = 0;
  comptime for f in typeof(User).fields {
    out[i].name = f.name;
    out[i].column = f.name;
    out[i].kind = f.type.kind;
    out[i].ty = rc_kind_type(f.type.kind);
    out[i].offset = (int32)f.offset;
    out[i].size = (int32)f.type.size;
    out[i].flags = 0;
    i = i + 1;
  }
  return i;
}
```

Two details that cost time:

- **Do not capture a module global in the `comptime` body.** On head
  `8f14c612`, a module-scope `var` referenced from inside a `comptime for`
  that lives in an *imported* module fails with `Undefined variable` (the
  expansion resolves in a scope that does not see the global). Passing the
  destination array as a parameter works and is clearer. Recorded here because
  it is not in any doc.
- **`f.type.kind` is the builtin `Kind` enum**, not a number:
  `Kind.Bool`, `Kind.Int32`, `Kind.Float64`, `Kind.String`, `Kind.Enum`,
  `Kind.Slice`, … Its numeric value happens to be a fixed table
  (`Bool = 1, Int32 = 4, Int64 = 5, Float64 = 11, String = 14, Slice = 17,
  Enum = 19`), but store the enum, not the number. `rc_kind_type` is the only
  place that translates it.

### Data structures

```mettle
struct RcField {
  name: string;    column: string;
  kind: Kind;      ty: int32;      // wire type
  offset: int32;   size: int32;    // compiler-reported
  flags: int32;                    // RC_F_*
}

struct RcMeta {
  table: string;   name: string;   size: int32;
  fields: RcField*; n_fields: int32; pk: int32;
}

struct RcColumn { index: int32; column: string; ty: int32; flags: int32; }
```

Access uses the reported offset and a *typed* load, so the compiler's layout is
used, not assumed:

```mettle
var at: uint8* = (uint8*)model + (int64)f.offset;
switch (f.kind) {
  case Kind.Int64: { var p: int64* = (int64*)at; *out = RcInt(*p); return RC_OK; }
  case Kind.String: { var p: string* = (string*)at; *out = RcText(*p); return RC_OK; }
  ...
}
```

`rc_meta_set` is the mirror image and adds the three checks that belong here
and nowhere else: arm/kind match (`RC_ERR_CAST`), narrowing range
(`RC_ERR_RANGE`), NOT NULL (`RC_ERR_CONSTRAINT`).

### Startup validation

`rc_meta_finalize` applies the override table, resolves `pk`, then
`rc_meta_check` refuses: duplicate column names, zero/two primary keys, a PK
without NOT NULL, AUTO on a non-integer or a non-PK, a field outside the struct
(`offset + size > sizeof(T)`), more than 64 fields, and any field type the wire
cannot carry (`RC_T_UNSUPPORTED`). Every one of these is a test
(`t_meta: invalid tables are refused`).

---

## 2. The value layer, and the wire mapping

```mettle
enum RcValue {
  RcNull, RcInt(int64), RcUint(uint64), RcFloat(float64),
  RcBool(bool), RcText(string), RcBlob(RcBytes), RcTime(int64)
}
```

One arm per wire family, and the casts are **strict**: no text→number, no
float→int, no int→bool. Coercion is `changeset/`'s job in Phase 3. The only
widening allowed is lossless (`RcInt`→`float64` up to 2^53, `RcUint`→`int64`
up to 2^63-1, bool→0/1), and lossy cases return `RC_ERR_RANGE` rather than a
rounded value.

Mapping decisions, in one place (`rc_kind_type` + the override table):

| Mettle field | `ty` | wire | note |
|---|---|---|---|
| `int8/16/32/64` | `RC_T_I64` | INTEGER | widened; range checked on write |
| `uint8/16/32` | `RC_T_I64` | INTEGER | safe, range checked |
| `uint64` | `RC_T_U64` | BLOB / refused | no signed 64-bit INTEGER arm fits |
| `float32/64` | `RC_T_F64` | REAL | float32 checked to its range first |
| `bool` | `RC_T_BOOL` | INTEGER 0/1 | dacor has no BOOL |
| `string` | `RC_T_TEXT` | TEXT | UTF-8; borrowed view |
| plain `enum` | `RC_T_I64` | INTEGER | never the name |
| `int64` + `RC_F_TIMESTAMP` | `RC_T_TIME` | INTEGER micros UTC | the override is what makes it a time |
| slice/struct/pointer/tagged enum | `RC_T_UNSUPPORTED` | — | refused at startup |

`RcTime` is not cosmetic: `rc_meta_get` returns `RcTime` for a TIMESTAMP column
because the metadata said so, which is how an adapter picks the right encoding
without seeing the schema.

---

## 3. NULL: a bitmap beside the struct

Mettle has no null scalar, and `Option<T>` in a field is a tagged enum the wire
cannot carry. So:

```mettle
struct RcEntity { meta: RcMeta; model: rawptr; nulls: uint64; state: int32; }
```

- `set(i, RcNull)` on a nullable field clears the storage **and** sets bit `i`.
- `set(i, v)` clears bit `i`.
- `get(i)` returns `RcNull` when the bit is set, regardless of the zeroed
  storage.
- `rc_entity_new` sets the bit for an AUTO primary key: absent is a null, and
  "not yet assigned" must not be confused with `id = 0`.
- 64 fields is the limit; `rc_meta_check` refuses more.

This is the reason `WHERE id IS NULL` is generatable at all, and it is the
pattern Phase 3 copies for dirty tracking.

---

## 4. Ownership: borrowed in, owned out

`string` is `{chars, length}` — a view. The rule is enforced by the API shape,
not by convention:

- **In**: an `RcValue` argument is borrowed; the caller keeps the buffer alive.
  `rc_value_clone` is the explicit "I need a copy".
- **Out**: every cell in an `RcResult` is owned by that result;
  `rc_result_free` releases text and blobs.
- **Model**: a loaded model's `string` fields borrow the `RcResult` that
  produced them, so `rc_persist_load` hands that result back through `owner`:

```mettle
var owner: RcResult;
rc_persist_load(a, m, RcInt(42), (rawptr)&u, &nulls, &owner);
// ... use u ...
rc_result_free(&owner);   // u's strings die here
```

That is a deliberate Phase-1 limitation with a documented end: Phase 2's
session arena becomes the owner and the rule becomes "a model borrows its
session". The test for it (`t_value: clone owns text and blob`) frees the
source and overwrites the heap block, so a shallow clone fails deterministically
instead of "sometimes".

---

## 5. The adapter seam

```mettle
struct RcAdapter {
  name: string; ud: rawptr;
  open:   fn(rawptr, string) -> int32;
  close:  fn(rawptr) -> int32;
  exec:   fn(rawptr, string, RcValue*, int32, RcResult*) -> int32;
  begin:  fn(rawptr, int32) -> int32;
  commit: fn(rawptr) -> int32;
  rollback: fn(rawptr) -> int32;
  ping:   fn(rawptr) -> int32;
}
```

Three properties, each with a test:

1. **Materialising.** `exec` runs the statement to completion. dacor cursors pin
   pager frames (`dacor/PHASE1.md §2.4`); a cursor that escapes can exhaust the
   frame table and turn every later page alloc into `DK_ERR_BUSY`. No cursor
   exists above this line.
2. **Guarded.** Every entry is a function pointer that may be `0`; the wrapper
   returns `RC_ERR_UNSUPPORTED` instead of calling through null. This is how a
   phase-gated capability behaves before the driver implements it.
3. **Total on failure.** A failed call records nothing and mutates nothing.
   `rc_mem_fail_next` injects a code *before* the record step so the test can
   prove it.

`adapter/mem.mettle` is the executable specification (records sql + args,
replays scripted rows). `adapter/dacor.mettle` is gated: every entry returns
`RC_ERR_UNSUPPORTED`, `rc_dacor_supported()` is `false`, and the file lists the
exact dacor calls the real bridge will make. Nothing can accidentally believe
in a store that does not exist yet.

### Head compiler bug, and the workaround

`--release` only:

```
Code generation error: Direct object backend cannot compile function 'main'
(call_indirect_unsupported)   Mettle internal compiler error
```

Minimal repro: a **local** struct whose function-pointer field is `0`, passed
to a function that calls through that field. The optimizer folds the known-null
pointer and the backend cannot lower the indirect call. Debug is fine, which is
why release is mandatory here.

Workaround: build the value behind an opaque call —
`@noinline export fn rc_adapter_empty() -> RcAdapter`. `@noinline` must be on
the same line as `fn` (a newline between decorator and declaration is a parse
error, and the diagnostic points at a confusing location).

---

## 6. The five Phase-1 tests

Run with `tools/check.sh`; each also runs under `mettle test` (interpreter) and
in the built binary. The check names below are the exact output lines.

### T1 `value: clone owns text and blob`
Duplicates `"hello"`, clones it into an `RcValue`, frees the original, then
`malloc`s the same size and overwrites it with `'x'`. The clone must still read
`"hello"`. Then: empty text clones and releases safely; a 4-byte blob
round-trips and compares byte-wise. **Pins**: borrowed-view semantics, no
use-after-free in the value layer, blob equality.

### T2 `value: strict casts and ranges`
Text→i64 is `CAST`; float→i64 is `CAST`; `2^63` as u64→i64 is `RANGE`;
`2^53+1` int→f64 is `RANGE`; int→bool is `CAST`; NULL→anything is `CAST`.
**Pins**: the no-implicit-coercion rule that keeps corruption out of the
database, and the exact boundaries (2^63, 2^53).

### T3 `meta: registry generated from typeof`
Field order, kinds, wire types, flags, offsets strictly increasing, each field
inside `sizeof(T)`, `string` size 16, `bool` size 1, pk index, `find` by name,
`find` miss = -1, a second model (5 fields) generated by the same code.
**Pins**: the reflection story — if the compiler's offsets move, this fails
before anything is written to disk.

### T4 `meta: invalid tables are refused`
Duplicate column, two PKs, AUTO without PK, PK without NOT NULL, AUTO on TEXT,
a field running past the struct end, `RC_T_UNSUPPORTED`, zero fields, and the
reported bad-field index. Plus the `Doc` model with a `uint8[]` field:
`rc_meta_check` = `RC_ERR_UNSUPPORTED`. **Pins**: every metadata mistake is a
startup failure, not a query-time surprise.

### T5 `adapter: failure leaves no state`
An argument-count mismatch never reaches the driver (call count unchanged); an
injected `CONFLICT` fails the call and leaves the previous sql/args/call-count
untouched; the failure is one-shot; a null vtable is `USAGE`, not a crash; an
empty vtable is `UNSUPPORTED`; transaction states refuse commit-without-begin,
double begin, and close-inside-transaction.

### T5b `persist: conflict keeps entity state` (integration)
Real model + generated metadata + the write path + the adapter: exact
`INSERT` text with the AUTO key omitted, 7 arguments in declaration order with
NULL preserved, `last_id` adopted into the model, state `NEW → CLEAN`.
Then a conflict: `CONFLICT` returned, state still `NEW`, still keyless, the
in-memory row unchanged, and a retry with `last_id = 77` succeeds. Finally the
`Doc` table never reaches the store (`UNSUPPORTED`, call count unchanged).
**Pins**: no partial mutation on failure — the bug class that makes an ORM
retry into a duplicate row.

---

## 7. What is deliberately not here

- No identity map, no session, no pool (Phase 2/4; `RcSession` is reserved in
  the design and absent in code — do not let a worker invent it).
- No UPDATE. `changeset/` decides what changed; emitting a partial SET list
  without a dirty mask is how ORMs overwrite concurrent writes.
- No prepared-statement cache: `prepare/reset/finalize` are named in
  `adapter/dacor.mettle` as the future vtable extension.
- No `--safe` support (it traps on `std/arena`/`std/strbuf`, which we do not
  use; `malloc`/`new` are fine under `--safe` if that becomes a requirement).
