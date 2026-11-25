# pg19-upgrade-tests

Tests behind the post "Upgrading to Postgres 19: What Breaks, and How Long pg_upgrade Takes (Tested)".
PostgreSQL 18.7 -> 19.0 (PGDG), run on 2026-11-24 on one AWS EC2 m7i.xlarge (ap-south-1, 200 GB gp3, XFS with reflink).

## Hand-in

| What | Where |
|---|---|
| The post (Markdown export of the shared draft) | `post/upgrading-to-postgres-19.md` |
| Raw numbers sheet | `results/numbers.md` (source CSVs: `results/*.csv`) |
| Raw output of every run | `results/raw/` |
| Mistakes made during the tests | `notes/field-notes.md` |

## Scripts

| Script | What it does |
|---|---|
| `Dockerfile` | One image with PostgreSQL 18.7 and 19.0 (+ JIT, pgvector, PostGIS, pg_cron; TimescaleDB for 18 only), all versions pinned |
| `run.sh` | Host side: drops the page cache, then runs one script in the `lab` container |
| `campaign.sh` | Runs every measurement in order |
| `scripts/lib.sh` | Shared helpers and the `postgresql.conf` used on both versions |
| `scripts/load.sh` | Builds the 1.67 GB (`small`) and 21.3 GB (`large`) 18.7 datasets |
| `scripts/probe.sh`, `scripts/gap.sh` | Client-side downtime: `SELECT 1` every 100 ms, longest outage |
| `scripts/upgrade-pg.sh` | Times `pg_upgrade --copy/--link/--clone/--swap` |
| `scripts/dump-restore.sh` | Times `pg_dump -Fd -j4` / `pg_restore -j4` |
| `scripts/logical.sh` | Logical replication 18 -> 19 under load, then a timed cutover |
| `scripts/wal.sh`, `scripts/archive-collision.sh` | WAL, PITR and WAL archive behaviour across the upgrade |
| `scripts/drills.sh` | Breaks the upgrade on purpose and keeps the exact errors |
| `scripts/extensions.sh` | Extensions on 19 and an upgrade with them |
| `scripts/settings-diff.sh` | 18 vs 19 built-in defaults (`pg_settings.boot_val`) |
| `scripts/bench.sh` | pgbench, FK insert, VACUUM, autovacuum, JIT |

## Run it

On a Linux host with Docker and a reflink-capable filesystem mounted at `/data`:

```sh
docker build -t pg19lab .
sudo chown -R "$(docker run --rm pg19lab id -u):$(docker run --rm pg19lab id -g)" /data
docker run -d --init --name lab --shm-size=6g -v /data:/data -v "$PWD/scripts:/lab:ro" pg19lab
./run.sh load.sh small && ./run.sh load.sh large
./run.sh settings-diff.sh && ./run.sh drills.sh && ./run.sh wal.sh && ./run.sh extensions.sh
./campaign.sh upgrades dump logical bench
```

Results land in `/data/results`; `campaign.log` keeps every run's full output and marks a failed run `FAILED`.

## Lab only

These scripts build throwaway clusters for measurement. Do not copy their settings to a real server:

- Every cluster uses `trust` authentication and listens only on a Unix socket in the container's `/tmp`
  (`listen_addresses = ''`): no TCP port is open. Anything that runs inside the container is a superuser.
- The container runs as the image's `postgres` user, with `/data` mounted read-write and the scripts
  read-only. `run.sh` only runs the scripts listed in it.
- `run.sh` uses `sudo` to drop the page cache before each run, so timings start cold.
- The drills write deliberately broken settings and dummy passwords (`secret`) to show the errors.
