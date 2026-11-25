#!/bin/bash
# Does the new 19 cluster try to archive a WAL file name that the 18 cluster already archived?
# The 19 cluster (archive_mode=on, same archive dir) is upgraded from an 18 cluster whose
# archive already holds 000000010000000000000001. Usage: archive-collision.sh
source /lab/lib.sh
set +e
out=$RESULTS/raw/wal; mkdir -p "$out"
W=/data/arch; rm -rf -- "${W:?}"; mkdir -p $W/archive
cmd="archive_command = 'test ! -f $W/archive/%f && cp %p $W/archive/%f'"
{
init_cluster 18 $W/c18
printf "archive_mode = on\n%s\n" "$cmd" >> $W/c18/postgresql.conf
pg_start 18 $W/c18
q 18 5432 -c "create table x as select generate_series(1,100000) g" -c "select pg_switch_wal()" -c "select pg_switch_wal()" >/dev/null; sleep 3
pg_stop 18 $W/c18
echo "### archive after 18 (archive_mode on since initdb)"; ls $W/archive
init_cluster 19 $W/c19
printf "archive_mode = on\n%s\n" "$cmd" >> $W/c19/postgresql.conf
echo "### 19 pg_wal/archive_status before pg_upgrade"; ls $W/c19/pg_wal/archive_status
(cd $W && "$B19/pg_upgrade" --link -b "$B18" -B "$B19" -d $W/c18 -D $W/c19 >/dev/null; echo "pg_upgrade exit=$?")
echo "### 19 pg_wal and archive_status after pg_upgrade"; ls $W/c19/pg_wal $W/c19/pg_wal/archive_status
pg_start 19 $W/c19; sleep 8
echo "### archive after 19 started"; ls $W/archive
echo "### 19 archiver"; q 19 5432 -c "select archived_count, last_archived_wal, failed_count, last_failed_wal from pg_stat_archiver"
echo "### 19 server.log (archive lines)"; grep -iE "archive" $W/c19/server.log | head -8
pg_stop 19 $W/c19
} > "$out/archive-collision.txt" 2>&1
rm -rf -- "${W:?}"
log "archive-collision done"
