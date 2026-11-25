#!/bin/bash
# 18 vs 19 on the same box, same settings, same data.
# Usage: bench.sh <pgbench|fk|vacuum|autovacuum|jit>   -> results/bench.csv + results/raw/bench-*
source /lab/lib.sh
what=$1
raw=$RESULTS/raw/bench-$what; mkdir -p "$raw"
W=/data/bench

# 18 = the pristine copy. 19 = the same data through pg_upgrade --clone, then ANALYZE.
pair() {
  local size=$1
  for v in 18 19; do pg_stop $v $W/c$v 2>/dev/null || true; done
  rm -rf -- "${W:?}"; mkdir -p $W
  cp -a --reflink=always /data/pristine-$size/c18 $W/c18
  init_cluster 19 $W/c19
  (cd $W && "$B19/pg_upgrade" --clone -b "$B18" -B "$B19" -d $W/c18 -D $W/c19 >/dev/null)
  rm -f $W/c18/global/pg_control.old 2>/dev/null
  rm -rf -- "${W:?}/c18"; cp -a --reflink=always /data/pristine-$size/c18 $W/c18   # untouched 18 copy
  pg_start 19 $W/c19; "$B19/vacuumdb" -p 5432 --all --analyze-only -q; pg_stop 19 $W/c19
}
empty() { for v in 18 19; do pg_stop $v $W/c$v 2>/dev/null || true; done; rm -rf -- "${W:?}"; mkdir -p $W; init_cluster 18 $W/c18; init_cluster 19 $W/c19; }
row() { csv_row bench.csv "$what" "$@" "$(date -u +%FT%TZ)"; log "$what $*"; }

case $what in
pgbench)   # TPC-B, scale 100, 16 clients, 4 threads, 120 s, 3 rounds alternating 18/19
  pair small
  for r in 1 2 3; do for v in 18 19; do
    pg_start $v $W/c$v; q $v 5432 -c checkpoint
    "$(binfor $v)/pgbench" -p 5432 -n -c 16 -j 4 -T 120 postgres > "$raw/$v-$r.txt" 2>&1
    tps=$(sed -n 's/^tps = \([0-9.]*\).*/\1/p' "$raw/$v-$r.txt"); lat=$(sed -n 's/^latency average = \([0-9.]*\) ms/\1/p' "$raw/$v-$r.txt")
    row "$v" "$r" "tps=$tps" "latency_ms=$lat"
    pg_stop $v $W/c$v
  done; done ;;

fk)        # INSERT ... SELECT 5M rows into a child table with a foreign key to a 1M-row parent
  empty
  for v in 18 19; do pg_start $v $W/c$v
    q $v 5432 -c "create table parent (id int primary key)" -c "insert into parent select generate_series(1, 1000000)" -c "vacuum analyze parent"
    for r in 1 2 3; do
      q $v 5432 -c "drop table if exists child" -c "create table child (id bigint, pid int references parent)" -c checkpoint
      t=$(now_ms); q $v 5432 -c "insert into child select g, (g % 1000000) + 1 from generate_series(1, 5000000) g"; ms=$(( $(now_ms) - t ))
      q $v 5432 -c "drop table child" -c "create table child (id bigint, pid int)" -c checkpoint
      t=$(now_ms); q $v 5432 -c "insert into child select g, (g % 1000000) + 1 from generate_series(1, 5000000) g"; base=$(( $(now_ms) - t ))
      row "$v" "$r" "with_fk_ms=$ms" "no_fk_ms=$base" "fk_cost_ms=$((ms-base))"
    done
    pg_stop $v $W/c$v; done ;;

vacuum)    # manual VACUUM (PARALLEL 3) on a bloated 20M-row table with 3 indexes
  empty
  for v in 18 19; do pg_start $v $W/c$v
    for r in 1 2; do
      q $v 5432 -c "set client_min_messages=warning" -c "drop table if exists bloat" -c "create table bloat (id int primary key, a int, b text) with (autovacuum_enabled = off)" \
        -c "insert into bloat select g, g % 1000, md5(g::text) from generate_series(1, 20000000) g" \
        -c "create index on bloat (a)" -c "create index on bloat (b)" -c "vacuum (analyze) bloat" \
        -c "update bloat set a = a + 1 where id % 5 = 0" -c "delete from bloat where id % 7 = 0" -c checkpoint
      t=$(now_ms); q $v 5432 -c "vacuum (parallel 3, verbose) bloat" > "$raw/$v-$r.txt" 2>&1; ms=$(( $(now_ms) - t ))
      w=$(grep -o "launched [0-9]* parallel vacuum workers[^)]*" "$raw/$v-$r.txt" | head -1)
      row "$v" "$r" "vacuum_parallel3_ms=$ms" "$w"
    done
    pg_stop $v $W/c$v; done ;;

autovacuum) # the same bloat, but let autovacuum do it; read the elapsed time from the log
  empty
  for v in 18 19; do
    cat >> $W/c$v/postgresql.conf <<EOF
log_autovacuum_min_duration = 0
autovacuum_naptime = 5s
EOF
    [ $v = 19 ] && echo "autovacuum_max_parallel_workers = 3" >> $W/c19/postgresql.conf
    pg_start $v $W/c$v
    [ $v = 19 ] && q 19 5432 -c "select name, setting, short_desc from pg_settings where name like 'autovacuum%parallel%'" > "$raw/19-settings.txt"
    q $v 5432 -c "set client_min_messages=warning" -c "create table bloat (id int primary key, a int, b text) with (autovacuum_enabled = off)" \
      -c "insert into bloat select g, g % 1000, md5(g::text) from generate_series(1, 20000000) g" \
      -c "create index on bloat (a)" -c "create index on bloat (b)" -c "vacuum (analyze) bloat" \
      -c "update bloat set a = a + 1 where id % 5 = 0" -c "delete from bloat where id % 7 = 0" -c checkpoint
    : > $W/c$v/server.log.mark; lines=$(wc -l < $W/c$v/server.log)
    q $v 5432 -c "alter table bloat set (autovacuum_enabled = on)"
    until tail -n +$((lines+1)) $W/c$v/server.log | grep -q 'automatic vacuum of table "postgres.public.bloat"'; do sleep 2; done
    sleep 1
    tail -n +$((lines+1)) $W/c$v/server.log | sed -n '/automatic vacuum of table "postgres.public.bloat"/,/system usage/p' > "$raw/$v.txt"
    el=$(grep -o 'elapsed: [0-9.]* s' "$raw/$v.txt" | head -1 || true); pw=$(grep -io 'parallel[^,]*' "$raw/$v.txt" | head -1 || true)
    row "$v" 1 "autovacuum_$el" "$pw"
    pg_stop $v $W/c$v; done ;;

jit)       # one analytic query on the small dataset (fits in shared_buffers: CPU-bound), 19, jit off (default) vs on
  pair small
  pg_start 19 $W/c19
  sql="select bid, count(*), sum(abalance), avg(aid * 2 + 1), sum((aid % 13) * (bid + 7) - abalance), max(length(filler)), stddev(aid::float8 / (bid + 1)) from pgbench_accounts where aid % 7 = 3 or abalance * 3 > aid group by bid order by bid"
  q 19 5432 -c "select pg_prewarm('pgbench_accounts')" 2>/dev/null || q 19 5432 -c "create extension pg_prewarm" -c "select pg_prewarm('pgbench_accounts')" >/dev/null
  q 19 5432 -c "$sql" >/dev/null; q 19 5432 -c "$sql" >/dev/null   # warm
  for r in 1 2 3 4 5; do for j in off on; do
    t=$(now_ms); q 19 5432 -c "set jit = $j" -c "$sql" >/dev/null; ms=$(( $(now_ms) - t ))
    row 19 "$r" "jit=$j" "ms=$ms"
  done; done
  q 19 5432 -c "set jit = on" -c "explain (analyze, buffers) $sql" > "$raw/explain-jit-on.txt"
  q 19 5432 -c "set jit = off" -c "explain (analyze, buffers) $sql" > "$raw/explain-jit-off.txt"
  pg_stop 19 $W/c19 ;;
esac
