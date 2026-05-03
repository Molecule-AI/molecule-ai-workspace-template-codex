FROM python:3.11-slim

# System deps:
#   curl, ca-certificates — TLS + Node tarball download
#   git           — codex's agent tools use git
#   gosu          — drop privileges in start.sh
#   xz-utils      — Node tarball is .tar.xz
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates git gosu xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 LTS via NodeSource (codex CLI requires Node ≥20).
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Non-root agent user. codex stores sessions under ~/.codex/sessions/
# so /home/agent should be a persistent volume in production
# deployments to keep thread state across workspace restarts.
RUN useradd -u 1000 -m -s /bin/bash agent

WORKDIR /app

# RUNTIME_VERSION arg matches hermes/openclaw conventions — when set
# (cascade-triggered builds), it pins the exact runtime version PyPI
# just published. Including it as ARG changes the cache key for the
# pip install layer below — without this, identical Dockerfile +
# requirements.txt would let docker reuse the cached layer with the
# previous version baked in (the cache trap that bit us 5x on
# 2026-04-27 — see runtime publish pipeline gates memory).
ARG RUNTIME_VERSION=

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    if [ -n "${RUNTIME_VERSION}" ]; then \
      pip install --no-cache-dir --upgrade "molecule-ai-workspace-runtime==${RUNTIME_VERSION}"; \
    fi

COPY adapter.py executor.py app_server.py __init__.py ./
COPY start.sh /usr/local/bin/start.sh
COPY codex_minimax_config.sh /usr/local/bin/codex_minimax_config.sh
COPY codex_mcp_config.sh /usr/local/bin/codex_mcp_config.sh
RUN chmod +x /usr/local/bin/start.sh \
              /usr/local/bin/codex_minimax_config.sh \
              /usr/local/bin/codex_mcp_config.sh

# --- Install the OpenAI Codex CLI globally as root (binary lives in
# /usr/lib/node_modules and symlinks into /usr/bin/codex; available to
# both root and the agent user).
#
# Pin to ^0.57 — MiniMax's official codex-cli docs flag a compat issue
# on later versions ("The latest version of Codex CLI has compatibility
# issues, version 0.57.0 is recommended"). 0.57 also still ships the
# `app-server` subcommand our executor depends on. Bump only after
# re-testing the executor against the new release's notification schema.
RUN npm install -g @openai/codex@^0.57

USER agent
WORKDIR /home/agent
USER root
WORKDIR /app

ENV ADAPTER_MODULE=adapter \
    PYTHONPATH=/app

# start.sh is intentionally minimal — codex doesn't need a separate
# daemon to boot; the app-server is a stdio child spawned by
# executor.py on the first A2A turn.
ENTRYPOINT ["/usr/local/bin/start.sh"]
