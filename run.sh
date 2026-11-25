#!/bin/bash
# Host-side runner (on the test box). Drops the page cache, then runs one script in the lab container.
# Usage: ./run.sh <script> [args...]     e.g. ./run.sh upgrade-pg.sh link large 1
# Only the scripts in scripts/ (mounted read-only at /lab) can be named.
set -euo pipefail
case ${1:-} in
  load.sh|upgrade-pg.sh|dump-restore.sh|logical.sh|wal.sh|archive-collision.sh|\
  drills.sh|extensions.sh|settings-diff.sh|bench.sh) ;;
  *) echo "usage: ./run.sh <script in scripts/> [args...]; refusing '${1:-}'" >&2; exit 64 ;;
esac
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
exec sudo docker exec -u postgres lab bash "/lab/$1" "${@:2}"
