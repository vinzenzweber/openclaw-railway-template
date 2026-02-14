#!/usr/bin/env bash
set -euo pipefail

: "${PORT:=18800}"
: "${CHROMIUM_CDP_HOST:=0.0.0.0}"
: "${CHROMIUM_CDP_PORT:=${PORT}}"
: "${CHROMIUM_BIN:=chromium}"
: "${CHROMIUM_USER_DATA_DIR:=/data/chromium-user-data}"
: "${CHROMIUM_FLAGS:=--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-blink-features=AutomationControlled --disable-features=IsolateOrigins,site-per-process}"

mkdir -p "${CHROMIUM_USER_DATA_DIR}"
chmod 700 "${CHROMIUM_USER_DATA_DIR}"

# Remove stale singleton lock files from unclean shutdowns.
rm -f \
  "${CHROMIUM_USER_DATA_DIR}/SingletonLock" \
  "${CHROMIUM_USER_DATA_DIR}/SingletonCookie" \
  "${CHROMIUM_USER_DATA_DIR}/SingletonSocket"

if [ -n "${CHROMIUM_EXTRA_FLAGS:-}" ]; then
  CHROMIUM_FLAGS="${CHROMIUM_FLAGS} ${CHROMIUM_EXTRA_FLAGS}"
fi

read -r -a chromium_args <<< "${CHROMIUM_FLAGS}"

exec "${CHROMIUM_BIN}" \
  "${chromium_args[@]}" \
  --remote-debugging-address="${CHROMIUM_CDP_HOST}" \
  --remote-debugging-port="${CHROMIUM_CDP_PORT}" \
  --user-data-dir="${CHROMIUM_USER_DATA_DIR}" \
  about:blank
