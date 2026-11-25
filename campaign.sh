#!/bin/bash
# Every measurement, in order. Host side, on the test box. Logs to /data/results/campaign.log.
# Usage: ./campaign.sh [stage...]   stages: upgrades dump logical wal extensions bench
# Each run's full output goes to the log, with its exit status; a failed run is marked FAILED.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LOG=/data/results/campaign.log
exec > >(sudo tee -a "$LOG" >/dev/null) 2>&1
if [ $# -gt 0 ]; then stages=("$@"); else stages=(upgrades dump logical wal extensions bench); fi
r() {
  echo "=== $(date -u +%FT%TZ) $*"
  ./run.sh "$@"
  local rc=$?
  [ $rc -eq 0 ] || echo "=== FAILED (exit $rc): $*"
}
for s in "${stages[@]}"; do case $s in
  upgrades)
    for run in 1 2 3; do for m in copy link clone swap; do r upgrade-pg.sh "$m" small "$run"; done; done
    for run in 1 2;   do for m in copy link clone swap; do r upgrade-pg.sh "$m" large "$run"; done; done ;;
  dump)       for run in 1 2 3; do r dump-restore.sh small "$run"; done; r dump-restore.sh large 1 ;;
  logical)    r logical.sh small 1; r logical.sh large 1 ;;
  wal)        r wal.sh; r archive-collision.sh ;;
  extensions) r extensions.sh ;;
  bench)      for b in fk vacuum autovacuum pgbench jit; do r bench.sh "$b"; done ;;
  *)          echo "=== unknown stage: $s" ;;
esac; done
echo "=== $(date -u +%FT%TZ) CAMPAIGN DONE"
