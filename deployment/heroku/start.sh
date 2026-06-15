#!/bin/sh
set -e

# Map Heroku platform env vars to MediaFusion conventions.
export STREAM_RS_PORT="${STREAM_RS_PORT:-${PORT:-8000}}"

if [ -z "${POSTGRES_URI:-}" ] && [ -n "${DATABASE_URL:-}" ]; then
  export POSTGRES_URI="$DATABASE_URL"
fi

if [ -z "${HOST_URL:-}" ]; then
  if [ -n "${HEROKU_APP_DEFAULT_DOMAIN_NAME:-}" ]; then
    export HOST_URL="https://${HEROKU_APP_DEFAULT_DOMAIN_NAME}"
  elif [ -n "${HEROKU_APP_NAME:-}" ]; then
    export HOST_URL="https://${HEROKU_APP_NAME}.herokuapp.com"
  fi
fi

# Eco dyno has 512 MB RAM — keep DB pool small.
export DB_POOL_SIZE="${DB_POOL_SIZE:-5}"
export DB_POOL_MIN="${DB_POOL_MIN:-1}"

# Single dyno runs API (foreground) + worker (background).
/usr/local/bin/mediafusion-worker &
exec /usr/local/bin/mediafusion-api
