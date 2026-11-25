# Raw numbers: PostgreSQL 18.7 -> 19.0 (2026-11-24)

Host: AWS EC2 m7i.xlarge (4 vCPU, 16 GB RAM), ap-south-1b, 200 GB gp3 (3,000 IOPS, 125 MB/s), XFS with reflink, Docker 26.1.5. PGDG 18.7-1.pgdg13+5 and 19.0-2.pgdg13+1. Every run started after `echo 3 > /proc/sys/vm/drop_caches`. Source CSVs: `upgrades.csv`, `bench.csv`, `datasets.csv`; raw logs per run in `raw/`.

## Datasets

| Name | pgbench scale | Size (pg_database_size, GB) | Load time (s) |
|---|---|---|---|
| small | 100 | 1.67 | 34 |
| large | 1300 | 21.32 | 861 |

## pg_upgrade runs

Downtime = client view (probe `SELECT 1` every 100 ms): last OK on 18 to first OK on 19.

| Mode | Dataset | Run | Downtime (s) | pg_upgrade (s) | Stop 18 (s) | Start 19 (s) | Peak extra disk (GB) | --check, live (s) | analyze --missing-stats-only (s) | Ext. stats before ANALYZE |
|---|---|---|---|---|---|---|---|---|---|---|
| pg_upgrade --copy | small | 1 | 26.01 | 25.70 | 0.10 | 0.11 | 1.65 | 0.60 | 0.05 | 1 |
| pg_upgrade --link | small | 1 | 1.87 | 1.61 | 0.10 | 0.11 | 0.03 | 0.60 | 0.05 | 1 |
| pg_upgrade --clone | small | 1 | 1.87 | 1.61 | 0.10 | 0.11 | 0.05 | 0.60 | 0.05 | 1 |
| pg_upgrade --swap | small | 1 | 1.87 | 1.61 | 0.10 | 0.11 | 0.01 | 0.60 | 0.05 | 1 |
| pg_upgrade --copy | small | 2 | 26.00 | 25.70 | 0.10 | 0.11 | 1.65 | 0.60 | 0.05 | 1 |
| pg_upgrade --link | small | 2 | 1.87 | 1.60 | 0.10 | 0.11 | 0.01 | 0.59 | 0.05 | 1 |
| pg_upgrade --clone | small | 2 | 1.87 | 1.60 | 0.10 | 0.11 | 0.01 | 0.59 | 0.05 | 1 |
| pg_upgrade --swap | small | 2 | 1.87 | 1.64 | 0.10 | 0.11 | 0.01 | 0.59 | 0.05 | 1 |
| pg_upgrade --copy | small | 3 | 26.01 | 25.70 | 0.10 | 0.11 | 1.65 | 0.64 | 0.05 | 1 |
| pg_upgrade --link | small | 3 | 1.87 | 1.57 | 0.10 | 0.11 | 0.01 | 0.61 | 0.05 | 1 |
| pg_upgrade --clone | small | 3 | 1.87 | 1.60 | 0.10 | 0.11 | 0.01 | 0.59 | 0.05 | 1 |
| pg_upgrade --swap | small | 3 | 1.87 | 1.64 | 0.10 | 0.11 | 0.01 | 0.58 | 0.05 | 1 |
| pg_upgrade --copy | large | 1 | 326.15 | 325.91 | 0.10 | 0.11 | 21.43 | 0.66 | 0.07 | 1 |
| pg_upgrade --link | large | 1 | 1.87 | 1.61 | 0.10 | 0.11 | 0.02 | 0.63 | 0.06 | 1 |
| pg_upgrade --clone | large | 1 | 1.91 | 1.64 | 0.10 | 0.11 | 0.02 | 0.62 | 0.06 | 1 |
| pg_upgrade --swap | large | 1 | 1.98 | 1.64 | 0.10 | 0.11 | 0.02 | 0.63 | 0.06 | 1 |
| pg_upgrade --copy | large | 2 | 320.44 | 320.12 | 0.10 | 0.11 | 21.43 | 0.60 | 0.06 | 1 |
| pg_upgrade --link | large | 2 | 1.78 | 1.57 | 0.10 | 0.11 | 0.00 | 0.59 | 0.06 | 1 |
| pg_upgrade --clone | large | 2 | 1.92 | 1.61 | 0.10 | 0.11 | 0.02 | 0.61 | 0.05 | 1 |
| pg_upgrade --swap | large | 2 | 1.90 | 1.63 | 0.10 | 0.11 | 0.01 | 0.61 | 0.05 | 1 |

## pg_dump / pg_restore runs (19 client tools, -Fd -j 4)

Downtime = start of pg_dump to end of pg_restore (writes stopped the whole time).

| Dataset | Run | Downtime (s) | pg_dump (s) | pg_restore (s) | Peak extra disk (GB) | Column stats after restore |
|---|---|---|---|---|---|---|
| small | 1 | 34.08 | 9.70 | 24.38 | 3.25 | 0 |
| small | 2 | 35.16 | 9.68 | 25.48 | 3.25 | 0 |
| small | 3 | 34.07 | 9.71 | 24.36 | 3.25 | 0 |
| large | 1 | 1535.01 | 136.11 | 1398.90 | 43.93 | 10 |

## Logical replication runs (18 publisher, 19 subscriber, live writes ~500 TPC-B tx/s + ~100 inserts/s)

Cutover = writers stopped on 18 to first successful write on 19 (catch-up + sequence copy + disable subscription).

| Dataset | Run | Cutover (s) | Initial copy (s) | Catch-up part of cutover (s) | Extra disk after copy (GB) | Note |
|---|---|---|---|---|---|---|
| small | 1 | 0.28 | 54.25 | 0.24 | 4.21 |  |
| large | 1 | 21.68 | 776.95 | 21.63 | 41.30 | INVALID as a cutover number: cut over with backlog (see field notes) |
| large | 2 | 0.32 | 776.93 | 0.26 | 40.49 | waited for lag < 16 MB first (drain 89.7 s) |

## Benchmarks (same host, same settings)

| Test | Version | Run | Result |
|---|---|---|---|
| vacuum | 18 | 1 | vacuum_parallel3_ms=23298 · launched 2 parallel vacuum workers for index vacuuming (planned: 2 |
| vacuum | 18 | 2 | vacuum_parallel3_ms=24463 · launched 2 parallel vacuum workers for index vacuuming (planned: 2 |
| vacuum | 19 | 1 | vacuum_parallel3_ms=23458 · launched 2 parallel vacuum workers for index vacuuming (planned: 2 |
| vacuum | 19 | 2 | vacuum_parallel3_ms=24459 · launched 2 parallel vacuum workers for index vacuuming (planned: 2 |
| pgbench | 18 | 1 | tps=4291.804019 · latency_ms=3.728 |
| pgbench | 19 | 1 | tps=6211.244921 · latency_ms=2.576 |
| pgbench | 18 | 2 | tps=6563.171911 · latency_ms=2.438 |
| pgbench | 19 | 2 | tps=6525.439497 · latency_ms=2.452 |
| pgbench | 18 | 3 | tps=6485.456698 · latency_ms=2.467 |
| pgbench | 19 | 3 | tps=6546.720841 · latency_ms=2.444 |
| autovacuum | 18 | 1 | autovacuum_elapsed: 119.63 s |
| autovacuum | 19 | 1 | autovacuum_elapsed: 118.93 s · parallel workers: index vacuum: 2 planned |
| jit | 19 | 1 | jit=off · ms=330 |
| jit | 19 | 1 | jit=on · ms=875 |
| jit | 19 | 2 | jit=off · ms=331 |
| jit | 19 | 2 | jit=on · ms=348 |
| jit | 19 | 3 | jit=off · ms=328 |
| jit | 19 | 3 | jit=on · ms=349 |
| jit | 19 | 4 | jit=off · ms=326 |
| jit | 19 | 4 | jit=on · ms=346 |
| jit | 19 | 5 | jit=off · ms=330 |
| jit | 19 | 5 | jit=on · ms=346 |
| fk | 18 | 1 | with_fk_ms=21191 · no_fk_ms=2567 · fk_cost_ms=18624 |
| fk | 18 | 2 | with_fk_ms=19707 · no_fk_ms=2594 · fk_cost_ms=17113 |
| fk | 18 | 3 | with_fk_ms=19736 · no_fk_ms=2568 · fk_cost_ms=17168 |
| fk | 19 | 1 | with_fk_ms=11638 · no_fk_ms=2537 · fk_cost_ms=9101 |
| fk | 19 | 2 | with_fk_ms=10009 · no_fk_ms=2538 · fk_cost_ms=7471 |
| fk | 19 | 3 | with_fk_ms=9932 · no_fk_ms=2515 · fk_cost_ms=7417 |

Notes: pgbench and FK run 1 are cold starts; the post uses runs 2-3. JIT runs are on 19 only, with `postgresql-19-jit` installed. Earlier JIT/FK runs without the JIT package were discarded (see `notes/field-notes.md`).
