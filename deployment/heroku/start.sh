#!/bin/sh
# All-in-one Heroku entrypoint: local PostgreSQL + MediaFusion API + worker.
# Self-healing: each service restarts on crash. Redis stays external (30 MB addon).

set -u

PGDATA="${PGDATA:-/data/postgres}"
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
  -c random_page_cost=1.1"

log() { echo "[start.sh] $*"; }

ensure_postgres_user() {
  if id postgres >/dev/null 2>&1; then
    return 0
  fi
  log "creating postgres system user (Heroku runtime resets /etc/passwd)"
  groupadd -r postgres 2>/dev/null || true
  useradd -r -g postgres -d /var/lib/postgresql -s /bin/bash postgres
  mkdir -p /var/lib/postgresql
  chown postgres:postgres /var/lib/postgresql /data/postgres 2>/dev/null || true
}

init_postgres() {
  if [ -s "$PGDATA/PG_VERSION" ]; then
    return 0
  fi

  log "initializing PostgreSQL data directory"
  su postgres -s /bin/bash -c "initdb -D '$PGDATA' --auth-host=trust --auth-local=trust"

  su postgres -s /bin/bash -c "pg_ctl -D '$PGDATA' -w start"
  su postgres -s /bin/bash -c "psql -v ON_ERROR_STOP=1" <<'SQL'
CREATE USER mediafusion WITH PASSWORD 'mediafusion' SUPERUSER;
CREATE DATABASE mediafusion OWNER mediafusion;
SQL
  su postgres -s /bin/bash -c "pg_ctl -D '$PGDATA' -m fast -w stop"
  log "PostgreSQL initialized"
}

wait_for_postgres() {
  i=0
  while [ "$i" -lt 60 ]; do
    if su postgres -s /bin/bash -c "pg_isready -q -d mediafusion"; then
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
      "$@"
      log "$name exited — restarting in 2s"
      sleep 2
    done
  ) &
}

run_postgres() {
  exec su postgres -s /bin/bash -c "exec postgres -D '$PGDATA' $PG_OPTS"
}

run_worker() {
  exec su mediafusion -s /bin/bash -c 'exec /usr/local/bin/mediafusion-worker'
}

run_api() {
  exec su mediafusion -s /bin/bash -c 'exec /usr/local/bin/mediafusion-api'
}

ensure_postgres_user
init_postgres
supervise postgres run_postgres
wait_for_postgres
supervise worker run_worker

# API stays in foreground so Heroku routes traffic to this PID tree.
log "starting mediafusion-api on port $STREAM_RS_PORT"
run_api
