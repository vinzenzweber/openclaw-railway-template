#!/usr/bin/env bash
set -euo pipefail

# Provide safe defaults for local/dev; encourage overriding in production.
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_PASSWORD:=postgres}"
: "${POSTGRES_DB:=postgres}"
if [ "${POSTGRES_PASSWORD}" = "postgres" ]; then
  echo "warning: POSTGRES_PASSWORD is set to the default 'postgres'; override this in production." >&2
fi

if [ -z "${DATABASE_URL:-}" ]; then
  export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:5432/${POSTGRES_DB}"
fi

# Start Chromium for OpenClaw browser attach mode.
: "${CHROMIUM_CDP_HOST:=127.0.0.1}"
: "${CHROMIUM_CDP_PORT:=18800}"
: "${CHROMIUM_BIN:=chromium}"
: "${CHROMIUM_USER_DATA_DIR:=/data/chromium-user-data}"
: "${CHROMIUM_FLAGS:=--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-blink-features=AutomationControlled --disable-features=IsolateOrigins,site-per-process}"
export CHROMIUM_CDP_URL="http://${CHROMIUM_CDP_HOST}:${CHROMIUM_CDP_PORT}"

mkdir -p "${CHROMIUM_USER_DATA_DIR}"
chmod 700 "${CHROMIUM_USER_DATA_DIR}"

# Allow operators to append custom flags without replacing defaults.
if [ -n "${CHROMIUM_EXTRA_FLAGS:-}" ]; then
  CHROMIUM_FLAGS="${CHROMIUM_FLAGS} ${CHROMIUM_EXTRA_FLAGS}"
fi

# Split configured flags into args safely.
read -r -a chromium_args <<< "${CHROMIUM_FLAGS}"

"${CHROMIUM_BIN}" \
  "${chromium_args[@]}" \
  --remote-debugging-address="${CHROMIUM_CDP_HOST}" \
  --remote-debugging-port="${CHROMIUM_CDP_PORT}" \
  --user-data-dir="${CHROMIUM_USER_DATA_DIR}" \
  about:blank >/tmp/chromium.log 2>&1 &
chromium_pid=$!

for _ in $(seq 1 30); do
  if curl -fsS "${CHROMIUM_CDP_URL}/json/version" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! curl -fsS "${CHROMIUM_CDP_URL}/json/version" >/dev/null 2>&1; then
  echo "Chromium CDP failed to start. Last log output:" >&2
  tail -n 50 /tmp/chromium.log >&2 || true
  exit 1
fi

PG_VERSION=18
PG_CLUSTER=main
PG_DATA_DIR="${POSTGRES_DATA_DIR:-/data/postgres}"

# Ensure data dir exists and is owned by postgres.
mkdir -p "${PG_DATA_DIR}"
chown -R postgres:postgres "${PG_DATA_DIR}"

# Create cluster if it doesn't exist.
if [ ! -f "${PG_DATA_DIR}/PG_VERSION" ]; then
  su -s /bin/bash postgres -c "/usr/lib/postgresql/${PG_VERSION}/bin/initdb -D \"${PG_DATA_DIR}\" --auth-local peer --auth-host scram-sha-256 --no-instructions"
fi

# Ensure Postgres listens on localhost.
if [ -f "${PG_DATA_DIR}/postgresql.conf" ]; then
  sed -i "s/^#\\?listen_addresses.*/listen_addresses = '127.0.0.1'/" "${PG_DATA_DIR}/postgresql.conf"
fi

# Start Postgres in the background.
su -s /bin/bash postgres -c "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D \"${PG_DATA_DIR}\" -w start"

cleanup() {
  su -s /bin/bash postgres -c "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl -D \"${PG_DATA_DIR}\" -w stop" >/dev/null 2>&1 || true
  kill -TERM "${node_pid:-}" "${chromium_pid:-}" "${watchdog_pid:-}" 2>/dev/null || true
  wait || true
}
trap cleanup INT TERM

# Wait for Postgres to accept connections.
until su -s /bin/bash postgres -c "pg_isready -d postgres" >/dev/null 2>&1; do
  sleep 1
done

sql_ident() {
  printf "%s" "$1" | sed 's/"/""/g'
}
sql_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}
psql_exec() {
  su -s /bin/bash postgres -c "psql -d postgres -v ON_ERROR_STOP=1 -c \"$1\"" >/dev/null 2>&1
}
psql_query() {
  su -s /bin/bash postgres -c "psql -d postgres -tAc \"$1\"" 2>/dev/null
}

user_ident="$(sql_ident "${POSTGRES_USER}")"
db_ident="$(sql_ident "${POSTGRES_DB}")"
user_lit="$(sql_literal "${POSTGRES_USER}")"
pass_lit="$(sql_literal "${POSTGRES_PASSWORD}")"
db_lit="$(sql_literal "${POSTGRES_DB}")"

# Create role/db and set password.
if [ -z "$(psql_query "SELECT 1 FROM pg_roles WHERE rolname='${user_lit}'")" ]; then
  psql_exec "CREATE ROLE \"${user_ident}\" LOGIN PASSWORD '${pass_lit}'"
else
  psql_exec "ALTER ROLE \"${user_ident}\" PASSWORD '${pass_lit}'"
fi

if [ -z "$(psql_query "SELECT 1 FROM pg_database WHERE datname='${db_lit}'")" ]; then
  psql_exec "CREATE DATABASE \"${db_ident}\" OWNER \"${user_ident}\""
fi

# Ensure pgvector is enabled in the target DB.
su -s /bin/bash postgres -c "psql -d \"${POSTGRES_DB}\" -c 'CREATE EXTENSION IF NOT EXISTS vector;'" >/dev/null 2>&1
if ! su -s /bin/bash postgres -c "psql -d \"${POSTGRES_DB}\" -tAc \"SELECT 1 FROM pg_extension WHERE extname='vector'\"" | grep -q 1; then
  echo "pgvector extension check failed" >&2
  exit 1
fi

# Run the Node wrapper in the background and wait on both processes.
node /app/src/server.js &
node_pid=$!

wait "${node_pid}"
exit_code=$?
cleanup
exit "${exit_code}"
