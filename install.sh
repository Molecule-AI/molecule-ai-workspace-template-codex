#!/usr/bin/env bash
# install.sh — set up the codex CLI on a bare-host workspace (the SaaS
# EC2 boot path). Mirrors the Dockerfile's `npm install -g @openai/codex`
# step that the Docker entrypoint takes for granted but the bare-host
# user-data never runs (CP clones the template + pip-installs requirements
# only).
#
# Symmetry: hermes ships an install.sh that mirrors its Dockerfile setup.
# Codex was missing one — caught live during the 2026-05-03 4-runtime
# A2A E2E. Workspace status flipped to `failed` at boot with:
#   RuntimeError: codex binary not on PATH. The Dockerfile installs
#   @openai/codex globally via npm — if you're running outside the
#   container, install it with: `npm install -g @openai/codex`
#
# The runtime user (ubuntu on EC2) runs this script via:
#   sudo -u ubuntu -E -H bash -c 'exec bash /opt/adapter/install.sh'
# so `sudo` is available for system-package installs but the working
# environment is the workspace user's.

set -euo pipefail

NODE_VERSION="${NODE_VERSION:-20}"  # codex CLI requires Node ≥20

echo "[install.sh] codex bare-host setup starting (user=$USER, home=$HOME)"

# --- Ensure Node ≥20 is installed ---
# The user-data script runs `apt-get install -y nodejs` which on Ubuntu
# 24.04 lands Node 18.x — codex 0.72.x refuses to start under <20. Drop
# any prior version and install fresh from NodeSource.
need_node20=true
if command -v node >/dev/null 2>&1; then
  cur_major=$(node -v | sed -E 's/^v([0-9]+).*/\1/')
  if [ "$cur_major" -ge "$NODE_VERSION" ] 2>/dev/null; then
    need_node20=false
    echo "[install.sh] Node $(node -v) already meets ≥${NODE_VERSION} requirement"
  fi
fi

if [ "$need_node20" = "true" ]; then
  echo "[install.sh] installing Node ${NODE_VERSION}.x from NodeSource..."
  sudo apt-get remove -y --purge nodejs npm 2>/dev/null || true
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash -
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs
  echo "[install.sh] Node $(node -v) ready"
fi

# --- Install codex CLI globally ---
# Pin matches the Dockerfile (^0.72). The codex app-server protocol is
# experimental and breaks across minors; bump deliberately when
# validating a new release.
if ! command -v codex >/dev/null 2>&1; then
  echo "[install.sh] installing @openai/codex@^0.72 globally..."
  sudo npm install -g @openai/codex@^0.72
fi

# --- Verify ---
# Adapter setup() raises RuntimeError if `which codex` returns nothing,
# so confirm here before handing off. Print the resolved path + version
# into the boot log so debugging never has to ask "did the install
# happen?" again.
if ! command -v codex >/dev/null 2>&1; then
  echo "[install.sh] FATAL: codex still not on PATH after install" >&2
  exit 1
fi
echo "[install.sh] codex ready: $(command -v codex) ($(codex --version 2>/dev/null || echo version-unknown))"
