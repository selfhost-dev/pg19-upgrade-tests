#!/bin/bash
# Client view of downtime: try "SELECT 1" on port 5432 every 100 ms.
# Usage: probe.sh <out.csv> <stopfile>     (writes "epoch_ms,ok|fail")
# Downtime = the longest run of failures, from the last OK before it
# to the first OK after it (see gap.sh).
out=$1 stop=$2
: > "$out"
export PGCONNECT_TIMEOUT=1
while [ ! -e "$stop" ]; do
  t=$(date +%s%3N)
  if /usr/lib/postgresql/19/bin/psql -X -qAt -h /tmp -p 5432 -U postgres -d postgres -c 'select 1' >/dev/null 2>&1; then
    echo "$t,ok" >> "$out"
  else
    echo "$t,fail" >> "$out"
  fi
  sleep 0.1
done
