FROM debian:bookworm-slim

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    chromium \
    chromium-sandbox \
    ca-certificates \
    curl \
    socat \
  && rm -rf /var/lib/apt/lists/*

COPY services/chromium/start.sh /usr/local/bin/start-chromium.sh
RUN chmod +x /usr/local/bin/start-chromium.sh

ENV PORT=18800
EXPOSE 18800

ENTRYPOINT ["/usr/local/bin/start-chromium.sh"]
