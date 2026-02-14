#!/usr/bin/env bash
set -euo pipefail

: "${PORT:=18800}"
: "${CHROMIUM_CDP_PORT_INTERNAL:=18801}"
: "${CHROMIUM_BIN:=chromium}"
: "${CHROMIUM_USER_DATA_DIR:=/data/chromium-user-data}"
: "${CHROMIUM_FLAGS:=--headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check --disable-blink-features=AutomationControlled --disable-features=IsolateOrigins,site-per-process}"
: "${CHROMIUM_CDP_READY_TIMEOUT_S:=60}"
: "${NGINX_BIN:=nginx}"

mkdir -p "${CHROMIUM_USER_DATA_DIR}"
chmod 700 "${CHROMIUM_USER_DATA_DIR}"

# Remove stale lock files from unclean shutdowns.
rm -f \
  "${CHROMIUM_USER_DATA_DIR}/SingletonLock" \
  "${CHROMIUM_USER_DATA_DIR}/SingletonCookie" \
  "${CHROMIUM_USER_DATA_DIR}/SingletonSocket"

# LevelDB uses a file named "LOCK" in each DB dir. In containers, Chromium often gets
# terminated hard; removing these is generally safe as long as no other Chromium
# process is using the same profile directory.
find "${CHROMIUM_USER_DATA_DIR}" -type f -name "LOCK" -delete 2>/dev/null || true

if [ -n "${CHROMIUM_EXTRA_FLAGS:-}" ]; then
  CHROMIUM_FLAGS="${CHROMIUM_FLAGS} ${CHROMIUM_EXTRA_FLAGS}"
fi

read -r -a chromium_args <<< "${CHROMIUM_FLAGS}"

"${CHROMIUM_BIN}" --version || true

"${CHROMIUM_BIN}" \
  "${chromium_args[@]}" \
  --remote-debugging-address="127.0.0.1" \
  --remote-debugging-port="${CHROMIUM_CDP_PORT_INTERNAL}" \
  --remote-allow-origins="*" \
  --user-data-dir="${CHROMIUM_USER_DATA_DIR}" \
  about:blank &

chromium_pid=$!

cleanup() {
  if [ -n "${chromium_pid:-}" ]; then kill -TERM "${chromium_pid}" 2>/dev/null || true; fi
  if [ -n "${nginx_pid:-}" ]; then kill -TERM "${nginx_pid}" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

echo "[chromium] pid=${chromium_pid} cdp_internal=http://127.0.0.1:${CHROMIUM_CDP_PORT_INTERNAL} public_port=${PORT}"

ready=0
for _ in $(seq 1 "${CHROMIUM_CDP_READY_TIMEOUT_S}"); do
  if curl -fsS "http://127.0.0.1:${CHROMIUM_CDP_PORT_INTERNAL}/json/version" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [ "${ready}" != "1" ]; then
  echo "[chromium] CDP not ready after ${CHROMIUM_CDP_READY_TIMEOUT_S}s" >&2
  exit 1
fi

echo "[chromium] CDP ready"

nginx_conf="/tmp/nginx.conf"
cat >"${nginx_conf}" <<EOF
worker_processes  1;
pid /tmp/nginx.pid;

events { worker_connections  1024; }

http {
  access_log off;
  error_log /dev/stderr warn;

  server {
    listen ${PORT};
    listen [::]:${PORT};

	    # Used by Railway healthchecks: maps to the underlying Chromium /json/version endpoint.
	    location = /healthz {
	      proxy_http_version 1.1;
	      # Chromium's DevTools HTTP server enforces a Host allowlist; rewrite Railway's
	      # private hostname Host header (chromium-cdp.railway.internal) to localhost.
	      proxy_set_header Host localhost;
	      proxy_pass http://127.0.0.1:${CHROMIUM_CDP_PORT_INTERNAL}/json/version;
	    }

	    location / {
	      proxy_http_version 1.1;
	      proxy_set_header Host localhost;
	      proxy_set_header Upgrade \$http_upgrade;
	      proxy_set_header Connection \"upgrade\";
	      proxy_pass http://127.0.0.1:${CHROMIUM_CDP_PORT_INTERNAL};
	    }
  }
}
EOF

echo "[nginx] starting reverse proxy on :${PORT} -> 127.0.0.1:${CHROMIUM_CDP_PORT_INTERNAL}"
${NGINX_BIN} -c "${nginx_conf}" -g 'daemon off;' &
nginx_pid=$!

wait -n "${chromium_pid}" "${nginx_pid}"
