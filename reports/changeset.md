# Phase 3 — reach/changeset


> Paths below predate the mbuild restructure: `reach/<mod>/` is now
> `src/<mod>/`, and imports are file-relative. The behaviour and symbol names
> are unchanged.
Status: **implemented and green** in the compile-time interpreter, debug build,
debug run, release build and release run. Phase 1 is untouched and still green.

Contract: `reports/directives/changeset.md`. Seams relied on:
`docs/02-seams.md`. Nothing outside `reach/changeset/` and
`tests/t_changeset.mettle` was edited; `core/` was not changed and no seam
change was needed.

---

## 1. Files added

| File | Lines | What |
|---|---|---|
| `reach/changeset/cast.mettle` | 286 | text → `RcValue` for a field's declared wire type; the arm/fit test; `RC_CS_MAX_TEXT` |
| `reach/changeset/changeset.mettle` | 404 | `RcChangeset`, the 64-bit dirty mask, baseline comparison, validation, `apply` |
| `tests/t_changeset.mettle` | 627 | 8 `check_*` functions, `main`, one `@test fn t_changeset()` |
| `reports/changeset.md` | — | this report |

No SQL and no DDL is emitted by this phase (directive §10): the deliverable is
the mask and the values that a later `UPDATE ... SET` directive consumes. There
is therefore no statement text to paste, and the test asserts none.

## 2. Exported seam, symbol by symbol

`reach/changeset/cast.mettle`:

```
export const RC_CS_MAX_TEXT: int64 = 1048576;
export fn rc_cast_fits(f: RcField, v: RcValue) -> int32;
export fn rc_cast_text(f: RcField, s: string, out: RcValue*, why: string*) -> int32;
```

`reach/changeset/changeset.mettle`:

```
export struct RcChangeset {
  meta: RcMeta; changes: uint64; values: RcValue*; n_values: int32;
  base: rawptr; base_nulls: uint64;
  err_field: int32; err_code: int32; err_reason: string;
}

export fn rc_changeset_new(m: RcMeta) -> RcChangeset;
export fn rc_changeset_free(cs: RcChangeset*);
export fn rc_changeset_reset(cs: RcChangeset*) -> int32;
export fn rc_changeset_bind(cs: RcChangeset*, model: rawptr, nulls: uint64) -> int32;
export fn rc_changeset_put(cs: RcChangeset*, field: int32, v: RcValue) -> int32;
export fn rc_changeset_put_name(cs: RcChangeset*, name: string, v: RcValue) -> int32;
export fn rc_changeset_put_text(cs: RcChangeset*, field: int32, s: string) -> int32;
export fn rc_changeset_put_null(cs: RcChangeset*, field: int32) -> int32;
export fn rc_changeset_has(cs: RcChangeset*, field: int32) -> bool;
export fn rc_changeset_n_dirty(cs: RcChangeset*) -> int32;
export fn rc_changeset_apply(cs: RcChangeset*, e: RcEntity*) -> int32;
export fn rc_changeset_valid(cs: RcChangeset*) -> bool;
export fn rc_changeset_error_field(cs: RcChangeset*) -> int32;
export fn rc_changeset_error_code(cs: RcChangeset*) -> int32;
export fn rc_changeset_error_reason(cs: RcChangeset*) -> string;
```

That is the whole surface and it matches the directive name for name. There is
no `put_text_i64`/`_f64`/`_bool` family: `rc_changeset_put_text` dispatches on
the field's declared `ty`, which is the only thing that knows what the text is
supposed to be. No new status code was invented; every refusal is one of
`RC_ERR_{CAST,RANGE,CONSTRAINT,USAGE,UNSUPPORTED,NOMEM}`. `RC_CS_MAX_TEXT` is a
policy constant, not a code.

Two extra exported names exist because Mettle has no cross-module visibility
without `export`: `rc_cast_text` and `rc_cast_fits` are the cast module's own
seam (changeset calls them), not part of the changeset API for callers.
`RC_CS_MAX_TEXT` lives in `cast.mettle` because the guard is enforced there; a
caller that imports only `changeset` gets it transitively.

## 3. Cast matrix, as implemented

`rc_changeset_put_text(cs, field, s)` → `rc_cast_text(rc_meta_field(meta, field), s, …)`.
`NOT NULL` below means `(field.flags & RC_F_NOT_NULL) != 0`. Every outcome below
is a `return` in `cast.mettle`; "pinned" names the assertion in
`tests/t_changeset.mettle` that would fail if the row were wrong (mutation-tested,
see §6).

### 3.1 Non-empty text, by field `ty`

| source | field `ty` | outcome | pinned |
|---|---|---|---|
| `"42"` | `RC_T_I64` | OK `RcInt(42)` | cast matrix #1 |
| `"-7"` | `RC_T_I64` | OK `RcInt(-7)` | cast matrix #2 |
| `"+7"` | `RC_T_I64` | OK `RcInt(7)` (a sign is not whitespace) | by construction |
| `"4.5"` | `RC_T_I64` | `RC_ERR_CAST` — no float→int | cast matrix #3 |
| `"9999999999999999999999"` | `RC_T_I64` | `RC_ERR_RANGE` — is an integer, is not an `int64` | cast matrix #4 |
| `" 42"` | `RC_T_I64` | `RC_ERR_CAST` — no trimming | cast matrix #5 |
| `"42 "` | `RC_T_I64` | `RC_ERR_CAST` — no trimming | cast matrix #6 |
| `"abc"` | `RC_T_I64` | `RC_ERR_CAST` | cast matrix #7 |
| `"1e5"`, `"4.5.5"`, `"--1"` | `RC_T_I64` | `RC_ERR_CAST` | by construction |
| `"42"` | `RC_T_U64` | OK `RcUint(42)` | no uint64 field in the test models |
| `"-5"` | `RC_T_U64` | `RC_ERR_RANGE` | no uint64 field in the test models |
| `"4.5"` | `RC_T_F64` | OK `RcFloat(4.5)` | cast matrix #9 |
| `"-0.25"`, `"10"`, `"0.5"` | `RC_T_F64` | OK `RcFloat` | by construction |
| `"abc"`, `" 4.5"`, `"4.5 "`, `"1e5"`, `"4.5.5"` | `RC_T_F64` | `RC_ERR_CAST` | by construction |
| 19+ digit mantissa | `RC_T_F64` | `RC_ERR_RANGE` (mantissa capped at 1e18) | by construction |
| `"1"`, `"true"` | `RC_T_BOOL` | OK `RcBool(true)` | cast matrix #10, #12 |
| `"0"`, `"false"` | `RC_T_BOOL` | OK `RcBool(false)` | cast matrix #11, #13 |
| `"yes"` | `RC_T_BOOL` | `RC_ERR_CAST` | cast matrix #14 |
| `"2"` | `RC_T_BOOL` | `RC_ERR_CAST` | cast matrix #15 |
| `"TRUE"`, `"True"` | `RC_T_BOOL` | `RC_ERR_CAST` (exact, lowercase only) | by construction |
| any non-empty, ≤ `RC_CS_MAX_TEXT` | `RC_T_TEXT` | OK `RcText(s)` **borrowed, not copied** | cast matrix #16, borrowed text |
| any, `s.length > RC_CS_MAX_TEXT` (1048576) | any | `RC_ERR_RANGE` before a byte is read | cast matrix #20 |
| exactly `RC_CS_MAX_TEXT` | `RC_T_TEXT` | OK (`>` not `>=`) | cast matrix #21–23 |
| `"1700000000000000"` | `RC_T_TIME` | OK `RcTime(1700000000000000)` (unix micros, int64 parse) | cast matrix #18 |
| `"4.5"` | `RC_T_TIME` | `RC_ERR_CAST` | by construction |
| any | `RC_T_BLOB` | `RC_ERR_CAST` — no text spelling of a blob, on purpose | by construction (no blob field) |
| any | `RC_T_UNSUPPORTED` / `RC_T_NULL` | `RC_ERR_UNSUPPORTED` | strict put #16–17 (via a meta that fails `rc_meta_check`; see §5) |

### 3.2 Empty text (`s.length == 0` or `s.chars == 0`), any `ty`

| field | outcome | pinned |
|---|---|---|
| `RC_F_NOT_NULL` | `RC_ERR_CONSTRAINT`, reason `"not null"` | empty-text `User.name` (#7), `User.role` (#15) |
| nullable | OK, `RcNull` (the null bit is set by `apply`, via `core/meta`) | empty-text `Post.body` (#1–6), `User.age` (#12) |

The matrix in the directive only spells the empty-string row out for
`RC_T_TEXT`. It is implemented for every family: "" means *absent*, and absent
is only storable where the column is nullable. `"0"` is still a value.

### 3.3 Strict `put` arm/fit matrix (`rc_cast_fits`)

`put` never parses and never coerces; it answers "does this arm belong to the
field's declared wire type".

| arm | field `ty` | outcome |
|---|---|---|
| matching arm (`RcInt`→I64, `RcFloat`→F64, `RcBool`→BOOL, `RcText`→TEXT, `RcTime`→TIME, `RcBlob`→BLOB, `RcUint`→U64) | — | OK |
| `RcUint` ↔ `RcInt` | I64 / U64 | OK — same INTEGER wire family, `core/meta` range-checks the narrowing |
| `RcNull` | any | OK; `RC_F_NOT_NULL` makes it `RC_ERR_CONSTRAINT` |
| `RcText` | I64/F64/BOOL/TIME | `RC_ERR_CAST` — "42"/"4.5"/"true" go through `put_text` |
| `RcInt` / `RcUint` | TEXT | `RC_ERR_CAST` |
| `RcInt` | F64 | `RC_ERR_CAST` — no numeric coercion at this seam |
| `RcInt` | TIME | `RC_ERR_CAST` — a TIME column takes `RcTime` |
| `RcFloat` | I64 | `RC_ERR_CAST` |
| any | `RC_T_UNSUPPORTED` | `RC_ERR_UNSUPPORTED` |

## 4. Semantics as built (and the decisions the directive left open)

1. **64-field ceiling, refuse never truncate.** `rc_changeset_new` calls
   `rc_meta_check`, which already refuses `n_fields > RC_MAX_FIELDS` with
   `RC_ERR_UNSUPPORTED`. Such a changeset comes back with `values == 0`,
   `n_values == 0`, `err_code` set to the meta's code and a static reason, and
   every later call returns that code (`put`, `put_text`, `put_name`, `reset`,
   `valid`=false, `apply`=USAGE). Tested with a hand-built 65-field `RcMeta`.
2. **`n_values`.** `== meta.n_fields` on every usable changeset; `0` exactly
   when `values == 0` (nothing allocated), so a caller looping `0..n_values`
   over a refused changeset cannot walk a null pointer. This is the one place
   the struct comment in the directive is narrowed; the fields and types are
   exactly the directive's.
3. **Baseline binding.** `bind(cs, model, nulls)` records the row, and `put`
   then compares the cell with `rc_meta_get(meta, base, base_nulls, field)`
   using `rc_value_same`; equal clears the bit, different sets it. `RcNull` vs
   `RcNull` is equal (that is `rc_value_same`'s identity rule), so a column that
   is NULL in the row and left NULL is not dirty. Without a baseline every put
   sets its bit. `bind` resets first (mask, cells, error), because a baseline
   from row A must never be compared against values put for row B.
4. **`put` is strict**, see §3.3.
5. **Borrowed text.** Documented in the module header: `put`/`put_text` keep
   the caller's `string` view, `rc_changeset_free` frees the cell array only and
   never `rc_value_release`s a cell. The "borrowed text is not copied" test
   compares `.chars` and `.length` against a heap `rc_text_dup` source for both
   `put_text` and `put`, and again for a literal.
6. **Duplicate put is last-wins**, not an error: two puts on field 3 leave the
   second value and `n_dirty == 1`.
7. **Unknown field name** → `RC_ERR_USAGE` with `err_field == -1`; a field
   index outside `[0, n_fields)` → `RC_ERR_USAGE` with `err_field` = the index
   (including `-1` as an index: indistinguishable from "no field", which is what
   the directive asks for). `put_name` resolves by field name *and* by column
   name (`rc_meta_find`).
8. **Errors are sticky and carry context.** The first refusal records
   `err_code`, `err_field` and a static `err_reason`; every later mutating call
   returns that same code without changing state, until `reset`/`bind`.
   `valid()` is pure (records nothing) and is false while an error stands or
   while a dirty `NOT NULL` field holds null; `apply` refuses an invalid
   changeset with `RC_ERR_USAGE` and writes nothing.
9. **`apply`** writes the dirty fields only, in field order, through
   `rc_entity_set`, and returns `core/meta`'s code unchanged (pinned: an int32
   field given 3000000000 returns `RC_ERR_RANGE` with `err_field == 3`, the
   entity keeps its state and its null bit). State changes are `rc_entity_set`'s
   frozen rule: `CLEAN → DIRTY` on the first written field, `NEW` stays `NEW`,
   `DELETED` is refused up front (`RC_ERR_USAGE`, `err_field == -1`, nothing
   written). The mask is **not** cleared on success — the caller still needs it
   to build the column list — and the baseline is not rebound.
10. **`valid()`'s `NOT NULL` re-check is defensive.** Because `put`/`put_text`
    already refuse a null on a `RC_F_NOT_NULL` column, the public API cannot
    reach the re-check with a bad state; it is kept (and shared with `apply`)
    so a future bulk/direct-write path cannot skip the rule.
11. **Residual casting limits, stated not hidden:** `RcInt → RC_T_F64` is
    refused at `put`; a caller that has an integer and a float column must pass
    `RcFloat` (or the text through `put_text`). `RcTime` is required for a
    `RC_T_TIME` column even though the wire arm is the same width as `RcInt`.

## 5. Seams: used, needed, not needed

Everything used is in `docs/02-seams.md` / the directive's allowed list:
`RcValue` + arms, `rc_value_type/is_null/same`, `RcField`/`RcMeta`,
`rc_meta_field/find/get/check`, `rc_nulls_has`, `RC_F_NOT_NULL`, `RcEntity`,
`rc_entity_get/set/has_pk`, `RC_ST_*`, `RC_OK` + the existing `RC_ERR_*`,
`rc_text_dup/free` (tests), `tests/models`, `tests/harness`, `std/mem`,
`std/conv`.

- **No change to any frozen seam was needed.** `core/entity.mettle` is
  untouched: the `changes` mask lives in `RcChangeset`, as the directive
  requires. `RcEntity`'s fields and signatures are unchanged.
- `rc_nulls_set` / `rc_nulls_clear` are *not* in the directive's allowed list,
  so the mask is set/cleared with `(uint64)1 << (uint64)field` and read with
  `rc_nulls_has`, which is allowed.
- `std/conv` has no `str_to_f64` and its `str_to_i64` collapses "not a number"
  into "out of range" behind one `Err(string)`. Rather than string-matching an
  error message, the integer and decimal scanners are hand-written in
  `cast.mettle` (length-delimited, no terminator read) so `RC_ERR_CAST` and
  `RC_ERR_RANGE` stay distinguishable. Not a seam change; worth knowing.
- `RC_CS_MAX_TEXT` had to be defined once, in `cast.mettle` (the module that
  enforces it) because `changeset` → `cast` is the only import direction that
  does not create a cycle.

## 6. Commands run, and the exact result lines

All from `cd /home/nox/Projects/mettle/reach`, compiler
`../raize/mettle-build/bin/mettle` (v0.17.0-444-g8f14c612).

```
$ tools/check.sh tests/t_changeset.mettle
== tests/t_changeset.mettle
  ok   t_changeset.interp
  ok   t_changeset.debug
  ok   t_changeset.debug.run
  ok   t_changeset.release
  ok   t_changeset.release.run

5 passed, 0 failed (logs in /tmp/reach-check)
```

Compile-time interpreter, on its own:

```
$ ../raize/mettle-build/bin/mettle test tests/t_changeset.mettle
running 1 test (compile-time interpreter, no codegen)
test t_changeset ... ok

1 passed (tests/t_changeset.mettle)
```

Debug binary (`/tmp/reach-check/t_changeset.debug`) and release binary
(`/tmp/reach-check/t_changeset.release`) print the same eight lines:

```
  ok   changeset: cast matrix
  ok   changeset: empty text is null only when nullable
  ok   changeset: identical value is not dirty
  ok   changeset: apply writes only changed fields
  ok   changeset: new entity stays new
  ok   changeset: strict put refuses coercion
  ok   changeset: errors carry field and code
  ok   changeset: borrowed text is not copied
8 checks passed
```

Full gate, no arguments, i.e. Phase 1 must not have moved:

```
$ tools/check.sh
...
20 passed, 0 failed (logs in /tmp/reach-check)
```

No warnings were emitted by any of the three compiler invocations for this
file:
```
$ grep -ci warning /tmp/reach-check/t_changeset.*.log
/tmp/reach-check/t_changeset.debug.log:0
/tmp/reach-check/t_changeset.debug.run.log:0
/tmp/reach-check/t_changeset.interp.log:0
/tmp/reach-check/t_changeset.release.log:0
/tmp/reach-check/t_changeset.release.run.log:0
```

## 7. Mutation evidence (the tests bite)

Each mutation was applied to the module, rebuilt, run, and reverted
(`diff` clean afterwards):

| mutation | result |
|---|---|
| baseline comparison always "different" | `FAIL changeset: identical value is not dirty code=19` |
| `put` always sets the bit (no comparison at all) | `FAIL changeset: identical value is not dirty code=19` |
| `put` skips the arm/fit check | `FAIL changeset: strict put refuses coercion code=1` |
| `put` accepts `RcNull` on a `NOT NULL` column | `FAIL changeset: empty text is null only when nullable code=17` |
| `RC_CS_MAX_TEXT` guard removed | `FAIL changeset: cast matrix code=20` |
| integer scanner skips junk characters | `FAIL changeset: cast matrix code=3` |
| `apply` ignores the dirty mask | `FAIL changeset: apply writes only changed fields code=13` (+2 more) |
| `apply` does not refuse a `DELETED` entity early | `FAIL changeset: errors carry field and code code=47` |

## 8. What Phase 3 hands forward

- `changes` (uint64) + `values` (`RcValue*`) is exactly the input an
  `UPDATE ... SET` builder needs: column list from the set bits, arguments in
  field order, `IS NULL` from `ce.values[i]` being `RcNull`.
- The mask survives `apply`, so the builder can run before or after the model
  is updated.
- `rc_changeset_valid` is the gate a persistence path should call: it answers
  "nothing was refused and every dirty `NOT NULL` column has a value".
