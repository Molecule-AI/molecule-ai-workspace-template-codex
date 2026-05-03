#!/usr/bin/env bash
# Boot script for the codex workspace template.
#
# Unlike hermes (which boots a separate gateway daemon on :8642 first),
# codex's app-server is a stdio child of executor.py — there's no
# network service to start, no port to wait on, no health endpoint.
# This script just verifies the binary is installed and exec's
# molecule-runtime.

set -euo pipefail

# Fail-fast preflight: codex binary must be on PATH. The Dockerfile
# installs @openai/codex globally; if it isn't here, something's wrong
# with the image build.
if ! command -v codex >/dev/null 2>&1; then
  echo "[start.sh] FATAL: codex binary not on PATH. Image misbuilt?" >&2
  exit 1
fi

CODEX_VERSION="$(codex --version 2>&1 || echo unknown)"
echo "[start.sh] codex installed: ${CODEX_VERSION}"

# Pre-create ~/.codex so codex doesn't try to mkdir it on first run as
# the wrong user. Persistent volume mount goes here for thread state.
install -d -o agent -g agent /home/agent/.codex
install -d -o agent -g agent /home/agent/.codex/sessions

# Activate the LiteLLM bridge if a non-OpenAI provider key is present.
# Sourced (not exec'd) so it can `export OPENAI_API_KEY=...` for codex.
# When no alternate-provider key is set, the script returns early and
# codex falls through to its default OpenAI behavior.
if [ -f /usr/local/bin/codex_bridge.sh ]; then
  HOME=/home/agent CODEX_HOME=/home/agent/.codex source /usr/local/bin/codex_bridge.sh
elif [ -f /app/codex_bridge.sh ]; then
  HOME=/home/agent CODEX_HOME=/home/agent/.codex source /app/codex_bridge.sh
fi
# Reapply ownership in case the bridge wrote into the agent's home as root.
chown -R agent:agent /home/agent/.codex 2>/dev/null || true

# Now check key. After the bridge sources, OPENAI_API_KEY is always
# set (real OpenAI key for direct mode; sentinel placeholder for
# bridge mode — LiteLLM doesn't enforce it without a master_key).
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "[start.sh] WARN: OPENAI_API_KEY not set and no alternate-provider key (e.g. MINIMAX_API_KEY) found. Workspace will fail preflight." >&2
fi

# Hand off to molecule-runtime. From here, every A2A message routes
# through executor.py → app_server.py → codex app-server child.
exec gosu agent molecule-runtime
