# Directive — reach-changeset (Phase 3)

Issued: wave A. Contract you are judged against. `docs/02-seams.md` is
authoritative for what you may rely on; this file is the narrower task.

## Files you may create

- `reach/changeset/cast.mettle`     (required — text → RcValue parsing)
- `reach/changeset/changeset.mettle` (required — RcChangeset, dirty mask, apply)
- `tests/t_changeset.mettle`        (required)
- `reports/changeset.md`            (required report)

Nothing else. **Do not** create or edit: `core/`, `adapter/`, `query/`,
`relation/`, `migration/`, `docs/`, `tests/models.mettle`,
`tests/harness.mettle`, `tools/check.sh`, or any `tests/t_*.mettle` other than
`tests/t_changeset.mettle`. `core/entity.mettle` is frozen: you do not add a
`changes` field to `RcEntity`; the mask lives in *your* struct.

## Frozen symbols you may use (and only these)

From `reach/core/value`: `RcValue` + arms (`RcNull`, `RcInt`, `RcUint`,
`RcFloat`, `RcBool`, `RcText`, `RcBlob`, `RcTime`), `RcBytes`, `RC_T_*`,
`rc_value_type`, `rc_value_is_null`, `rc_value_same`, `rc_value_clone`,
`rc_value_release`, `rc_value_int`/`_float`/`_bool`/`_text`/`_time`/`_null`,
`rc_text_dup`, `rc_text_free`.

From `reach/core/meta`: `RcMeta`, `RcField`, `rc_meta_field`, `rc_meta_find`,
`rc_meta_pk`, `rc_meta_get`, `rc_meta_check`, `rc_nulls_has`, `RC_F_PK`,
`RC_F_AUTO`, `RC_F_NOT_NULL`, `RC_F_UNIQUE`, `RC_F_READ_ONLY`,
`RC_F_TIMESTAMP`, `RC_MAX_FIELDS`, `RC_T_UNSUPPORTED`.

From `reach/core/entity`: `RcEntity`, `RC_ST_NEW`, `RC_ST_CLEAN`,
`RC_ST_DIRTY`, `RC_ST_DELETED`, `rc_entity_get`, `rc_entity_set`,
`rc_entity_has_pk`, `rc_entity_state_name`.

From `reach/core/status`: `RC_OK` and the existing `RC_ERR_*` codes. **Never
invent a status code** — a new negative number is a stop condition. You may add
`RC_CS_*` **constants that are not status codes** (e.g. a text length policy).

From `tests/models` (tests only): `user_meta()`, `post_meta()`, models `User`,
`Post`, `Doc`. From `tests/harness`: `rc_report`, `rc_summary`.

`std/mem` (`malloc`/`free`/`memset`) and `std/conv` are fine. No `std/strbuf`.

## Required shape — exact names

```
export const RC_CS_MAX_TEXT: int64 = 1048576;   // policy limit, RC_ERR_RANGE above it

export struct RcChangeset {
  meta: RcMeta;
  changes: uint64;      // bit i set = field i was written by the caller
  values: RcValue*;     // meta.n_fields cells, borrowed, default RcNull
  n_values: int32;      // == meta.n_fields
  base: rawptr;         // baseline model for dirty comparison, 0 = none
  base_nulls: uint64;
  err_field: int32;     // -1 when no error
  err_code: int32;      // RC_OK when no error
  err_reason: string;   // static string, never owned
}

export fn rc_changeset_new(m: RcMeta) -> RcChangeset
export fn rc_changeset_free(cs: RcChangeset*)
export fn rc_changeset_reset(cs: RcChangeset*) -> int32
export fn rc_changeset_bind(cs: RcChangeset*, model: rawptr, nulls: uint64) -> int32
export fn rc_changeset_put(cs: RcChangeset*, field: int32, v: RcValue) -> int32
export fn rc_changeset_put_name(cs: RcChangeset*, name: string, v: RcValue) -> int32
export fn rc_changeset_put_text(cs: RcChangeset*, field: int32, s: string) -> int32
export fn rc_changeset_put_null(cs: RcChangeset*, field: int32) -> int32
export fn rc_changeset_has(cs: RcChangeset*, field: int32) -> bool
export fn rc_changeset_n_dirty(cs: RcChangeset*) -> int32
export fn rc_changeset_apply(cs: RcChangeset*, e: RcEntity*) -> int32
export fn rc_changeset_valid(cs: RcChangeset*) -> bool
export fn rc_changeset_error_field(cs: RcChangeset*) -> int32
export fn rc_changeset_error_code(cs: RcChangeset*) -> int32
export fn rc_changeset_error_reason(cs: RcChangeset*) -> string
```

That is the whole exported surface — one flat namespace, `Rc`/`rc_`/`RC_`
prefixes only. `rc_changeset_put_text` is the **single** parsing entry point
(the agent blurb's `put_text_i64`/`_f64`/... helpers are folded into it: one
function that dispatches on the field's declared `ty`). Do not add a
second family.

## Semantics that are not negotiable

1. **`changes` bit per field, 64 fields max.** `rc_changeset_new` on a meta
   with `n_fields > RC_MAX_FIELDS` or a failing `rc_meta_check` returns a
   changeset whose `values == 0` and `err_code` is `RC_ERR_UNSUPPORTED` /
   the meta code; every later call on it returns that code. Never truncate.
2. **Baseline binding.** `rc_changeset_bind(cs, model, nulls)` records the row
   the changeset came from. `put` then compares with `rc_value_same` against
   `rc_meta_get(meta, base, base_nulls, field)`:
   - equal → the bit is **cleared**, `n_dirty` does not count it;
   - different → the bit is set.
   This is the whole point: an UPDATE built from `changes` must never rewrite
   an untouched column. `RcNull` vs `RcNull` is "equal" (`rc_value_same` is
   identity) — a field that is NULL in the row and left NULL is not dirty.
   Without a bound baseline every put sets its bit.
3. **Put is strict.** `rc_changeset_put` refuses an arm that does not fit the
   field's declared `ty` with `RC_ERR_CAST` (`RcText` into `RC_T_I64`,
   `RcInt` into `RC_T_TEXT`, `RcFloat` into `RC_T_I64`, …). Casting is only
   through `rc_changeset_put_text`.
4. **Cast matrix.** `rc_changeset_put_text(cs, field, s)` dispatches on
   `rc_meta_field(meta, field).ty`:

   | input | field ty | outcome |
   |---|---|---|
   | `"42"`, `"-7"` | `RC_T_I64` | `RcInt(42)` / `RcInt(-7)` |
   | `"4.5"` | `RC_T_I64` | `RC_ERR_CAST` (no float→int) |
   | `"9999999999999999999999"` | `RC_T_I64` | `RC_ERR_RANGE` |
   | `" 42"` / `"42 "` | any numeric | `RC_ERR_CAST` — **no trimming** |
   | `"abc"`, `""` on NOT NULL | `RC_T_I64` | `RC_ERR_CAST` / `RC_ERR_CONSTRAINT` |
   | `"4.5"` | `RC_T_F64` | `RcFloat(4.5)` |
   | `"1"`,`"0"`,`"true"`,`"false"` | `RC_T_BOOL` | `RcBool(true/false)` |
   | `"yes"`, `"2"` | `RC_T_BOOL` | `RC_ERR_CAST` |
   | any non-empty | `RC_T_TEXT` | `RcText(s)` borrowed, **no copy** |
   | `""` | `RC_T_TEXT` + `RC_F_NOT_NULL` | `RC_ERR_CONSTRAINT` |
   | `""` | `RC_T_TEXT`, nullable | `RcNull` (sets the null bit via apply) |
   | `"1700000000000000"` | `RC_T_TIME` | `RcTime(...)` — unix micros, int64 parse |
   | any | `RC_T_UNSUPPORTED` | `RC_ERR_UNSUPPORTED` |

   `s.length > RC_CS_MAX_TEXT` is `RC_ERR_RANGE`.
5. **Borrowed text.** `put`/`put_text` do not clone: `values[i]` holds the
   caller's `string`. Document in the module header that the changeset borrows
   text exactly like `RcEntity` does, and that the caller keeps the buffer
   alive until `rc_changeset_free`. `rc_changeset_free` must **not**
   `rc_value_release` cells (they are borrowed).
6. **Duplicate put is last-wins, not an error.** `put(2, 3)` then `put(2, 5)`
   → value 5, `n_dirty` still counts field 2 once, `RC_OK` both times. (This
   overrides the "duplicate put is a validation error" line in your agent
   brief — the test asserts last-wins.)
7. **Unknown field name.** `rc_changeset_put_name` on a name with
   `rc_meta_find == -1` → `RC_ERR_USAGE`, `err_field = -1`; a field index
   outside `[0, n_fields)` → `RC_ERR_USAGE`, `err_field = <index>`.
8. **Errors carry context.** Every refusal sets `err_code`, `err_field` (or
   `-1`) and `err_reason` to a **static** string, then returns the code.
   `rc_changeset_valid` returns `false` while any recorded error stands *and*
   re-checks NOT NULL across the dirty set. `rc_changeset_apply` on an invalid
   changeset returns `RC_ERR_USAGE` and writes nothing.
9. **Apply goes through `rc_entity_set`** for the dirty fields only, in field
   order. Consequences the test must pin:
   - a field whose bit is clear is **not** touched (`rc_value_same` on the
     entity before/after);
   - `RC_ERR_RANGE` from `core/meta`'s narrowing is returned unchanged with
     `err_field` = that field;
   - `e->state` becomes `RC_ST_DIRTY` only if at least one field was written
     and the entity was `RC_ST_CLEAN`. A `RC_ST_NEW` entity stays `NEW`
     (`rc_entity_set`'s frozen rule); a `DELETED` entity is `RC_ERR_USAGE`.
10. **No UPDATE SQL in this phase.** You produce the mask and the values;
    emitting `UPDATE ... SET` is a later directive. Do not add SQL text here.

## Definition of done

1. `cd /home/nox/Projects/mettle/reach && tools/check.sh tests/t_changeset.mettle`
   prints `5 passed, 0 failed (logs in /tmp/reach-check)` — interpreter,
   debug build, debug run, release build, release run. Release is mandatory.
2. `tests/t_changeset.mettle` follows `tests/t_persist.mettle`'s shape:
   `export fn main() -> int32` running `check_*()` through `rc_report`, plus
   one `@test fn t_changeset() -> int32` running the same functions. Required
   checks:
   - `changeset: cast matrix` — the whole table in §4, one assertion each.
   - `changeset: empty text is null only when nullable` — Post.body (nullable)
     vs User.name (NOT NULL).
   - `changeset: identical value is not dirty` — bind a real `User`, put the
     values the row already holds → `n_dirty == 0`; change one → `n_dirty == 1`
     and only that bit.
   - `changeset: apply writes only changed fields` — before/after comparison
     of every field via `rc_entity_get`; state `CLEAN → DIRTY`.
   - `changeset: new entity stays new` — `rc_entity_new` + `apply` → state
     `RC_ST_NEW`, values written.
   - `changeset: strict put refuses coercion` — `RcText` into I64,
     `RcInt` into TEXT, unsupported Doc field.
   - `changeset: errors carry field and code` — `err_field`, `err_code`,
     non-empty `err_reason`, `valid()` false, `apply` refuses with
     `RC_ERR_USAGE`.
   - `changeset: borrowed text is not copied` — `put_text` a heap string,
     compare `.chars` pointer identity of `values[i]` with the source view.
3. No edit outside your file list. 2-space indent, explicit type on every
   `var`/local `const`, `export` on every public declaration, `defer` cleanup
   so the leak analyser is quiet, no `--safe`.
4. Report in `reports/changeset.md`: files, exported seam symbol by symbol, the
   cast matrix as implemented (source arm × field ty → outcome), the commands
   run, the exact pass/fail lines, and any seam you needed but could not have.
