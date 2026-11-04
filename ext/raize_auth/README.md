# flux_raize_auth

A [raize_auth](../../../raize_auth) storage backend (`RaStores`: credentials, counters, tokens) on flux_orm and MeoDB.
API tokens and lockout counters get two tables of their own; passwords stay
in the app's user table.

## Use

Add it with its dependencies in the app's `mbuild.mettle`:

```
mb_dep_path("flux_raize_auth", "../flux_orm/ext/raize_auth");
mb_dep_path("flux_orm", "../flux_orm");
mb_dep_path("raize_auth", "../raize_auth");
mb_dep_path("crypto", "../cryptex");
```

Then:

```
import "flux_orm/flux_orm";
import "flux_orm/adapter/meodb";
import "flux_orm/repo/pool";
import "raize_auth/auth";
import "flux_raize_auth/flux_raize_auth";

// 1. a pool, one connection per worker thread or fewer
var pool: RcPool;
rc_meodb_pool(&pool, 8, "token", "127.0.0.1:5490");

// 2. the tables: add the migration to the app's set
var migs: RcMigration[2];
migs[0] = ...;                 // the app's own
rfa_migration(&migs[1], 2);    // ra_tokens, ra_counters
rc_migration_run(adapter, &set, &report);

// 3. the store
var ctx: RfaStore;
ctx.pool = &pool;
ctx.users.meta = user_meta();  // the app's user model
ctx.users.login = "email";     // looked up by cred_get
ctx.users.owner = "id";        // the user id raize_auth sees
ctx.users.hash = "password_hash";
ctx.users.disabled = "";       // or a bool/int column
var stores: RaStores;
rfa_stores_bind(&stores, &ctx);   // then ra_auth_init(&a, &cfg, &stores)
```

`ctx` and the pool must outlive every call through `stores`. Each call checks a
session out of the pool (waiting up to 5 s) and back in, so one store can be
shared by all threads.

## Tables

- `ra_tokens`: key BLOB primary key (SHA-256 of the token), owner, created,
  expires, last_used, revoked (INTEGER), scope, label (TEXT); index
  `ra_tokens_owner_index` on owner.
- `ra_counters`: key BLOB primary key, failures, window_start, locked_until.

The migration's down step drops both.

## The user table

`RfaUsers` names columns in the app's own table. The hash column is TEXT and
holds the Argon2id string; NULL or empty means no password (it never
verifies). `disabled` is `""` when the app never disables users; NULL there
means enabled.

`cred_set_hash` uses flux's update_all, so a user table with an RC_F_VERSION
column is refused (`RA_E_STORE`), and RC_F_UPDATED columns are stamped from
the clock set with `rc_clock_set`, which must then be installed.

## Codes

Every function answers `RA_OK`, `RA_E_NOT_FOUND`, `RA_E_NOMEM` or
`RA_E_STORE` (any other flux error, a busy pool included). `tok_list` and
`prune` answer a count instead of `RA_OK`.

## Test

`tests/store_live.mettle` runs the RaStores contract and a four-thread smoke
test against a real server. It is a test program (`mb_test_bin`), so mbuild
links libsodium for it; with no server on 127.0.0.1:5491 it prints SKIP and
passes. From this directory:

```
MB=/home/nox/Projects/mettle/mbuild/build/linux/release/mbuild
export METTLE=/home/nox/Projects/mettle/Mettle/bin/mettle
../../../meodb/build/linux/release/meodb --db /tmp/rfa.meo --listen 127.0.0.1:5491 &
$MB test --force store_live        # -r for release
kill %1; rm -f /tmp/rfa.meo*
```

Use an empty database each run. `--force` reruns it even when mbuild has
cached a pass (for example one that skipped).
