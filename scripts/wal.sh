#!/bin/bash
# Does pg_upgrade replay (or copy) the old cluster's WAL? And what happens to PITR?
# Usage: wal.sh          -> results/raw/wal/wal.txt
# Small dataset. 18 archives WAL to /data/run/archive; we take a base backup,
# write more, upgrade with --link, then try to use the 18 backup past the upgrade.
source /lab/lib.sh
set +e
out=$RESULTS/raw/wal; rm -rf -- "${out:?}"; mkdir -p "$out"
work=/data/run; rm -rf -- "${work:?}"; mkdir -p "$work/archive"
cp -a --reflink=always /data/pristine-small/c18 "$work/c18"
cat >> "$work/c18/postgresql.conf" <<EOF
archive_mode = on
archive_command = 'test ! -f $work/archive/%f && cp %p $work/archive/%f'
EOF
init_cluster 19 "$work/c19"
cat >> "$work/c19/postgresql.conf" <<EOF
archive_mode = on
archive_command = 'test ! -f $work/archive/%f && cp %p $work/archive/%f'
EOF
section() { echo; echo "### $*"; }
ctl() { "$(binfor "$1")/pg_controldata" "$2" | grep -E "system identifier|Database cluster state|Latest checkpoint location|REDO location|REDO WAL file|TimeLineID|NextXID|Data page checksum"; }

{
pg_start 18 "$work/c18"
"$B18/pg_basebackup" -p 5432 -D "$work/base18" -X stream -c fast
q 18 5432 -c "create table after_backup (t timestamptz default now(), note text)" -c "insert into after_backup (note) values ('written on 18 after the base backup')"
q 18 5432 -c "select pg_switch_wal()" >/dev/null; sleep 2
t_before_upgrade=$(q 18 5432 -c "select now()")
section "18 before shutdown: current WAL file"; q 18 5432 -c "select pg_walfile_name(pg_current_wal_lsn())"
pg_stop 18 "$work/c18"
section "18 after clean shutdown: pg_controldata"; ctl 18 "$work/c18"
section "18 pg_wal files"; ls "$work/c18/pg_wal" | grep -v archive_status
section "19 (fresh initdb) pg_controldata"; ctl 19 "$work/c19"

section "pg_upgrade --link"
(cd "$work" && "$B19/pg_upgrade" --link -b "$B18" -B "$B19" -d "$work/c18" -D "$work/c19" | grep -iE "wal|xid|Upgrade Complete")
section "19 after pg_upgrade: pg_controldata"; ctl 19 "$work/c19"
section "19 pg_wal files after pg_upgrade"; ls "$work/c19/pg_wal" | grep -v archive_status
section "did any 18 WAL file get copied into 19? (same names)"
comm -12 <(ls "$work/c18/pg_wal" | sort) <(ls "$work/c19/pg_wal" | sort) | grep -v archive_status || echo "none"

pg_start 19 "$work/c19"
q 19 5432 -c "insert into after_backup (note) values ('written on 19 after the upgrade')"
q 19 5432 -c "select pg_switch_wal()" >/dev/null; sleep 2
section "19 now writes WAL file"; q 19 5432 -c "select pg_walfile_name(pg_current_wal_lsn())"
pg_stop 19 "$work/c19"
section "archive contents (18 then 19, one directory)"; ls "$work/archive"

section "PITR 1: start the 18 base backup with 19 binaries"
cp -a --reflink=always "$work/base18" "$work/pitr19"
"$B19/pg_ctl" -D "$work/pitr19" -l "$work/pitr19.log" -w -t 30 start; echo "exit=$?"; cat "$work/pitr19.log"

section "PITR 2: restore the 18 base backup with 18 binaries, replay the whole archive (target: latest)"
cp -a --reflink=always "$work/base18" "$work/pitr18"
cat >> "$work/pitr18/postgresql.conf" <<EOF
archive_mode = off
restore_command = 'cp $work/archive/%f %p'
recovery_target_timeline = 'latest'
EOF
touch "$work/pitr18/recovery.signal"
"$B18/pg_ctl" -D "$work/pitr18" -l "$work/pitr18.log" -w -t 120 start; echo "exit=$?"
grep -E "LOG|FATAL|PANIC|WARNING" "$work/pitr18.log" | grep -vE "checkpoint (starting|complete)" | tail -15
section "rows that the 18 restore can see"
q 18 5432 -c "select note from after_backup order by t" 2>&1
"$B18/pg_ctl" -D "$work/pitr18" -m fast -w stop >/dev/null 2>&1
} > "$out/wal.txt" 2>&1
log "wal done"
