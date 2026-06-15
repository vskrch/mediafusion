#!/bin/sh
# All-in-one Heroku entrypoint — runs as USER postgres (no su; Heroku blocks /etc/passwd writes).

set -eu

PGDATA="${PGDATA:-/data/postgres}"
PORT_HOLDER_PID=""
export STREAM_RS_PORT="${STREAM_RS_PORT:-${PORT:-8000}}"
export POSTGRES_URI="${POSTGRES_URI:-postgresql://mediafusion:mediafusion@127.0.0.1:5432/mediafusion}"
export DB_POOL_SIZE="${DB_POOL_SIZE:-2}"
export DB_POOL_MIN="${DB_POOL_MIN:-1}"

if [ -z "${HOST_URL:-}" ]; then
  if [ -n "${HEROKU_APP_DEFAULT_DOMAIN_NAME:-}" ]; then
    export HOST_URL="https://${HEROKU_APP_DEFAULT_DOMAIN_NAME}"
  elif [ -n "${HEROKU_APP_NAME:-}" ]; then
    export HOST_URL="https://${HEROKU_APP_NAME}.herokuapp.com"
  fi
fi

if [ -z "${REDIS_URL:-}" ] && [ -n "${REDISCLOUD_URL:-}" ]; then
  export REDIS_URL="$REDISCLOUD_URL"
fi

PG_OPTS="-c shared_buffers=32MB \
  -c max_connections=30 \
  -c effective_cache_size=96MB \
  -c work_mem=2MB \
  -c maintenance_work_mem=16MB \
  -c wal_buffers=4MB \
  -c checkpoint_completion_target=0.9 \
  -c random_page_cost=1.1 \
  -c unix_socket_directories=/tmp/pg-run \
  -c listen_addresses=127.0.0.1"

log() { echo "[start.sh] $*"; }

hold_port_for_boot() {
  (
    while true; do
      printf 'HTTP/1.1 503 Booting\r\nContent-Length: 7\r\nConnection: close\r\n\r\nBooting' \
        | nc -l -p "$STREAM_RS_PORT" -q 1 2>/dev/null || sleep 0.5
    done
  ) &
  PORT_HOLDER_PID=$!
  log "holding port $STREAM_RS_PORT during database startup"
}

release_port_holder() {
  if [ -n "$PORT_HOLDER_PID" ]; then
    kill "$PORT_HOLDER_PID" 2>/dev/null || true
    wait "$PORT_HOLDER_PID" 2>/dev/null || true
    PORT_HOLDER_PID=""
    sleep 1
  fi
}

init_postgres() {
  if [ -s "$PGDATA/PG_VERSION" ]; then
    log "reusing existing PostgreSQL data"
    return 0
  fi

  log "initializing PostgreSQL data directory"
  initdb -D "$PGDATA" --auth-host=trust --auth-local=trust

  pg_ctl -D "$PGDATA" -o "$PG_OPTS" -w start
  psql -v ON_ERROR_STOP=1 postgres <<'SQL'
CREATE USER mediafusion WITH PASSWORD 'mediafusion' SUPERUSER;
CREATE DATABASE mediafusion OWNER mediafusion;
SQL
  pg_ctl -D "$PGDATA" -m fast -w stop
  log "PostgreSQL initialized"
}

wait_for_postgres() {
  i=0
  while [ "$i" -lt 180 ]; do
    if pg_isready -h 127.0.0.1 -p 5432 -d mediafusion -q; then
      log "PostgreSQL is ready"
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  log "ERROR: PostgreSQL did not become ready in time"
  return 1
}

supervise() {
  name=$1
  shift
  (
    while true; do
      log "$name starting"
      "$@" || log "$name exited — restarting in 2s"
      sleep 2
    done
  ) &
}

run_postgres() {
  exec postgres -D "$PGDATA" $PG_OPTS
}

hold_port_for_boot
init_postgres
supervise postgres run_postgres
if ! wait_for_postgres; then
  release_port_holder
  exit 1
fi
release_port_holder
supervise worker /usr/local/bin/mediafusion-worker

log "starting mediafusion-api on port $STREAM_RS_PORT (migrations may take a few minutes on first boot)"
exec /usr/local/bin/mediafusion-api
