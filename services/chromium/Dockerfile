FROM debian:bookworm-slim

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    chromium \
    chromium-sandbox \
    ca-certificates \
    curl \
    nginx-light \
  && rm -rf /var/lib/apt/lists/*

COPY services/chromium/start.sh /usr/local/bin/start-chromium.sh
RUN chmod +x /usr/local/bin/start-chromium.sh

ENTRYPOINT ["/usr/local/bin/start-chromium.sh"]
