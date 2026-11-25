# Upgrading to Postgres 19: What Breaks, and How Long pg_upgrade Takes (Tested)

2026-11-24 · Mohammad Aziz

PostgreSQL 19 was released on November 19, 2026. On a 21.3 GB database, `pg_upgrade --link` moved us from 18.7 to 19.0 with 1.9 seconds of client downtime. `--copy` took 5.4 minutes, and `pg_dump`/`pg_restore` took 25.6 minutes. The new features were not the risk. The risk was the changed defaults and the removed settings, and `pg_upgrade --check` does not see most of them.

We tested the upgrade on one AWS EC2 m7i.xlarge (4 vCPU, 16 GB RAM, gp3 disk) in ap-south-1, with two datasets: 1.67 GB and 21.3 GB. We broke the upgrade on purpose ten times and kept the exact errors. Every number in this post comes from runs on November 24, 2026, with PGDG packages 18.7 and 19.0. The scripts are in the `pg19-upgrade-tests` repository.

## What changed in Postgres 19 that matters for your upgrade

Five features that were announced for 19 were pulled before release, and some pages still list them. We ran each one on 19.0. Every one failed with a syntax error or "function does not exist". The table keeps only the features that change how you operate a server.

| Feature                                                          | In 19.0?                | What we saw on 19.0                                                                                                     |
|------------------------------------------------------------------|-------------------------|-------------------------------------------------------------------------------------------------------------------------|
| `REPACK` and `REPACK (CONCURRENTLY)`                             | Shipped                 | `repack (concurrently) rp` ran without error                                                                            |
| Parallel autovacuum                                              | Shipped                 | New setting `autovacuum_max_parallel_workers` (default 0) and five `autovacuum_*_score_weight` settings                 |
| Auto-scaling I/O workers                                         | Shipped                 | `io_workers` is gone; `io_min_workers`, `io_max_workers`, `io_worker_idle_timeout`, `io_worker_launch_interval` are new |
| Logical replication without a restart when `wal_level = replica` | Shipped                 | New read-only setting `effective_wal_level`                                                                             |
| Aggregation before joins                                         | Shipped                 | New settings `enable_eager_aggregate`, `min_eager_agg_group_size`                                                       |
| Faster foreign-key checks                                        | Shipped                 | A 5M-row insert with an FK took 10.0 s on 19 and 19.7 s on 18 (see the benchmark)                                       |
| `WAIT FOR LSN`, logical replication of sequences                 | Shipped (release notes) | Not run on 19 here. An 18 publisher cannot publish sequences (see the logical replication section)                      |
| SQL/PGQ (`CREATE PROPERTY GRAPH`, `GRAPH_TABLE`)                 | Pulled                  | `ERROR: syntax error at or near "property"`                                                                             |
| `ALTER TABLE ... MERGE PARTITIONS` / `SPLIT PARTITION`           | Pulled                  | `ERROR: syntax error at or near "merge"`                                                                                |
| `UPDATE ... FOR PORTION OF`                                      | Pulled                  | `ERROR: syntax error at or near "for"`                                                                                  |
| Online checksum toggle                                           | Pulled                  | `ERROR: function pg_enable_data_checksums() does not exist`                                                             |
| `pg_get_*_ddl()` functions                                       | Pulled                  | No function matches `^pg_get_.*_ddl$` in `pg_proc`                                                                      |

This is what a pulled feature looks like on 19.0:

```
postgres=# alter table m merge partitions (m1, m2) into m12;
ERROR:  syntax error at or near "merge"
LINE 1: alter table m merge partitions (m1, m2) into m12
                      ^
```

To get the setting changes, we compared `pg_settings.boot_val` on a new 18.7 cluster and a new 19.0 cluster. 19.0 adds 22 settings and removes two: `io_workers` and `escape_string_warning`. Four defaults change, and the next section covers them.

## Changed defaults that hit you after the upgrade

Four built-in defaults change between 18.7 and 19.0, and `pg_upgrade --check` reports none of them. Two of them can change your capacity or your logs on the first day.

```
setting                     18.7    19.0
default_toast_compression   pglz    lz4
jit                         on      off
log_lock_waits              off     on
max_locks_per_transaction   64      128
```

**`max_locks_per_transaction` must be doubled if you set it yourself.** 19 sizes the lock table differently, so the same number now holds fewer locks. With `max_locks_per_transaction = 64` and `max_connections = 100` on both versions, we counted how many tables one transaction could lock:

| Version | max_locks_per_transaction | Tables locked in one transaction |
|---------|---------------------------|----------------------------------|
| 18.7    | 64                        | about 14,960                     |
| 19.0    | 64                        | about 8,750                      |
| 19.0    | 128                       | about 17,519                     |

Past the limit, both versions fail the same way:

```
ERROR:  out of shared memory
HINT:  You might need to increase "max_locks_per_transaction".
```

If you copy a tuned `postgresql.conf` from 18, a transaction that touches many partitions can fail on 19 with the same setting. If you never set it, the new default of 128 already covers this.

**JIT is off by default.** On one CPU-bound aggregate over 10 million cached rows, JIT made the query slower on 19: 329 ms with `jit = off` and 347 ms with `jit = on` (median of runs 2 to 5). The first JIT run took 875 ms. JIT compiled 36 functions in 26 ms per run, and the query did not gain that time back. Test your own analytic queries before you turn JIT on again. Also check `select pg_jit_available();` first: on PGDG packages, JIT is in a separate `postgresql-19-jit` package (see field notes).

**`log_lock_waits` is on.** Any session that waits longer than `deadlock_timeout` (1 s by default) for a lock now writes a log line. On a busy server this can add log volume. The release notes list it under Monitoring, not in the migration section, so it is easy to miss.

**New TOAST data uses lz4, old data stays pglz.** Values that are already stored keep their compression. We wrote 2,000 rows with pglz on 19, then ran `REPACK` and `VACUUM FULL`. Both kept pglz. Only an `UPDATE` that rewrote the value changed it to lz4:

```
 rows written with pglz          pglz|2000
 after REPACK                    pglz|2000
 after VACUUM FULL               pglz|2000
 after UPDATE body = body || ''  lz4|2000
```

**MD5 logins now warn.** MD5 still works on 19, but each login prints a warning to the client:

```
WARNING:  authenticated with an MD5-encrypted password
DETAIL:  MD5 password support is deprecated and will be removed in a future release of PostgreSQL.
```

You can silence it with `md5_password_warnings = off`. Better, move each role to SCRAM: set `password_encryption = 'scram-sha-256'`, set the password again, and change `md5` to `scram-sha-256` in `pg_hba.conf`. That worked on 19 with no warning. 19 also adds `password_expiration_warning_threshold` (7 days by default).

## What breaks when you upgrade to Postgres 19: tested

`pg_upgrade --check` stopped three of our six breakages before it touched any data. The other three passed the check and failed later: two at server start and one in a dump load that reported errors but kept going. Run the check, and also read your config files and your dump scripts.

| Breakage                                              | Caught by `pg_upgrade --check`? | Where it fails                        |
|-------------------------------------------------------|---------------------------------|---------------------------------------|
| `io_workers` in `postgresql.conf`                     | No                              | 19 refuses to start                   |
| `radius` line in `pg_hba.conf`                        | No                              | 19 refuses to start                   |
| 18 dump made with `standard_conforming_strings = off` | No (not a pg_upgrade path)      | Load into 19: errors, then wrong data |
| `btree_gist` index on `inet`/`cidr`                   | Yes                             | The check, before any data moves      |
| Database or role name with a line break               | Yes                             | The check                             |
| Extension with no 19 build (TimescaleDB)              | Yes                             | The check                             |

### 1. `io_workers` in postgresql.conf

The setting is removed. If you copy your old config, 19 does not start:

```
LOG:  unrecognized configuration parameter "io_workers" in file "/data/drill/c19/postgresql.conf" line 951
FATAL:  configuration file "/data/drill/c19/postgresql.conf" contains errors
```

Fix: delete the line. If you tuned it, set `io_min_workers` (default 2) and `io_max_workers` (default 8) instead.

### 2. RADIUS in pg_hba.conf

18 accepted the line. `pg_upgrade --check` said `*Clusters are compatible*`. Then 19 refused to start with the same `pg_hba.conf`:

```
LOG:  invalid authentication method "radius"
CONTEXT:  line 1 of configuration file "/data/drill/c19/pg_hba.conf"
FATAL:  could not load /data/drill/c19/pg_hba.conf
```

Fix: move those users to another method before the upgrade.

### 3. An old dump with standard_conforming_strings = off

This was the worst one, because part of it is silent. We set `standard_conforming_strings = off` on 18, made a table whose column default holds a Windows path, and dumped it with the 18 `pg_dump`. Loaded into 19 with `psql`, two lines fail:

```
psql:old18.sql:15: ERROR:  non-standard string literals are not supported
psql:old18.sql:20: ERROR:  unrecognized configuration parameter "escape_string_warning"
```

`psql` does not stop on errors by default, so the load goes on. The rows that come through `COPY` are correct. The DDL strings are not: the dump wrote `'C:\\temp\\new'` for the old non-standard parser, and 19 reads both backslashes. A new row now gets a different default:

```
18: default value of a new row: C:\temp\new
19: default value of a new row: C:\\temp\\new
```

Table comments change the same way. Fix: dump the 18 server with the 19 `pg_dump`. It writes `SET standard_conforming_strings = on;` and single backslashes, and the same data loads into 19 correctly. Also load dumps with `-v ON_ERROR_STOP=1`.

### 4. btree_gist indexes on inet or cidr

This is the blocker that is most likely to hit a real database. 19 removes the `btree_gist` operator classes `gist_inet_ops` and `gist_cidr_ops`, and the check refuses to continue:

```
Checking for uses of gist_inet_ops/gist_cidr_ops              fatal

Your installation contains indexes that use the btree_gist extension's
gist_inet_ops or gist_cidr_ops operator classes, which cannot be
binary-upgraded.  Replace them with indexes that use the built-in GiST
inet_ops operator class.
```

The file it names lists each index (`public.hosts_ip_gist`, `public.hosts_net_gist`). Fix: drop them on 18, upgrade, then create them again on 19. A plain `CREATE INDEX ... USING gist (ip)` picks the built-in `inet_ops`. To find them before you start, run this on 18:

```sql
SELECT n.nspname, c.relname AS table_name, i.relname AS index_name, opc.opcname
FROM pg_index x
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN unnest(x.indclass::oid[]) AS k(opcoid) ON true
JOIN pg_opclass opc ON opc.oid = k.opcoid
WHERE opc.opcname IN ('gist_inet_ops', 'gist_cidr_ops');
```

### 5. A database or role name with a line break

```
Checking names of databases, roles, and tablespaces           fatal

Your installation contains databases, roles, or tablespaces with names
with invalid characters (newline or carriage return).  To fix this,
rename these objects.
```

The file it names listed `database name = "sales\neu"` and `role name = "report\ner"` (the line break shown as `\n`). Fix: rename them on 18 with `ALTER DATABASE ... RENAME TO` and `ALTER ROLE ... RENAME TO`.

### 6. An extension with no build for 19

We installed TimescaleDB 2.32.0 on 18. PGDG has no TimescaleDB package for 19, so the check stops:

```
Checking for presence of required libraries                   fatal

Your installation references loadable libraries that are missing from the
new installation.
```

The file it names says `could not load library "timescaledb-2.32.0": ERROR: could not access file "timescaledb-2.32.0": No such file or directory`. There is no fix on your side: wait for a TimescaleDB release that supports 19.

## How to upgrade to Postgres 19: three methods, timed

On a 21.3 GB database, `pg_upgrade --link` gave 1.9 s of client downtime, `--copy` gave 5.4 minutes, `pg_dump`/`pg_restore` gave 25.6 minutes, and a logical replication cutover gave 0.3 s. Downtime here is what a client sees: a probe ran `SELECT 1` every 100 ms, and we measured the gap from its last success on 18 to its first success on 19.

### pg_upgrade

`pg_upgrade` needs the 18 and the 19 binaries on the same host. We built one Docker image with both versions from the PGDG packages, every version pinned. `tianon/postgres-upgrade` also has an `18-to-19` tag since November 24, 2026; we did not use it. The data directories are on a mounted volume. Inside that container, the sequence is:

```bash
B18=/usr/lib/postgresql/18/bin
B19=/usr/lib/postgresql/19/bin

# 1. New, empty 19 cluster. Same locale, encoding and checksum setting as 18.
$B19/initdb -D /data/c19 -U postgres -E UTF8 --locale=en_US.UTF-8

# 2. Check while 18 is still running. This is not downtime.
$B19/pg_upgrade --check -b $B18 -B $B19 -d /data/c18 -D /data/c19

# 3. Downtime starts: stop 18 cleanly, upgrade, start 19.
$B18/pg_ctl -D /data/c18 -m fast stop
$B19/pg_upgrade --link -j 4 -b $B18 -B $B19 -d /data/c18 -D /data/c19
$B19/pg_ctl -D /data/c19 -l /data/c19/server.log start

# 4. Clients are back. Fill in the statistics that did not carry over.
$B19/vacuumdb --all --analyze-in-stages --missing-stats-only
```

The check ran against the live 18 server in 0.6 s. Of the 1.9 s of downtime with `--link`, `pg_upgrade` took 1.6 s; stopping 18 and starting 19 took 0.1 s each. The data size did not matter, because `--link`, `--clone` (on XFS with reflink) and `--swap` copy no data blocks. `--copy` rewrites every file: 26 s on 1.67 GB and 320 to 326 s on 21.3 GB (about 66 MB/s on our gp3 disk), plus 21.4 GB of extra disk.

Statistics carried over: before any `ANALYZE`, 19 already had the column statistics and our extended statistics object. The `--missing-stats-only` pass took 0.07 s. `pg_upgrade` still suggests a full `vacuumdb --all --analyze-only` afterwards; clients do not need to wait for it.

The cost of `--link` and `--swap` is the rollback. Once 19 has started, the 18 directory is not safe to start: `pg_upgrade` renames `global/pg_control` to `pg_control.old` and says so. Your rollback is a backup or a standby. The `pg_upgrade` docs say `--copy` and `--clone` leave the old cluster usable; we did not start 18 again to test it.

### pg_dump and pg_restore

Use the 19 client tools, also for the dump from the 18 server (see breakage 3):

```bash
$B19/pg_dumpall -p 5432 --globals-only > globals.sql
$B19/pg_dump    -p 5432 -Fd -j 4 -f /data/dump postgres
$B19/psql       -p 5433 -f globals.sql postgres
$B19/pg_restore -p 5433 -j 4 -d postgres /data/dump
```

Writes must stop for the whole time. On 21.3 GB the dump took 2.3 minutes and the restore 23.3 minutes. The restored database had no statistics: run `ANALYZE` before you send traffic to it. This is the method to use when you move into a new managed instance, where you cannot run `pg_upgrade`.

### Logical replication: near-zero downtime

We kept 18 under load during the whole run, about 500 pgbench TPC-B transactions and 100 inserts per second. Then:

```sql
-- on 19: the schema first (19 pg_dump --schema-only | psql)
-- on 18:
CREATE PUBLICATION p FOR ALL TABLES;
-- on 19:
CREATE SUBSCRIPTION s
  CONNECTION 'host=... port=5432 dbname=postgres user=postgres'
  PUBLICATION p WITH (copy_data = true);
```

The initial copy of 21.3 GB took 13 minutes. After it, the subscriber was still behind, and it needed 90 s more to get within 16 MB of 18. Only then did we cut over: stop the writers, wait until the slot's `confirmed_flush_lsn` reached 18's current LSN, copy the sequence values, disable the subscription, and write to 19. That window was 0.32 s on 21.3 GB and 0.28 s on 1.67 GB. The row counts and `sum(abalance)` matched on both sides. The window does not include the time your application takes to switch its connection string.

Sequences do not come over from 18. Publishing them is a 19 feature, and 18 refuses it:

```
postgres=# create publication pseq for all sequences;
ERROR:  syntax error at or near "sequences"
```

If you forget them, the first insert on 19 fails:

```
ERROR:  duplicate key value violates unique constraint "orders_pkey"
DETAIL:  Key (id)=(1) already exists.
```

Copy them by hand at cutover, after the writers stop. Generate one `setval` per sequence on 18 and run the output on 19:

```sql
SELECT format('SELECT setval(%L, %s, %s);',
              schemaname || '.' || sequencename,
              coalesce(last_value, 1),
              CASE WHEN last_value IS NULL THEN 'false' ELSE 'true' END)
FROM pg_sequences;
```

DDL and large objects do not replicate either. Freeze schema changes until the cutover.

### Results

| Method                             | 1.67 GB downtime | 21.3 GB downtime             | Extra disk at 21.3 GB | Rollback after start   |
|------------------------------------|------------------|------------------------------|-----------------------|------------------------|
| `pg_upgrade --link`                | 1.9 s            | 1.8 to 1.9 s                 | under 20 MB           | Backup or standby only |
| `pg_upgrade --swap`                | 1.9 s            | 1.9 to 2.0 s                 | under 20 MB           | Backup or standby only |
| `pg_upgrade --clone` (XFS reflink) | 1.9 s            | 1.9 s                        | under 20 MB           | 18 directory unchanged |
| `pg_upgrade --copy`                | 26 s             | 320 to 326 s                 | 21.4 GB               | 18 directory unchanged |
| `pg_dump`/`pg_restore -j 4`        | 34 to 35 s       | 25.6 min                     | 43.9 GB               | 18 still running       |
| Logical replication cutover        | 0.28 s           | 0.32 s (after a 13 min copy) | 40.5 GB               | 18 still running       |

On a 21.3 GB database, `pg_upgrade --link` took 1.9 seconds of client downtime, `pg_upgrade --copy` took 5.4 minutes, and `pg_dump`/`pg_restore` took 25.6 minutes.

### Which one I would pick

If the database is on a filesystem with reflink (XFS, Btrfs), use `--clone`: about 2 s of downtime, and the 18 directory stays usable. Without reflink and with a standby or a fresh backup, use `--link`. Use `--copy` only when you cannot accept a one-way step and you have the disk and the minutes. Use logical replication when even 2 s is too much, or when you cannot run `pg_upgrade` on the host, as on a managed service. Use `pg_dump`/`pg_restore` for small databases, or when you also want to change the encoding or the server.

## Does pg_upgrade replay WAL?

No. `pg_upgrade` does not replay the old cluster's WAL and does not copy it. It needs a cleanly shut-down 18 cluster, so there is nothing to replay. The new cluster starts its WAL at a segment number after the old cluster's last one, and it has a new system identifier. That is why a base backup from 18 cannot get you past the upgrade.

We compared `pg_controldata` before and after:

```
18 after clean shutdown
  Database system identifier:        7711639022795206690
  Database cluster state:            shut down
  Latest checkpoint's REDO WAL file: 000000010000000000000056
  (pg_wal holds recycled segments up to ...00A5)

19 after pg_upgrade --link
  Database system identifier:        7711646723791454536
  Latest checkpoint's REDO WAL file: 0000000100000000000000A9
  pg_wal: ...00A8, ...00A9 (no file shared with 18)
```

**PITR does not cross the upgrade.** We took a base backup of 18 with archiving on, wrote a row on 18, upgraded, and wrote a row on 19. Then we tried two restores. 19 refuses the 18 backup:

```
FATAL:  database files are incompatible with server
DETAIL:  The data directory was initialized by PostgreSQL version 18, which is not compatible with this version 19.0.
```

18 restores the backup and replays the 18 WAL to its end, then stops and opens on a new timeline. It has the row written on 18 and not the row written on 19. So take a new base backup of 19 right after the upgrade. Until it finishes, your only path back is the 18 backup plus the 18 WAL, which ends at the upgrade.

**Use a new archive location for 19.** We kept one archive directory for both versions, with the usual `test ! -f ... && cp` command. The 19 archiver then tried to archive its own `000000010000000000000001`, a name the 18 cluster had already archived:

```
 archived_count | last_archived_wal        | failed_count | last_failed_wal
              2 | 00000001000000000000000A |            6 | 000000010000000000000001
```

With a command that does not test for the file, it would have replaced the 18 file. Point 19 at a new path, or a new bucket prefix, before you start it.

**Standbys.** A standby of 18 cannot follow 19: the system identifier is different. Build new standbys from the 19 primary. The `rsync` method in the `pg_upgrade` docs can upgrade a standby in place after `--link`, but we did not test it.

## Extensions: can you upgrade yet?

Four of the five extensions we checked work on 19 in release week; TimescaleDB does not. We installed each one from PGDG on 19.0, ran a small test, and then upgraded an 18 cluster that used the four that exist for 19.

| Extension          | Version on 19.0 (PGDG) | Installs on 19                                     | 18 to 19 with pg_upgrade                              | Selfhost.dev catalog for 19                             |
|--------------------|------------------------|----------------------------------------------------|-------------------------------------------------------|---------------------------------------------------------|
| pgvector           | 0.8.7                  | Yes (HNSW index and a nearest-neighbour query ran) | Passed; the index answered the same query             | Available                                               |
| PostGIS            | 3.7.0                  | Yes                                                | Passed; the geometry row came over                    | Available                                               |
| pg_cron            | 1.6                    | Yes (a job was scheduled)                          | Passed; the job came over                             | Available                                               |
| pg_stat_statements | 1.13                   | Yes                                                | Passed; stays at 1.12 until you run the update script | Available                                               |
| TimescaleDB        | none for 19            | No: `extension "timescaledb" is not available`     | Blocked by `--check` (breakage 6)                     | Not available: "Requires PostgreSQL 14, 15, 16, 17, 18" |

The Selfhost.dev column comes from the live extension catalog API for PostgreSQL 19 on November 24, 2026. It also lists `pg_textsearch` as not available on 19.

After the upgrade, `pg_upgrade` wrote an `update_extensions.sql`:

```
\connect postgres
ALTER EXTENSION "pg_stat_statements" UPDATE;
```

Run it with `psql` as a superuser on 19. The order of work is: update each extension to its newest version on 18, check that the same version exists for 19, upgrade, then run the update script.

## Postgres 18 vs 19: a quick benchmark

Only one of our four tests got faster on 19: a bulk insert into a table with a foreign key took half the time. pgbench, a manual parallel `VACUUM`, and autovacuum gave the same times on both versions. Both servers ran on the same host with the same settings (`shared_buffers = 4GB`, `max_wal_size = 16GB`) and the same data. For pgbench, the 19 data came from the 18 data through `pg_upgrade`, and we ran `ANALYZE` on it.

| Test                                                                            | 18.7           | 19.0           | Change           |
|---------------------------------------------------------------------------------|----------------|----------------|------------------|
| `INSERT ... SELECT` of 5M rows into a child table with an FK to a 1M-row parent | 19.7 s         | 10.0 s         | 2.0 times faster |
| The same insert without the FK                                                  | 2.6 s          | 2.5 s          | none             |
| pgbench TPC-B, scale 100, 16 clients, 4 threads, 120 s                          | 6,524 tps      | 6,536 tps      | none             |
| `VACUUM (PARALLEL 3)` on a bloated 20M-row table with 3 indexes                 | 23.3 to 24.5 s | 23.5 to 24.5 s | none             |
| Autovacuum of that table (19: `autovacuum_max_parallel_workers = 3`)            | 119.6 s        | 118.9 s        | none             |

The FK and pgbench rows are the average of runs 2 and 3; the first run of each was a cold start. In the FK test, the cost of the FK check itself went from 17.2 s to 7.4 s. The FK and vacuum tests ran on new, empty clusters of each version.

Parallel autovacuum worked, but it did not save time here. The 19 log line says `parallel workers: index vacuum: 2 planned, 2 launched in total`, and CPU time went from 6.6 s to 4.2 s, but the elapsed time stayed at about 119 s. Autovacuum's cost-based delay was at its default, and it limits the leader and the workers together, so the table was paced, not CPU-bound. We did not test with the delay off. The new setting is 0 by default, so parallel autovacuum is off until you set it.

## Postgres 19 upgrade checklist

1.  Check that every extension you use has a build for 19, and update each one on 18 first.

2.  Run the `btree_gist` query on 18; drop the `gist_inet_ops`/`gist_cidr_ops` indexes and plan to create them again on 19.

3.  Run `pg_upgrade --check` with the 19 binaries against a copy of production, and fix every `fatal` line.

4.  Remove `io_workers` from `postgresql.conf` and any `radius` line from `pg_hba.conf`, because `--check` does not see them and 19 will not start.

5.  Double any `max_locks_per_transaction` you set yourself, or remove it to get the new default of 128.

6.  Move md5 roles to `scram-sha-256` before the upgrade.

7.  Take every logical dump with the 19 `pg_dump`, and load dumps with `ON_ERROR_STOP=1`.

8.  Point the 19 cluster at a new WAL archive location before it starts.

9.  Right after the upgrade, run `vacuumdb --all --analyze-in-stages --missing-stats-only`, then `update_extensions.sql`, then a new base backup.

10. Build new standbys from the 19 primary, and test your analytic queries with JIT off (the new default) and on.

## Field notes: what I got wrong the first time

- **My first logical cutover took 21.7 s, not 0.3 s.** I cut over 30 s after the 13-minute copy ended, while the subscriber was still applying the backlog. After I waited for the lag to drop below 16 MB (90 s more), it took 0.32 s. Watch the lag, not the clock.

- **My sequence copy wrote `setval(..., t)`.** `format('%s', boolean)` prints `t`, so every `setval` failed, and `psql` without `ON_ERROR_STOP` hid it. The first insert on 19 then hit a duplicate key.

- **My image had no JIT.** JIT is in `postgresql-19-jit`, which `--no-install-recommends` skipped, so my first JIT test compared nothing. Run `select pg_jit_available();` first.

- **My first JIT query measured the disk.** It read 21 GB at about 125 MB/s, so both runs took 110 s. I moved it to a dataset that fits in memory.

- **`kill -INT` did not stop pgbench.** A non-interactive shell starts background jobs with SIGINT ignored. Use `kill -TERM`.

- **I expected `REPACK` to recompress old pglz data as lz4.** It did not, and neither did `VACUUM FULL`.

## Should you upgrade to Postgres 19 now?

Yes, if your extensions are ready and you fix the checklist items first: the upgrade itself took under 2 s of downtime. Wait if one of these applies to you.

**Upgrade now if:**

- every extension you use has a 19 build (pgvector, PostGIS, pg_cron and pg_stat_statements do);

- you have no `gist_inet_ops`/`gist_cidr_ops` indexes, or you can rebuild them after the upgrade;

- you can take about 2 s of downtime (`--link`, `--clone` or `--swap`) or set up logical replication;

- you have a standby or a fresh backup for rollback, or you use `--clone`.

**Wait if:**

- you use TimescaleDB, or `pg_textsearch` on Selfhost.dev: there is no build for 19 yet;

- you run many partitions with a tuned `max_locks_per_transaction` and have not tested the doubled value;

- your analytic workload depends on JIT and you have not compared it on 19;

- your standby and PITR setup cannot be rebuilt right after the upgrade.

If you can upgrade now, start with `pg_upgrade --check` on a copy of production today. If you have to wait, run the `btree_gist` query and clean your config files on 18 now, so the upgrade day is short.


## Frequently asked questions

### When is Postgres 19 released?

PostgreSQL 19 was released on November 19, 2026; we tested the 19.0 packages from PGDG on November 24. The PostgreSQL project supports it until November 19, 2031, five years after the first release. On Selfhost.dev, the API accepts version 19 for new databases, and 18 stays the default.

### Does Postgres 19 include SQL/PGQ graph queries?

No. SQL/PGQ was pulled before the release. On 19.0, `CREATE PROPERTY GRAPH` fails with `syntax error at or near "property"`, and `GRAPH_TABLE` fails the same way. `MERGE PARTITIONS`, `SPLIT PARTITION`, `FOR PORTION OF`, online checksum changes and the `pg_get_*_ddl()` functions were pulled too.

### How long does pg_upgrade take?

With `--link`, `--clone` or `--swap`, clients were down for about 1.9 seconds on both a 1.67 GB and a 21.3 GB database, because no data blocks are copied. With `--copy`, downtime grows with the data: 26 seconds for 1.67 GB and about 5.4 minutes for 21.3 GB on our gp3 disk.

### Does pg_upgrade replay WAL?

No. `pg_upgrade` needs a cleanly stopped old cluster and does not copy or replay its WAL. The new cluster starts its WAL after the old one's last segment and has a new system identifier. So an 18 base backup cannot restore past the upgrade: take a new base backup of 19 right away.

### Can I upgrade from Postgres 16 directly to 19?

The `pg_upgrade` docs support upgrades "from 9.2.X and later to the current major release", so 16 to 19 is one step. We tested only 18 to 19. The 19 breakages in this post should apply to a 16 or 17 cluster too, plus the changes in 17 and 18.

### Is Postgres 19 ready for production on day one?

The server is. In our tests, 19.0 upgraded cleanly, kept every row and sequence value, and ran pgbench at the same speed as 18. Your extensions decide it: TimescaleDB has no 19 build yet. Fix the config items `pg_upgrade --check` does not catch before you start.
