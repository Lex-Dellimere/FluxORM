# Frozen seams

A worker may rely on exactly what is listed here and nothing more. If a phase
needs a change to an earlier phase's exported shape, it reports the need to the
director; it does not edit the earlier phase. This is the same rule as
`raize`: fix the seam in code, then hand it off.

All symbols below are exported from modules that are already green
(`tools/check.sh`, through mbuild). Import them file-relatively:
`import "../core/value";` from `src/<phase>/`, `import "../src/core/value";`
from `tests/`.

---

## Phase 1 → everything: `core/value`

```
RcValue        RcNull | RcInt(i64) | RcUint(u64) | RcFloat(f64) | RcBool(bool)
               | RcText(string) | RcBlob(RcBytes) | RcTime(i64)
RcBytes        { data: uint8*, len: int64 }
RC_T_*         NULL I64 F64 BOOL TEXT BLOB TIME U64 UNSUPPORTED
rc_value_type, rc_value_type_name, rc_value_is_null
rc_value_as_i64/u64/f64/bool/text/blob (strict, out-param, RC_ERR_CAST/RANGE)
rc_value_clone / rc_value_release / rc_value_same
rc_value_null/int/uint/float/bool/text/time/blob
rc_text_dup / rc_text_free / rc_blob_dup
```

Rules: `RcText`/`RcBlob` are borrowed. `clone` owns, `release` frees only
cloned values. `rc_value_same` is identity (NULL == NULL); SQL three-valued
logic belongs to query/.

## Phase 1 → everything: `core/status`

`RC_OK`, `RC_ERR_{CAST,RANGE,NOT_FOUND,CONFLICT,CONSTRAINT,UNSUPPORTED,USAGE,CLOSED,TX,NOMEM,ADAPTER,SCRIPT}`, `rc_status_name`, `rc_status_ok`.

Codes are public: a caller may branch on them. Never invent a new negative
number in a later phase without adding it here.

## Phase 1 → everything: `core/meta`

```
RcField   { name, column, kind: Kind, ty: int32, offset, size, flags }
RcMeta    { table, name, size, fields: RcField*, n_fields, pk }
RcColumn  { index, column, ty, flags }        // override row
RC_F_{PK,AUTO,NOT_NULL,UNIQUE,READ_ONLY,TIMESTAMP}
RC_MAX_FIELDS = 64
rc_kind_type(Kind) -> int32
rc_nulls_{has,set,clear}(mask, i)
rc_meta_field/find/pk/is_auto/apply/finalize/check
rc_meta_get(m, model, nulls, i, out)          // read
rc_meta_set(m, model, nulls*, i, v)           // write, range-checked
```

Invariants: `rc_meta_check` must pass before any persistence call. A model
field must be a scalar, `string`, or plain enum; anything else is
`RC_ERR_UNSUPPORTED` at startup.

## Phase 1 → everything: `core/entity`

```
RcEntity { meta, model, nulls, state }
RC_ST_{NEW,CLEAN,DIRTY,DELETED}
rc_entity_new/get/set/pk/has_pk/state_name
```

`set` on a NEW entity leaves it NEW (new is not dirty). Phase 3 adds a
`changes` mask for per-field dirty tracking; it must not change these
signatures, only extend `RcEntity` at the end.

## Phase 1 → everything: `adapter/adapter`

```
RcResult { rows: RcRow*, n_rows, n_cols, affected, last_id }
RcRow    { values: RcValue*, n }
RcAdapter { name, ud, open, close, exec, begin, commit, rollback, ping }
RC_TX_{DEFAULT,DEFERRED,IMMEDIATE}
rc_result_{init,alloc,free,copy,get,borrow,text,i64}
rc_adapter_{open,close,exec,begin,commit,rollback,ping}   // guarded
rc_adapter_empty()                                        // no capabilities
```

`exec(ud, sql, args, n_args, out)` is **synchronous and materialising**: it
runs the statement to completion and copies every row before returning. No
cursor exists. Rows in `RcResult` are owned; `rc_result_borrow` hands out a
borrowed cell for loaders.

Placeholders are `?`, positional. Identifiers are double-quoted, embedded `"`
doubled (`rc_buf_ident`). Values are never interpolated into text.

## Phase 1 → everything: `core/buf`

`RcBuf {data,len,cap}`, `rc_buf_{new,free,clear,put,putc,put_i64,ident,text}`.
`rc_buf_text` is a borrowed view valid until the next mutation/free.

## Phase 1 → everything: `core/persist` (the straw man Phase 2 replaces)

`rc_persist_insert(a, e*)`, `rc_persist_load(a, m, pk, model, nulls*, owner*)`,
`rc_persist_delete(a, e*)`.

The load signature is the lifetime contract: `*owner` receives the result the
model's strings point into; free it after the last use of the model.

---

## What each later phase may add

**Phase 2 (query/)** may add `query/` and `tests/t_query.mettle`. It may not
edit `core/` or `adapter/`. It emits the same statement shapes `core/persist`
uses. Deleting surface: it owns `RcDialect` (quoting, placeholder, LIMIT
syntax) and must route `core/buf` through it.

**Phase 3 (changeset/)** may add `changeset/` and `tests/t_changeset.mettle`.
It adds a `changes` mask (same 64-field rule) and casting/validation on top of
`RcValue`; it does not touch `RcEntity`'s existing fields. Casting policy:
changeset parses user input, `core/meta` still does the final range check.

**Phase 4 (relation/)** may add `relation/` and `tests/t_relation.mettle`. It
may not add columns to models; relations are declared as metadata
(`RcRelation { kind, local_field, foreign_table, foreign_field }`) plus a
loader that uses Phase 2's IN support. No N+1.

**Phase 5 (migration/)** may add `migration/` and `tests/t_migration.mettle`.
It emits DDL through the adapter and records applied versions in
`_reach_migrations (version INTEGER PRIMARY KEY, name TEXT, applied_at INTEGER)`.
Up-only until dacor's catalog can be read.

---

## Definition of done (all phases)

1. Code compiles with no warnings.
2. A test file exists with `check_*` functions, `main`, and one `@test`.
3. `tools/check.sh <that file>` is green: interpreter, debug, release.
4. No edit outside the phase's own directory plus its own test file.
5. The director has been given: the files added, the exported seam, the
   commands run, and the exact output lines.
6. Anything that had to be worked around (compiler bug, missing dacor API) is
   written down as a comment at the workaround **and** reported.
