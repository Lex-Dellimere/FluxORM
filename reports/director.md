# reach — director report

## State
phase: **1–6 green** — core+adapter, query, changeset, relation, migration, and
the cross-phase integration test
layout: canonical mbuild — modules in `src/<mod>/`, file-relative imports,
`mbuild.toml`, gate driven by `tools/check.sh` → mbuild, no `[toolchain]` pin
gate: **green**   last full run: `tools/check.sh` → **42 passed, 0 failed**

```
$ tools/check.sh                     # no arguments: every tests/t_*.mettle
42 passed, 0 failed (logs in /tmp/reach-check)
   = mbuild check + mbuild test (interpreter)
   + 9 × (t_*.debug.build, debug.run, release.build, release.run)
   + mbuild build, demo.debug.run, mbuild build -r, demo.release.run
```

`mbuild test` alone is the interpreter only and is **not** the gate. Release
builds and runs are mandatory: every head miscompile in this project has been
release-only (`tools/repros/`).

## Layout (post-restructure)
```
src/core/{value,status,meta,entity,buf,persist}.mettle
src/adapter/{adapter,mem,dacor}.mettle
src/query/{dialect,builder}.mettle
src/changeset/{cast,changeset}.mettle
src/relation/{relation,load}.mettle
src/migration/{ddl,version}.mettle
tests/{harness,models}.mettle
tests/t_{value,meta,adapter,persist,query,changeset,relation,migration,integration}.mettle
cmd/reachdemo/main.mettle   mbuild.toml   tools/check.sh
```

## Seams frozen
- `core/status` — RC_* taxonomy (no later phase may invent a code)
- `core/value` — RcValue, strict casts, clone/release
- `core/meta` — RcField/RcMeta/RcColumn, comptime registry, null bitmap,
  typed get/set with range + NOT NULL checks, startup validation
- `core/entity` — RcEntity, NEW/CLEAN/DIRTY/DELETED (unchanged in Phase 3)
- `core/buf` — RcBuf, identifier quoting, i64 formatting
- `core/persist` — insert/load(owner result)/delete (DELETE still current)
- `adapter/adapter` — vtable, RcResult ownership, guarded wrappers, materialising exec
- `adapter/mem` — recording/replay double; `adapter/dacor` — gated (unsupported)
- `query/dialect` — RcDialect, byte-identical to `rc_buf_ident`
- `query/builder` — RcQuery: SELECT/WHERE/IN/ORDER/LIMIT/OFFSET/JOIN, batch INSERT
- `changeset/cast` + `changeset/changeset` — RcChangeset mask, cast matrix, apply
- `relation/{relation,load}` — RcRelation, RcRelationResult, batch loader
- `migration/{ddl,version}` — CREATE TABLE from RcMeta, ledger, per-migration tx

## Hand-offs
| worker | phase | files | verified by (director-run) | result |
|---|---|---|---|---|
| (parent) | 1 core+adapter | src/core/*, src/adapter/*, tests/t_{value,meta,adapter,persist}.mettle | `tools/check.sh` → 20/20 (pre-mbuild); post-move `mbuild test` → 7 passed | green, frozen |
| reach-query | 2 | src/query/{dialect,builder}.mettle, tests/t_query.mettle | `tools/check.sh tests/t_query.mettle` → 5 ok (pre-mbuild); 7-file run → 35/35 | green |
| reach-changeset | 3 | src/changeset/{cast,changeset}.mettle, tests/t_changeset.mettle | `tools/check.sh tests/t_changeset.mettle` → 5 ok (pre-mbuild); 7-file run → 35/35 | green |
| reach-migration | 5 | src/migration/{ddl,version}.mettle, tests/t_migration.mettle | `tools/check.sh tests/t_migration.mettle` → 5 ok (pre-mbuild); 7-file run → 35/35 | green |
| reach-relation | 4 | src/relation/{relation,load}.mettle, tests/t_relation.mettle, reports/relation.md | post-move: `tools/check.sh tests/t_relation.mettle` → **10 passed, 0 failed**; full `tools/check.sh` → **38 passed, 0 failed** | green |
| worker (builtin) | 6 | tests/t_integration.mettle | `tools/check.sh tests/t_integration.mettle` → **10 passed, 0 failed**; full `tools/check.sh` → **42 passed, 0 failed** | green |

Every row was verified by the director running the gate itself and reading the
output; no worker's "tests pass" was accepted as evidence. Worker reports:
`reports/{query,changeset,migration,relation}.md` (the integration worker was
limited to one file and reported in its hand-off message; its content is
summarised in the drift section below).

## Directives issued
| time | worker | directive | run id |
|---|---|---|---|
| wave A | reach-query | reports/directives/query.md | f60b6683-0493-48a0-95c4-08ac3162576d (wf 5fad2ca7) |
| wave A | reach-changeset | reports/directives/changeset.md | 9db5c301-c1c3-4002-8477-8558c8a8696c (wf 5fad2ca7) |
| wave A | reach-migration | reports/directives/migration.md | 778d2d43-f999-4fca-b68a-1ceb176756ab (wf 5fad2ca7) |
| wave B | reach-relation | reports/directives/relation.md (reissued for mbuild paths) | 23579633-… (wf 66661c04) → interrupted at the layout freeze → resumed as 8ef0ac4f-d693-41f5-886b-c7d58a278034 |
| wave C | worker (builtin) | reports/directives/integration.md | 5ce0cfd0-55d0-4118-9239-abe92231972d (wf 361469c5) |

## Gate log (director-run, exact output)

Phase 4 file, post-restructure:
```
$ tools/check.sh tests/t_relation.mettle
== mbuild check
  ok   mbuild.check
== mbuild test (interpreter)
  ok   mbuild.test
== tests/t_relation.mettle
  ok   t_relation.debug.build
  ok   t_relation.debug.run
  ok   t_relation.release.build
  ok   t_relation.release.run
== demo bin
  ok   mbuild.build
  ok   demo.debug.run
  ok   mbuild.build.release
  ok   demo.release.run

10 passed, 0 failed (logs in /tmp/reach-check)
```

Phase 6 (integration) file:
```
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

Everything, post-restructure:
```
$ tools/check.sh
…
42 passed, 0 failed (logs in /tmp/reach-check)
```

Pre-restructure (kept for the record, mettle-only gate):
```
$ tools/check.sh                                    -> 20 passed, 0 failed   (Phase 1)
$ tools/check.sh tests/t_query.mettle               ->  5 passed, 0 failed
$ tools/check.sh tests/t_changeset.mettle           ->  5 passed, 0 failed
$ tools/check.sh tests/t_migration.mettle           ->  5 passed, 0 failed
$ tools/check.sh t_value t_meta t_adapter t_persist t_query t_changeset t_migration
                                                    -> 35 passed, 0 failed
```

## Drift recorded (not blocking, not papered over)
1. **`RcDialect` lives in `src/query/dialect.mettle`**, not
   `adapter/dialect.mettle` as the adapter brief says. `docs/02-seams.md` gives
   it to Phase 2; `adapter/` was never written, so one definition, no duplicate
   export. Adapter's item 1 is amended.
2. **`src/changeset/cast.mettle` exports two names beyond its directive**
   (`rc_cast_fits`, `rc_cast_text`). Mettle has no cross-module visibility
   without `export`; `changeset.mettle` calls them. `rc_`-prefixed, unique.
3. **`src/migration` has no real clock.** `clock_gettime` makes `mettle test`
   skip the whole file (probe transcript in `reports/migration.md` §5), so
   `applied_at` comes from `rc_migration_set_clock` with a documented 0
   fallback. No test depends on wall time.
4. **`docs/04-integration.md` is stale against the code in fourteen places**;
   the integration directive listed eight in advance and the worker found six
   more. The material ones: `rc_query_where_gt` does not exist (builder has
   eq/null/not_null/in and takes field **indexes**); there is no UPDATE emitter
   (changeset owns the mask and values); there is no session cache; the ledger
   read is `SELECT "version" FROM "_reach_migrations" ORDER BY "version" ASC`;
   `rc_migration_create_table` takes an `RcBuf*` and emits
   `CREATE TABLE IF NOT EXISTS` with `NOT NULL` before `UNIQUE`; relation type
   mismatch is `RC_ERR_CAST` not `RC_ERR_UNSUPPORTED`; unknown changeset field
   yields `error_field() == -1` plus the static reason `"unknown field name"`,
   not the name; `adapter/mem` replays rows and never evaluates SQL, so "the
   NULL row is excluded" is asserted at the null bitmap instead; and §5's
   "IN (?, ?, ?)" contradicts its own "fourth owner with zero posts", so those
   are two honest loads (3 keys, then 4 keys). **`docs/04-integration.md` should
   be corrected by whoever owns docs.**
5. **Compiler finding (reported, worked around at the call site):** a
   `tests/t_integration.mettle` `@test` that calls all seven checks directly
   segfaults head 8f14c612 in IR lowering ("Function: t_integration"); small
   groups are fine. The file walks a module-global `(fn() -> int32)[7]` table
   so each check stays its own IR unit, with a comment at the site. All three
   runners (interpreter, debug, release) are green.
6. Worker briefs in `.pi/agents/` still describe parts of the pre-mbuild gate
   (`tools/check.sh` now goes through `mbuild check` / `mbuild test` +
   `mbuild mettle`).

## Open seams (deliberately **not** started)
`core/session`, `core/arena`, hooks/auto-timestamps (`RC_F_TIMESTAMP` /
`RC_F_READ_ONLY` are still unfilled), identity map + stale-write detection, the
UPDATE emitter fed by the changeset mask, the dacor bridge (`rc_dacor_supported()
== false`), prepared-statement cache, `RcDiagnostic`, and query's
`where_gt`/`where_lt`.

## Next
- nothing gated on the director. The build order (1→5) plus cross-phase
  acceptance is complete and green; the items above need a new directive to
  start.
