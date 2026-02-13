# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.2.12
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


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
    golang-go \
    cargo \
    build-essential \
    pkg-config \
    libssl-dev \
    pipx \
  && rm -rf /var/lib/apt/lists/*

# Install Poetry and uv via pipx, plus CLI bin paths
ENV PATH="/root/.local/bin:/root/go/bin:/root/.cargo/bin:${PATH}"
RUN pipx install poetry \
  && pipx install uv

# Install OpenClaw skill CLIs via Linux-native package managers
RUN set -eux; \
    go install github.com/steipete/wacli/cmd/wacli@latest; \
    go install github.com/steipete/goplaces/cmd/goplaces@latest; \
    go install github.com/steipete/gogcli/cmd/gog@latest; \
    go install github.com/Yakitrak/notesmd-cli@latest; \
    cargo install --locked himalaya; \
    uv tool install nano-pdf; \
    uv tool install openai-whisper

# Verify key CLIs are available
RUN command -v gh \
  && command -v ffmpeg \
  && command -v wacli \
  && command -v goplaces \
  && command -v gog \
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

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

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
