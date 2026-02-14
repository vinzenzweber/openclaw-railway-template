#!/usr/bin/env bash
set -euo pipefail

: "${PORT:=18800}"
: "${CHROMIUM_CDP_HOST:=0.0.0.0}"
: "${CHROMIUM_CDP_PORT:=${PORT}}"
: "${CHROMIUM_BIN:=chromium}"
: "${CHROMIUM_USER_DATA_DIR:=/data/chromium-user-data}"
: "${CHROMIUM_FLAGS:=--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-blink-features=AutomationControlled --disable-features=IsolateOrigins,site-per-process}"
: "${CHROMIUM_CDP_READY_TIMEOUT_S:=60}"

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

"${CHROMIUM_BIN}" \
  "${chromium_args[@]}" \
  --remote-debugging-address="${CHROMIUM_CDP_HOST}" \
  --remote-debugging-port="${CHROMIUM_CDP_PORT}" \
  --remote-allow-origins="*" \
  --user-data-dir="${CHROMIUM_USER_DATA_DIR}" \
  about:blank &

chromium_pid=$!

echo "[chromium] pid=${chromium_pid} cdp=http://${CHROMIUM_CDP_HOST}:${CHROMIUM_CDP_PORT}"

ready=0
for _ in $(seq 1 "${CHROMIUM_CDP_READY_TIMEOUT_S}"); do
  if curl -fsS "http://127.0.0.1:${CHROMIUM_CDP_PORT}/json/version" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [ "${ready}" != "1" ]; then
  echo "[chromium] CDP not ready after ${CHROMIUM_CDP_READY_TIMEOUT_S}s" >&2
  kill -TERM "${chromium_pid}" 2>/dev/null || true
  wait "${chromium_pid}" 2>/dev/null || true
  exit 1
fi

echo "[chromium] CDP ready"

wait "${chromium_pid}"
