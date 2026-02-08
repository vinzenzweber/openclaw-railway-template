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

PG_VERSION=18
PG_CLUSTER=main
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}"
PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/${PG_CLUSTER}"

# Ensure data dir exists and is owned by postgres.
mkdir -p "${PG_DATA_DIR}"
chown -R postgres:postgres "/var/lib/postgresql/${PG_VERSION}"

# Create cluster if it doesn't exist.
if ! pg_lsclusters | awk '$1 == "'"${PG_VERSION}"'" && $2 == "'"${PG_CLUSTER}"'" {found=1} END {exit !found}'; then
  pg_createcluster "${PG_VERSION}" "${PG_CLUSTER}"
fi

# Ensure Postgres listens on localhost.
if [ -f "${PG_CONF_DIR}/postgresql.conf" ]; then
  sed -i "s/^#\\?listen_addresses.*/listen_addresses = '127.0.0.1'/" "${PG_CONF_DIR}/postgresql.conf"
fi

# Start Postgres in the background.
pg_ctlcluster "${PG_VERSION}" "${PG_CLUSTER}" start

cleanup() {
  pg_ctlcluster "${PG_VERSION}" "${PG_CLUSTER}" stop >/dev/null 2>&1 || true
  kill -TERM "${node_pid:-}" "${watchdog_pid:-}" 2>/dev/null || true
  wait || true
}
trap cleanup INT TERM

# Wait for Postgres to accept connections.
until pg_isready -U postgres -d postgres >/dev/null 2>&1; do
  sleep 1
done

# Create role/db and set password.
su -s /bin/bash postgres -c "psql -v user='${POSTGRES_USER}' -v pass='${POSTGRES_PASSWORD}' -v db='${POSTGRES_DB}' -d postgres <<'SQL'
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'user') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', :'user', :'pass');
  ELSE
    EXECUTE format('ALTER ROLE %I PASSWORD %L', :'user', :'pass');
  END IF;
END
\$\$;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', :'db', :'user');
  END IF;
END
\$\$;
SQL" >/dev/null 2>&1

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
