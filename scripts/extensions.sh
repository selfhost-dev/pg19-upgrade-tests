#!/bin/bash
# Extensions on 19: does each install? Then pg_upgrade an 18 cluster that uses them.
# Usage: extensions.sh   -> results/raw/extensions/
source /lab/lib.sh
set +e
out=$RESULTS/raw/extensions; rm -rf -- "${out:?}"; mkdir -p "$out"
W=/data/ext; rm -rf -- "${W:?}"; mkdir -p $W
exts="vector postgis pg_cron pg_stat_statements timescaledb"
for v in 18 19; do
  init_cluster $v $W/c$v 5432
  echo "shared_preload_libraries = 'pg_stat_statements,pg_cron'" >> $W/c$v/postgresql.conf
  echo "cron.database_name = 'postgres'" >> $W/c$v/postgresql.conf
done
# 18 also preloads timescaledb (installed for 18 only)
sed -i "s/'pg_stat_statements,pg_cron'/'pg_stat_statements,pg_cron,timescaledb'/" $W/c18/postgresql.conf

{
echo "# extension install on 19.0 ($(date -u +%FT%TZ))"
pg_start 19 $W/c19
for e in $exts; do
  r=$(q 19 5432 -c "create extension if not exists $e cascade" 2>&1 | grep -E "ERROR" )
  vv=$(q 19 5432 -c "select extversion from pg_extension where extname='$e'")
  echo "$e|${vv:-not installed}|${r}"
done
section() { echo; echo "### $*"; }
section "available versions on 19"
q 19 5432 -c "select name, default_version from pg_available_extensions where name in ('vector','postgis','pg_cron','pg_stat_statements','timescaledb') order by 1"
section "smoke tests on 19"
q 19 5432 -c "create table items (id int, embedding vector(3))" -c "insert into items values (1,'[1,2,3]'),(2,'[3,2,1]')" -c "create index on items using hnsw (embedding vector_l2_ops)" -c "select id from items order by embedding <-> '[1,2,2]' limit 1" 2>&1
q 19 5432 -c "select postgis_full_version()" 2>&1 | cut -c1-200
q 19 5432 -c "select cron.schedule('nightly', '0 3 * * *', 'select 1')" 2>&1
q 19 5432 -c "select count(*) > 0 from pg_stat_statements" 2>&1
pg_stop 19 $W/c19
} > "$out/install-19.txt" 2>&1

# pg_upgrade with the four that exist on 19 (timescaledb left out)
rm -rf -- "${W:?}/c19"; init_cluster 19 $W/c19 5432
echo "shared_preload_libraries = 'pg_stat_statements,pg_cron'" >> $W/c19/postgresql.conf
echo "cron.database_name = 'postgres'" >> $W/c19/postgresql.conf
sed -i "s/,timescaledb'/'/" $W/c18/postgresql.conf
{
pg_start 18 $W/c18
q 18 5432 <<'SQL'
create extension vector; create extension postgis; create extension pg_cron; create extension pg_stat_statements;
create table items (id int, embedding vector(3)); insert into items values (1,'[1,2,3]'),(2,'[3,2,1]');
create index items_hnsw on items using hnsw (embedding vector_l2_ops);
create table places (id int, g geometry(Point, 4326)); insert into places values (1, 'SRID=4326;POINT(72.8 19.0)');
create index places_g on places using gist (g);
select cron.schedule('nightly', '0 3 * * *', 'select 1');
SQL
echo "### 18 extensions"; q 18 5432 -c "select extname, extversion from pg_extension order by 1"
pg_stop 18 $W/c18
echo "### pg_upgrade --check"
(cd $W && "$B19/pg_upgrade" --check -b "$B18" -B "$B19" -d $W/c18 -D $W/c19) | tail -6
echo "### pg_upgrade --link"
(cd $W && "$B19/pg_upgrade" --link -b "$B18" -B "$B19" -d $W/c18 -D $W/c19) | tail -12
pg_start 19 $W/c19
echo "### 19 after upgrade"
q 19 5432 -c "select extname, extversion from pg_extension order by 1"
q 19 5432 -c "select id from items order by embedding <-> '[1,2,2]' limit 1" -c "select st_astext(g) from places" -c "select jobname, schedule from cron.job"
echo "### update_extensions.sql written by pg_upgrade?"; cat $W/update_extensions.sql 2>/dev/null || echo "none"
pg_stop 19 $W/c19
} > "$out/upgrade-with-extensions.txt" 2>&1
rm -rf -- "${W:?}"
log "extensions done"
