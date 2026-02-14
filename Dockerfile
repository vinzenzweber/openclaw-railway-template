# Runtime image (Node + Postgres 18 + pgvector)
FROM node:22-bookworm
ENV NODE_ENV=production

# Install Chromium
RUN apt-get update && \
    apt-get install -y chromium chromium-sandbox ca-certificates curl gnupg debsig-verify && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install Playwright
RUN npm install -g playwright

# Install OpenClaw (official npm distribution)
# Pin this to a specific version in Railway via build arg if you want deterministic builds.
ARG OPENCLAW_NPM_VERSION=latest
RUN npm install -g "openclaw@${OPENCLAW_NPM_VERSION}" \
  && openclaw --version

# Install 1Password CLI (official APT repo + package signature policy)
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
      | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg; \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/${ARCH} stable main" \
      > /etc/apt/sources.list.d/1password.list; \
    mkdir -p /etc/debsig/policies/AC2D62742012EA22; \
    curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol \
      -o /etc/debsig/policies/AC2D62742012EA22/1password.pol; \
    mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22; \
    curl -sS https://downloads.1password.com/linux/keys/1password.asc \
      | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends 1password-cli; \
    rm -rf /var/lib/apt/lists/*

# Verify installations
RUN chromium --version && op --version

# Install Postgres 18 + pgvector from PGDG
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    python3 \
    python3-venv \
    python3-pip \
    python3-psycopg2 \
    ffmpeg \
    gh \
    pipx \
  && rm -rf /var/lib/apt/lists/*

# Install Poetry and uv via pipx, plus CLI bin paths
ENV PATH="/root/.local/bin:/root/go/bin:/usr/local/go/bin:${PATH}"
RUN pipx install poetry \
  && pipx install uv

# Install OpenClaw skill CLIs via Linux-native package managers
RUN set -eux; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) GOARCH=amd64; TOOLARCH=amd64; HIMALAYA_ARCH=x86_64 ;; \
      arm64) GOARCH=arm64; TOOLARCH=arm64; HIMALAYA_ARCH=aarch64 ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go1.22.12.linux-${GOARCH}.tar.gz" -o /tmp/go.tgz; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm -f /tmp/go.tgz; \
    go version; \
    go install github.com/steipete/wacli/cmd/wacli@latest; \
    curl -fsSL "https://github.com/steipete/goplaces/releases/download/v0.2.1/goplaces_0.2.1_linux_${TOOLARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin goplaces; \
    curl -fsSL "https://github.com/steipete/gogcli/releases/download/v0.9.0/gogcli_0.9.0_linux_${TOOLARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin gog; \
    curl -fsSL "https://github.com/Yakitrak/notesmd-cli/releases/download/v0.3.0/notesmd-cli_0.3.0_linux_${TOOLARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin notesmd-cli; \
    curl -fsSL "https://github.com/pimalaya/himalaya/releases/download/v1.1.0/himalaya.${HIMALAYA_ARCH}-linux.tgz" \
      | tar -xz -C /usr/local/bin himalaya; \
    npm install -g @steipete/summarize; \
    uv tool install nano-pdf; \
    uv tool install openai-whisper

# Verify key CLIs are available
RUN command -v gh \
  && command -v ffmpeg \
  && command -v wacli \
  && command -v goplaces \
  && command -v gog \
  && command -v summarize \
  && command -v notesmd-cli \
  && command -v himalaya \
  && command -v nano-pdf \
  && command -v whisper \
  && whisper --help >/dev/null

RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    postgresql-18 \
    postgresql-client-18 \
    postgresql-18-pgvector \
  && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY src ./src

# Postgres defaults
ENV POSTGRES_USER=postgres \
  POSTGRES_PASSWORD=postgres \
  POSTGRES_DB=postgres

# Initialize pgvector extension on first boot

# Start Postgres and the Node server
COPY scripts/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
EXPOSE 5432
ENTRYPOINT ["/usr/local/bin/start.sh"]
