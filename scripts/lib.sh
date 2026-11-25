# shellcheck shell=bash
# Shared helpers. Source this file; do not run it.
# Runs inside the "lab" container as user postgres. /data is the XFS (reflink) disk.
set -euo pipefail

B18=/usr/lib/postgresql/18/bin
B19=/usr/lib/postgresql/19/bin
export PGHOST=/tmp PGUSER=postgres PGDATABASE=postgres
RESULTS=/data/results
mkdir -p "$RESULTS"

now_ms() { date +%s%3N; }
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# The same server settings on 18 and 19, so the only change is the version.
# Sized for m7i.xlarge (4 vCPU, 16 GB RAM).
write_conf() {
  local dir=$1 port=${2:-5432}
  cat >> "$dir/postgresql.conf" <<EOF

# --- pg19-upgrade-tests ---
port = $port
listen_addresses = ''
unix_socket_directories = '/tmp'
shared_buffers = 4GB
effective_cache_size = 11GB
maintenance_work_mem = 1GB
work_mem = 32MB
max_wal_size = 16GB
checkpoint_timeout = 15min
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
max_parallel_workers = 4
max_parallel_maintenance_workers = 4
logging_collector = off
EOF
}

# init_cluster <18|19> <dir> [port]
init_cluster() {
  local v=$1 dir=$2 port=${3:-5432} bin
  bin=$(binfor "$v")
  mkdir -p "$(dirname "$dir")"
  "$bin/initdb" -D "$dir" -U postgres -E UTF8 --locale=en_US.UTF-8 --auth=trust >/dev/null
  write_conf "$dir" "$port"
}

binfor() { case $1 in 18) echo "$B18" ;; 19) echo "$B19" ;; *) echo "bad version $1" >&2; return 1 ;; esac; }

pg_start() { "$(binfor "$1")/pg_ctl" -D "$2" -l "$2/server.log" -w -t 600 start >/dev/null; }
pg_stop()  { "$(binfor "$1")/pg_ctl" -D "$2" -m fast -w -t 600 stop >/dev/null; }

# psql against a port with the given version's client.
q() { local v=$1 port=$2; shift 2; "$(binfor "$v")/psql" -X -qAt -v ON_ERROR_STOP=1 -p "$port" "$@"; }

db_size_bytes() { q "$1" "${2:-5432}" -c "select sum(pg_database_size(datname)) from pg_database"; }

# Real blocks used on /data (reflink-aware; du is not).
disk_used_bytes() { df -B1 --output=used /data | tail -1 | tr -d ' '; }

# Sample disk use every second into $1 until $2 exists.
disk_sampler() {
  local out=$1 stop=$2
  : > "$out"
  while [ ! -e "$stop" ]; do disk_used_bytes >> "$out"; sleep 1; done
  disk_used_bytes >> "$out"
}

csv_row() { local file=$1; shift; local IFS=,; echo "$*" >> "$RESULTS/$file"; }
