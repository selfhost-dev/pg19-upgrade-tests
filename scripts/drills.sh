#!/bin/bash
# Break the upgrade on purpose and keep the exact output.
# Usage: drills.sh [drill...]    (default: all)   -> results/raw/drills/<drill>.txt
# Each drill uses its own tiny clusters on ports 5450/5451.
source /lab/lib.sh
set +e   # drills are supposed to fail; we capture, we do not stop
out=$RESULTS/raw/drills; mkdir -p "$out"
W=/data/drill
P18=5450 P19=5451

fresh() {   # fresh 18 + 19 pair
  pg_stop 18 $W/c18 2>/dev/null; pg_stop 19 $W/c19 2>/dev/null
  rm -rf -- "${W:?}"; mkdir -p $W
  init_cluster 18 $W/c18 $P18; init_cluster 19 $W/c19 $P19
}
check() { (cd $W && "$B19/pg_upgrade" --check -b "$B18" -B "$B19" -d $W/c18 -D $W/c19 -p $P18 -P $P19 2>&1); echo "exit=$?"; }
section() { echo; echo "### $*"; }

drill_io_workers() {
  fresh
  echo "io_workers = 4" >> $W/c19/postgresql.conf
  section "start 19 with io_workers = 4 in postgresql.conf"
  "$B19/pg_ctl" -D $W/c19 -l $W/c19/server.log -w -t 20 start 2>&1; echo "exit=$?"
  section "server.log"; cat $W/c19/server.log
}

drill_radius() {
  fresh
  sed -i '1i host all all 10.0.0.0/8 radius radiusservers="10.0.0.1" radiussecrets="x"' $W/c18/pg_hba.conf
  pg_start 18 $W/c18
  section "18 accepts the radius line"; q 18 $P18 -c "select line_number, auth_method from pg_hba_file_rules where auth_method='radius'"
  pg_stop 18 $W/c18
  section "pg_upgrade --check (old pg_hba.conf has radius)"; check
  cp $W/c18/pg_hba.conf $W/c19/pg_hba.conf
  section "start 19 with the old pg_hba.conf copied over"
  "$B19/pg_ctl" -D $W/c19 -l $W/c19/server.log -w -t 20 start 2>&1; echo "exit=$?"
  section "server.log"; cat $W/c19/server.log
}

drill_scs() {
  fresh
  pg_start 18 $W/c18; pg_start 19 $W/c19
  q 18 $P18 <<'SQL'
alter system set standard_conforming_strings = off;
select pg_reload_conf();
SQL
  q 18 $P18 <<'SQL'
set standard_conforming_strings = off;
create table paths (id int, p text default 'C:\\temp\\new', note text);
comment on table paths is 'Windows path C:\\temp';
insert into paths values (1, 'C:\temp', 'tab\there');
SQL
  section "18: stored values"; q 18 $P18 -c "select p, note, obj_description('paths'::regclass) from paths" -c "select pg_get_expr(adbin, adrelid) from pg_attrdef where adrelid='paths'::regclass" -c "set standard_conforming_strings = off" -c "insert into paths (id) values (2)" -c "select 'default value of a new row: ' || p from paths where id = 2"
  section "18 server setting"; q 18 $P18 -c "show standard_conforming_strings"
  "$B18/pg_dump" -p $P18 -f $W/old18.sql postgres
  section "dump made with 18 pg_dump: SET lines + DDL"; grep -nE "standard_conforming|DEFAULT|COMMENT ON TABLE" $W/old18.sql
  section "load the 18 dump into 19 (psql, ON_ERROR_STOP off)"
  "$B19/psql" -X -p $P19 -f $W/old18.sql postgres 2>&1 | grep -vE "^(SET|CREATE|ALTER|COMMENT|COPY|set_config| *$|-+|\(1 row\))"
  section "19: what arrived"; q 19 $P19 -c "select p, note, obj_description('paths'::regclass) from paths" -c "select pg_get_expr(adbin, adrelid) from pg_attrdef where adrelid='paths'::regclass" -c "insert into paths (id) values (2)" -c "select 'default value of a new row: ' || p from paths where id = 2" 2>&1
  section "19: try to turn it off"; q 19 $P19 -c "set standard_conforming_strings = off" 2>&1; echo "exit=$?"
  q 19 $P19 -c "drop table if exists paths" >/dev/null 2>&1
  section "fix: dump the same 18 server with the 19 pg_dump"
  "$B19/pg_dump" -p $P18 -f $W/new19.sql postgres
  grep -nE "standard_conforming|DEFAULT|COMMENT ON TABLE" $W/new19.sql
  "$B19/psql" -X -q -v ON_ERROR_STOP=1 -p $P19 -f $W/new19.sql postgres >/dev/null 2>&1; echo "load exit=$?"
  q 19 $P19 -c "select p, note, obj_description('paths'::regclass) from paths"
  pg_stop 18 $W/c18; pg_stop 19 $W/c19
}

drill_btree_gist() {
  fresh
  pg_start 18 $W/c18
  q 18 $P18 <<'SQL'
create extension btree_gist;
create table hosts (ip inet, net cidr);
create index hosts_ip_gist on hosts using gist (ip);
create index hosts_net_gist on hosts using gist (net);
SQL
  pg_stop 18 $W/c18
  section "pg_upgrade --check"; check
  section "file named in the output"; cat $W/c19/pg_upgrade_output.d/*/gist_inet_ops.txt 2>/dev/null
}

drill_newline_name() {
  fresh
  pg_start 18 $W/c18
  q 18 $P18 -c "create database \"sales
eu\"" ; q 18 $P18 -c "create role \"report
er\""
  section "18: names with a newline"; q 18 $P18 -c "select 'db', datname from pg_database where datname ~ E'\n' union all select 'role', rolname from pg_roles where rolname ~ E'\n'"
  pg_stop 18 $W/c18
  section "pg_upgrade --check"; check
  section "files named in the output"; for f in $W/c19/pg_upgrade_output.d/*/*.txt; do echo "-- $(basename $f)"; cat "$f"; done 2>/dev/null
}

drill_missing_ext() {
  fresh
  echo "shared_preload_libraries = 'timescaledb'" >> $W/c18/postgresql.conf
  pg_start 18 $W/c18
  q 18 $P18 -c "create extension timescaledb" >/dev/null
  q 18 $P18 -c "create table m (t timestamptz not null, v float); select create_hypertable('m', 't')" >/dev/null
  section "18: installed"; q 18 $P18 -c "select extname, extversion from pg_extension where extname='timescaledb'"
  pg_stop 18 $W/c18
  section "19: timescaledb files present?"; ls /usr/lib/postgresql/19/lib/ | grep -i timescale || echo "no timescaledb library for 19"
  section "pg_upgrade --check"; check
  section "files named in the output"; for f in $W/c19/pg_upgrade_output.d/*/*.txt; do echo "-- $(basename $f)"; cat "$f"; done 2>/dev/null
}

drill_pulled_features() {
  fresh
  pg_start 19 $W/c19
  q 19 $P19 -c "create table m (id int, d date) partition by range (d)" -c "create table m1 partition of m for values from ('2026-01-01') to ('2026-02-01')" -c "create table m2 partition of m for values from ('2026-02-01') to ('2026-03-01')"
  section "MERGE PARTITIONS"; q 19 $P19 -c "alter table m merge partitions (m1, m2) into m12" 2>&1
  section "SPLIT PARTITION"; q 19 $P19 -c "alter table m split partition m1 into (partition m1a for values from ('2026-01-01') to ('2026-01-15'), partition m1b for values from ('2026-01-15') to ('2026-02-01'))" 2>&1
  section "SQL/PGQ CREATE PROPERTY GRAPH"; q 19 $P19 -c "create property graph g vertex tables (m)" 2>&1
  section "SQL/PGQ GRAPH_TABLE"; q 19 $P19 -c "select * from graph_table (g match (a) columns (a.id))" 2>&1
  section "FOR PORTION OF"; q 19 $P19 -c "create table r (id int, valid daterange, v int)" -c "update r for portion of valid from '2026-01-01' to '2026-02-01' set v = 1" 2>&1
  section "pg_get_*_ddl functions"; q 19 $P19 -c "select proname from pg_proc where proname ~ '^pg_get_.*_ddl\$'" 2>&1; echo "(empty above = none)"
  section "online checksum toggle (pg_enable_data_checksums)"; q 19 $P19 -c "select pg_enable_data_checksums()" 2>&1
  section "REPACK CONCURRENTLY (shipped)"; q 19 $P19 -c "create table rp (id int primary key, v text)" -c "insert into rp select g, 'x' from generate_series(1,1000) g" -c "repack (concurrently) rp" 2>&1; echo "exit=$?"
  pg_stop 19 $W/c19
}

drill_md5() {
  fresh
  sed -i '1i local all md5user md5' $W/c19/pg_hba.conf
  pg_start 19 $W/c19
  q 19 $P19 -c "set password_encryption = md5" -c "create role md5user login password 'secret'" 2>&1
  section "19: login as an md5 user"
  PGPASSWORD=secret "$B19/psql" -X -p $P19 -U md5user -d postgres -c "select 1 as ok" 2>&1
  section "19: settings"; q 19 $P19 -c "select name, setting from pg_settings where name in ('md5_password_warnings','password_encryption','password_expiration_warning_threshold')"
  section "move to SCRAM"
  q 19 $P19 -c "set password_encryption = 'scram-sha-256'" -c "alter role md5user password 'secret'"
  q 19 $P19 -c "select rolname, left(rolpassword, 14) from pg_authid where rolname='md5user'"
  sed -i '1s/ md5$/ scram-sha-256/' $W/c19/pg_hba.conf; q 19 $P19 -c "select pg_reload_conf()" >/dev/null
  PGPASSWORD=secret "$B19/psql" -X -p $P19 -U md5user -d postgres -c "select 1 as ok" 2>&1
  pg_stop 19 $W/c19
}

drill_max_locks() {
  # Same explicit max_locks_per_transaction on 18 and 19: how many tables can ONE transaction lock?
  # Binary search on N. Tables are created in batches (one transaction each) first.
  fresh; export PGOPTIONS="-c client_min_messages=warning"
  for cfg in "18 64" "19 64" "19 128"; do
    set -- $cfg; v=$1 ml=$2
    d=$W/c$v; p=$([ $v = 18 ] && echo $P18 || echo $P19)
    printf 'max_locks_per_transaction = %s\nmax_connections = 100\n' "$ml" >> $d/postgresql.conf
    pg_start $v $d
    for b in $(seq 0 39); do
      q $v $p -c "do \$\$ begin for i in $((b*500+1))..$(((b+1)*500)) loop execute format('create table if not exists t_%s (id int)', i); end loop; end \$\$" >/dev/null
    done
    lo=0 hi=20000 err=""
    while [ $((hi-lo)) -gt 25 ]; do
      mid=$(((lo+hi)/2))
      r=$(q $v $p -c "do \$\$ begin for i in 1..$mid loop execute format('lock table t_%s in access share mode', i); end loop; end \$\$" 2>&1 | grep -E '^ERROR' )
      if [ -z "$r" ]; then lo=$mid; else hi=$mid; err=$r; fi
    done
    echo "$v max_locks_per_transaction=$(q $v $p -c 'show max_locks_per_transaction') max_connections=$(q $v $p -c 'show max_connections'): one transaction locks ~$lo tables; at ~$hi -> $err"
    pg_stop $v $d
    sed -i '/^max_locks_per_transaction = /d' $d/postgresql.conf
  done
}

drill_toast() {
  fresh
  pg_start 19 $W/c19
  section "19 default"; q 19 $P19 -c "show default_toast_compression"
  q 19 $P19 -c "set default_toast_compression = pglz" -c "create table tc (id int, body text)" \
           -c "insert into tc select g, repeat(md5(g::text), 400) from generate_series(1, 2000) g"
  section "rows written with pglz"; q 19 $P19 -c "select pg_column_compression(body), count(*) from tc group by 1"
  section "after REPACK (default now lz4)"; q 19 $P19 -c "repack tc"; q 19 $P19 -c "select pg_column_compression(body), count(*) from tc group by 1"
  section "after VACUUM FULL"; q 19 $P19 -c "vacuum full tc"; q 19 $P19 -c "select pg_column_compression(body), count(*) from tc group by 1"
  section "after UPDATE body = body || ''"; q 19 $P19 -c "update tc set body = body || ''"; q 19 $P19 -c "select pg_column_compression(body), count(*) from tc group by 1"
  pg_stop 19 $W/c19
}

all="io_workers radius scs btree_gist newline_name missing_ext pulled_features md5 max_locks toast"
if [ $# -gt 0 ]; then list=("$@"); else read -r -a list <<< "$all"; fi
for d in "${list[@]}"; do
  log "drill $d"
  { echo "# drill: $d  ($(date -u +%FT%TZ), 18.7 -> 19.0)"; "drill_$d"; } > "$out/$d.txt" 2>&1
done
pg_stop 18 $W/c18 2>/dev/null; pg_stop 19 $W/c19 2>/dev/null; rm -rf -- "${W:?}"
