#!/bin/bash
# Time pg_dump (19 client, directory format, -j 4) from 18 -> pg_restore -j 4 into a new 19.
# Usage: dump-restore.sh <small|large> [run#]
# Downtime = writes must stop for the whole dump + restore. We count from the
# start of pg_dump to the end of pg_restore (+ globals). Reads could continue on 18.
source /lab/lib.sh
size=$1 run=${2:-1}
work=/data/run tag="dump-$size-$run"
raw=$RESULTS/raw/$tag; rm -rf -- "${raw:?}"; mkdir -p "$raw"
rm -rf -- "${work:?}"; mkdir -p "$work"
cp -a --reflink=always "/data/pristine-$size/c18" "$work/c18"
init_cluster 19 "$work/c19" 5433
pg_start 18 "$work/c18"; pg_start 19 "$work/c19"
rows18=$(q 18 5432 -c "select count(*) from pgbench_accounts")
seq18=$(q 18 5432 -c "select last_value from orders_id_seq")

rm -f "$raw/stop"; disk0=$(disk_used_bytes)
disk_sampler "$raw/disk.txt" "$raw/stop" & sampler=$!

t0=$(now_ms)
"$B19/pg_dumpall" -p 5432 --globals-only > "$work/globals.sql"
"$B19/pg_dump" -p 5432 -Fd -j 4 -f "$work/dump" postgres > "$raw/dump.txt" 2>&1
t1=$(now_ms)
"$B19/psql" -X -q -p 5433 -f "$work/globals.sql" postgres > "$raw/globals.txt" 2>&1 || true   # "role postgres already exists" is expected
"$B19/pg_restore" -p 5433 -j 4 -d postgres "$work/dump" > "$raw/restore.txt" 2>&1
t2=$(now_ms)
touch "$raw/stop"; wait "$sampler" || true
peak=$(sort -n "$raw/disk.txt" | tail -1)
dump_bytes=$(du -sb "$work/dump" | cut -f1)

stats_cols=$(q 19 5433 -c "select count(*) from pg_stats where schemaname='public'")
stats_ext=$(q 19 5433 -c "select count(*) from pg_stats_ext where statistics_name='accounts_aid_bid' and n_distinct is not null")
rows19=$(q 19 5433 -c "select count(*) from pgbench_accounts")
seq19=$(q 19 5433 -c "select last_value from orders_id_seq")
t=$(now_ms)
"$B19/vacuumdb" -p 5433 --all --analyze-in-stages --missing-stats-only > "$raw/analyze.txt" 2>&1
analyze_ms=$(( $(now_ms) - t ))
pg_stop 18 "$work/c18"; pg_stop 19 "$work/c19"
[ "$rows18" = "$rows19" ] && [ "$seq18" = "$seq19" ] || { log "MISMATCH rows $rows18/$rows19 seq $seq18/$seq19"; exit 1; }

log "$tag: downtime=$((t2-t0))ms dump=$((t1-t0))ms restore=$((t2-t1))ms extra_disk=$(((peak-disk0)/1048576))MB dump_size=$((dump_bytes/1048576))MB analyze=${analyze_ms}ms stats_cols=$stats_cols ext=$stats_ext"
csv_row upgrades.csv "pg_dump/pg_restore -j4" "$size" "$run" "$((t2-t0))" "$((t2-t1))" "$((t1-t0))" "" "$((peak-disk0))" "" "$analyze_ms" "$stats_cols" "$stats_ext" "" "$(date -u +%FT%TZ)"
