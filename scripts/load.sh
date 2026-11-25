#!/bin/bash
# Build a pristine PostgreSQL 18 cluster for one dataset size.
# Usage: load.sh <small|large>
#   small = pgbench scale 100  (~1.5 GB)
#   large = pgbench scale 1300 (~20 GB)
# Adds: foreign keys (pgbench --foreign-keys), one extra index, one extended
# statistics object, and one identity column (to test sequences later).
source /lab/lib.sh
size=$1
case $size in small) scale=100 ;; large) scale=1300 ;; *) echo "small|large" >&2; exit 1 ;; esac
dir=/data/pristine-$size/c18
rm -rf -- "/data/pristine-${size:?}"
init_cluster 18 "$dir"
pg_start 18 "$dir"

t0=$(now_ms)
"$B18/pgbench" -p 5432 -i -s "$scale" --foreign-keys -q postgres 2>&1 | tail -2
q 18 5432 <<'SQL'
create index pgbench_accounts_bid on pgbench_accounts (bid);
create statistics accounts_aid_bid (ndistinct, dependencies) on aid, bid from pgbench_accounts;
create table orders (id bigint generated always as identity primary key, aid int references pgbench_accounts, note text);
insert into orders (aid, note) select (random()*99999)::int + 1, md5(g::text) from generate_series(1, 100000) g;
analyze;
checkpoint;
SQL
t1=$(now_ms)

bytes=$(db_size_bytes 18)
seq=$(q 18 5432 -c "select last_value from orders_id_seq")
pg_stop 18 "$dir"
log "loaded $size: scale=$scale bytes=$bytes seconds=$(( (t1-t0)/1000 )) orders_seq=$seq"
csv_row datasets.csv "$size" "$scale" "$bytes" "$(( (t1-t0)/1000 ))" "$(date -u +%FT%TZ)"
