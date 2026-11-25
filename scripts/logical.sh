#!/bin/bash
# Logical replication 18 -> 19 with live writes, then a timed cutover.
# Usage: logical.sh <small|large> [run#]
#
# 1. 18 (5432) keeps taking writes: pgbench tpcb-like + inserts into orders (identity column).
# 2. 19 (5433) gets the schema from the 19 pg_dump --schema-only.
# 3. Publication on 18, subscription on 19 (copy_data). Time the initial sync.
# 4. Cutover window = stop writers on 18 -> 19 has every change -> sequences fixed
#    -> first successful write on 19.
source /lab/lib.sh
size=$1 run=${2:-1}
work=/data/run tag="logical-$size-$run"
raw=$RESULTS/raw/$tag; rm -rf -- "${raw:?}"; mkdir -p "$raw"
rm -rf -- "${work:?}"; mkdir -p "$work"
cp -a --reflink=always "/data/pristine-$size/c18" "$work/c18"
init_cluster 19 "$work/c19" 5433
pg_start 18 "$work/c18"; pg_start 19 "$work/c19"
disk0=$(disk_used_bytes)

# pgbench_history has no primary key; INSERT-only, so it replicates. Give it one anyway
# would change the dataset, so we leave it.
"$B19/pg_dump" -p 5432 --schema-only postgres | "$B19/psql" -X -q -p 5433 postgres > "$raw/schema.txt" 2>&1

cat > "$work/orders.sql" <<'SQL'
\set aid random(1, 100000)
insert into orders (aid, note) values (:aid, 'live');
SQL
# Writers: ~500 tpcb tx/s + ~100 orders/s. Runs until killed.
"$B18/pgbench" -p 5432 -n -c 4 -j 2 -T 36000 -R 500 -b tpcb-like postgres > "$raw/pgbench-tpcb.txt" 2>&1 & w1=$!
"$B18/pgbench" -p 5432 -n -c 1 -j 1 -T 36000 -R 100 -f "$work/orders.sql" postgres > "$raw/pgbench-orders.txt" 2>&1 & w2=$!
sleep 3

{
  echo "### 18: try to publish sequences (a 19 feature)"
  q 18 5432 -c "create publication pseq for all sequences" 2>&1 || true
} > "$raw/sequences.txt"
q 18 5432 -c "create publication p for all tables"

t0=$(now_ms)
q 19 5433 -c "create subscription s connection 'host=/tmp port=5432 dbname=postgres user=postgres' publication p with (copy_data = true)"
until [ "$(q 19 5433 -c "select count(*) from pg_subscription_rel where srsubstate <> 'r'")" = 0 ]; do sleep 2; done
t_sync=$(now_ms)
sync_disk=$(( $(disk_used_bytes) - disk0 ))
# Drain the backlog that built up during the initial copy: wait until the slot is < 16 MB behind.
until [ "$(q 18 5432 -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) < 16*1024*1024 from pg_replication_slots where slot_name='s'")" = t ]; do sleep 1; done
t_drained=$(now_ms)
sleep 30   # steady state with live writes
lag_bytes=$(q 18 5432 -c "select pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) from pg_replication_slots where slot_name='s'")

# ---- cutover ----
t_cut=$(now_ms)
kill -TERM $w1 $w2; wait $w1 $w2 2>/dev/null || true
lsn=$(q 18 5432 -c "select pg_current_wal_lsn()")
deadline=$(( $(now_ms) + 300000 ))
until [ "$(q 18 5432 -c "select confirmed_flush_lsn >= '$lsn' from pg_replication_slots where slot_name='s'")" = t ]; do
  [ "$(now_ms)" -lt "$deadline" ] || { log "catch-up timeout"; exit 1; }
  sleep 0.05
done
t_caught=$(now_ms)

seq18=$(q 18 5432 -c "select last_value from orders_id_seq")
seq19_before=$(q 19 5433 -c "select coalesce(last_value, 0) from orders_id_seq")
{
  echo "### 19 sequence before fix: $seq19_before (18 has $seq18)"
  echo "### 19: insert before the sequence fix"
  q 19 5433 -c "insert into orders (aid, note) values (1, 'too early')" 2>&1 || true
} >> "$raw/sequences.txt"
# Copy every sequence value from 18 to 19 (setval).
q 18 5432 -c "select format('select setval(%L, %s, %s);', schemaname||'.'||sequencename, coalesce(last_value, 1), case when last_value is null then 'false' else 'true' end) from pg_sequences" \
  | q 19 5433 > /dev/null
q 19 5433 -c "alter subscription s disable"
q 19 5433 -c "insert into orders (aid, note) values (1, 'first write on 19') returning id" > "$raw/first-write.txt"
t_first=$(now_ms)

# Same data on both sides?
chk() { q "$1" "$2" -c "select (select count(*) from pgbench_history), (select sum(abalance) from pgbench_accounts), (select count(*) from orders where note <> 'first write on 19')"; }
c18=$(chk 18 5432); c19=$(chk 19 5433)
echo "18: $c18 / 19: $c19" > "$raw/compare.txt"

q 19 5433 -c "alter subscription s set (slot_name = none)" -c "drop subscription s" >/dev/null
q 18 5432 -c "select pg_drop_replication_slot('s')" >/dev/null 2>&1 || true
pg_stop 18 "$work/c18"; pg_stop 19 "$work/c19"
[ "$c18" = "$c19" ] || { log "MISMATCH $c18 vs $c19"; exit 1; }

log "$tag: drain=$((t_drained-t_sync))ms lag_at_cutover=${lag_bytes}B initial_sync=$((t_sync-t0))ms cutover=$((t_first-t_cut))ms (catch-up=$((t_caught-t_cut))ms) extra_disk=$((sync_disk/1048576))MB seq18=$seq18 seq19_before=$seq19_before"
csv_row upgrades.csv "logical replication" "$size" "$run" "$((t_first-t_cut))" "$((t_sync-t0))" "$((t_caught-t_cut))" "" "$sync_disk" "" "" "" "" "" "$(date -u +%FT%TZ)"
