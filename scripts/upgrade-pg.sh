#!/bin/bash
# Time one pg_upgrade run, 18 -> 19.
# Usage: upgrade-pg.sh <copy|link|clone|swap> <small|large> [run#]
# The host wrapper drops the page cache before this script starts.
#
# Timeline (client view, from probe.sh):
#   18 up -> pg_upgrade --check (live, not downtime) -> stop 18 -> pg_upgrade --<mode>
#   -> start 19 -> first OK = end of downtime. ANALYZE runs after, while clients are back.
source /lab/lib.sh
mode=${1:-} size=${2:-} run=${3:-1}
case $mode in copy|link|clone|swap) ;; *) echo "mode must be copy|link|clone|swap" >&2; exit 64 ;; esac
case $size in small|large) ;; *) echo "size must be small|large" >&2; exit 64 ;; esac
case $run in *[!0-9]*|"") echo "run must be a number" >&2; exit 64 ;; esac
work=/data/run
tag="pg-$mode-$size-$run"
raw=$RESULTS/raw/$tag; rm -rf -- "${raw:?}"; mkdir -p "$raw"

rm -rf -- "${work:?}"; mkdir -p "$work"
cp -a --reflink=always "/data/pristine-$size/c18" "$work/c18"   # cheap, shares blocks with pristine
init_cluster 19 "$work/c19"
sync

pg_start 18 "$work/c18"
rows18=$(q 18 5432 -c "select count(*) from pgbench_accounts")
seq18=$(q 18 5432 -c "select last_value from orders_id_seq")

rm -f "$raw/stop"
/lab/probe.sh "$raw/probe.csv" "$raw/stop" &
probe=$!
disk0=$(disk_used_bytes)
disk_sampler "$raw/disk.txt" "$raw/stop" &
sampler=$!
sleep 2

cd "$work" || exit 1
# 1. Check against the live old server. Not part of downtime.
t=$(now_ms)
"$B19/pg_upgrade" --check -b "$B18" -B "$B19" -d "$work/c18" -D "$work/c19" > "$raw/check.txt" 2>&1
check_ms=$(( $(now_ms) - t ))

# 2. Downtime starts here.
t_stop=$(now_ms)
pg_stop 18 "$work/c18"
t_up0=$(now_ms)
"$B19/pg_upgrade" --"$mode" -j 4 -b "$B18" -B "$B19" -d "$work/c18" -D "$work/c19" > "$raw/upgrade.txt" 2>&1
t_up1=$(now_ms)
pg_start 19 "$work/c19"
t_start=$(now_ms)
sleep 2
touch "$raw/stop"; wait "$probe" "$sampler" || true

read -r gap_ms _ < <(/lab/gap.sh "$raw/probe.csv")
peak=$(sort -n "$raw/disk.txt" | tail -1)
extra_bytes=$(( peak - disk0 ))

# 3. What carried over before any ANALYZE.
stats_cols=$(q 19 5432 -c "select count(*) from pg_stats where schemaname='public'")
stats_ext=$(q 19 5432 -c "select count(*) from pg_stats_ext where statistics_name='accounts_aid_bid' and n_distinct is not null")
rows19=$(q 19 5432 -c "select count(*) from pgbench_accounts")
seq19=$(q 19 5432 -c "select last_value from orders_id_seq")

# 4. Post-upgrade ANALYZE (clients are already back).
t=$(now_ms)
"$B19/vacuumdb" -p 5432 --all --analyze-in-stages --missing-stats-only > "$raw/analyze.txt" 2>&1 || \
  "$B19/vacuumdb" -p 5432 --all --analyze-in-stages >> "$raw/analyze.txt" 2>&1
analyze_ms=$(( $(now_ms) - t ))
stats_ext_after=$(q 19 5432 -c "select count(*) from pg_stats_ext where statistics_name='accounts_aid_bid' and n_distinct is not null")
pg_stop 19 "$work/c19"

[ "$rows18" = "$rows19" ] && [ "$seq18" = "$seq19" ] || { log "MISMATCH rows $rows18/$rows19 seq $seq18/$seq19"; exit 1; }

log "$tag: downtime=${gap_ms}ms pg_upgrade=$((t_up1-t_up0))ms stop=$((t_up0-t_stop))ms start=$((t_start-t_up1))ms extra_disk=$((extra_bytes/1048576))MB check=${check_ms}ms analyze=${analyze_ms}ms stats_cols=$stats_cols ext_before=$stats_ext ext_after=$stats_ext_after"
csv_row upgrades.csv "pg_upgrade --$mode" "$size" "$run" "$gap_ms" "$((t_up1-t_up0))" "$((t_up0-t_stop))" "$((t_start-t_up1))" "$extra_bytes" "$check_ms" "$analyze_ms" "$stats_cols" "$stats_ext" "$stats_ext_after" "$(date -u +%FT%TZ)"
