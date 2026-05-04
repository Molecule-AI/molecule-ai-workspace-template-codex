# Pin by digest, not tag — avoids surprise base-bumps. Pairs with the
# Trivy gate in molecule-ci/.github/workflows/publish-template-image.yml
# (PR #35): pin avoids unexpected upgrade, Trivy catches if the pinned
# digest accumulates fixable HIGH/CRITICAL vulns over time. Bump
# deliberately by re-resolving:
#   docker pull --platform linux/amd64 python:3.11-slim
#   docker inspect --format='{{index .RepoDigests 0}}' python:3.11-slim
# Last resolved: 2026-05-03 (RFC #388 PR-2b).
FROM python:3.11-slim@sha256:6d85378d88a19cd4d76079817532d62232be95757cb45945a99fec8e8084b9c2

# ─────────────────────────────────────────────────────────────────────
# CACHE-FRIENDLY LAYER ORDER — read before adding new layers.
#
# Layers are ordered slowest-and-most-stable → fastest-and-most-changing.
# When `cache-from: type=gha` hits, Docker reuses the cached output of a
# layer iff (a) its command text is identical AND (b) every prior layer
# was also a cache hit. Any earlier layer that changes invalidates ALL
# subsequent layers.
#
# The expensive layers are:
#   1. apt-get install (system deps)
#   2. NodeSource setup_20.x + apt install nodejs (~80 MB)
#   3. pip install -r requirements.txt
#   4. npm install -g @openai/codex@^0.57 (codex CLI binary + deps)
#
# These ~rarely change (only on Dockerfile edits / requirements bumps /
# codex pin bumps) so they belong UP TOP. The cheap, high-churn `COPY
# *.py` layers belong AT THE BOTTOM. Putting the codex install below
# the COPYs caused every adapter.py / executor.py / start.sh change to
# bust its cache. Don't move the COPYs back above the codex install.
# Same pattern shipped to template-hermes in PR #48.
# ─────────────────────────────────────────────────────────────────────

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

# Bump pip + setuptools + wheel BEFORE installing project deps — the
# python:3.11-slim base ships old transitives (jaraco.context, wheel,
# setuptools) Trivy flags as fixable HIGH CVEs. Bumping here resolves
# them at the metadata layer; subsequent pip installs use the upgraded
# resolvers. molecule-ci#38 Phase-1.
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    if [ -n "${RUNTIME_VERSION}" ]; then \
      pip install --no-cache-dir --upgrade "molecule-ai-workspace-runtime==${RUNTIME_VERSION}"; \
    fi

# --- Install the OpenAI Codex CLI globally as root (binary lives in
# /usr/lib/node_modules and symlinks into /usr/bin/codex; available to
# both root and the agent user).
#
# This MUST stay above the COPY *.py layers below (see cache-order
# rationale at the top). The npm install command text is fixed — the
# pin (^0.57) is what changes the cache key, so a deliberate bump
# invalidates this layer; routine Python edits do not.
#
# Pin to ^0.57 — MiniMax's official codex-cli docs flag a compat issue
# on later versions ("The latest version of Codex CLI has compatibility
# issues, version 0.57.0 is recommended"). 0.57 also still ships the
# `app-server` subcommand our executor depends on. Bump only after
# re-testing the executor against the new release's notification schema.
RUN npm install -g @openai/codex@^0.57

# ─────────────────────────────────────────────────────────────────────
# Fast-changing layers — keep at the bottom.
# Edits to *.py / start.sh / codex_*_config.sh only invalidate from here
# down (~5-10 s of work) instead of busting the codex npm install.
# ─────────────────────────────────────────────────────────────────────
COPY adapter.py executor.py app_server.py __init__.py ./
COPY start.sh /usr/local/bin/start.sh
COPY codex_minimax_config.sh /usr/local/bin/codex_minimax_config.sh
COPY codex_mcp_config.sh /usr/local/bin/codex_mcp_config.sh
RUN chmod +x /usr/local/bin/start.sh \
              /usr/local/bin/codex_minimax_config.sh \
              /usr/local/bin/codex_mcp_config.sh

# Preserved from pre-reorder Dockerfile — these 4 lines flip USER/WORKDIR
# with no operation between them, so they're functionally a no-op (final
# state matches what was already in effect). Likely leftover from an
# earlier refactor where agent-user operations lived here. Kept rather
# than deleted so this PR stays scoped to the cache-order reorder; if
# the reviewer confirms they're dead, they can come out in a follow-up.
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
