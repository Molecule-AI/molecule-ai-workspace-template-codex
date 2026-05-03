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

# Generate the MiniMax provider config.toml when MINIMAX_API_KEY is
# present. No-op when the operator is using OpenAI direct (the env
# the codex CLI checks defaults to OPENAI_API_KEY in that path).
# Source: https://platform.minimax.io/docs/token-plan/codex-cli
if [ -f /usr/local/bin/codex_minimax_config.sh ]; then
  HOME=/home/agent CODEX_HOME=/home/agent/.codex \
    bash /usr/local/bin/codex_minimax_config.sh
elif [ -f /app/codex_minimax_config.sh ]; then
  HOME=/home/agent CODEX_HOME=/home/agent/.codex \
    bash /app/codex_minimax_config.sh
fi

# Append the molecule A2A MCP server block — gives the codex agent
# list_peers / delegate_task / commit_memory etc. as MCP tools (same
# capability claude-code's mcp_servers["a2a"] wiring provides). Order
# matters: codex_minimax_config.sh writes config.toml with `cat >`
# (overwrite); this one uses `cat >>` (append) and so must run after.
# Tracks issue molecule-ai-workspace-template-codex#15.
if [ -f /usr/local/bin/codex_mcp_config.sh ]; then
  HOME=/home/agent CODEX_HOME=/home/agent/.codex \
    bash /usr/local/bin/codex_mcp_config.sh
elif [ -f /app/codex_mcp_config.sh ]; then
  HOME=/home/agent CODEX_HOME=/home/agent/.codex \
    bash /app/codex_mcp_config.sh
fi
# Reapply ownership in case the helpers wrote into agent's home as root.
chown -R agent:agent /home/agent/.codex 2>/dev/null || true

# Provider preflight: at least one of OPENAI_API_KEY or MINIMAX_API_KEY
# must be set. The adapter's setup() also checks but surfacing here
# gives operators a clearer signal in container logs.
if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${MINIMAX_API_KEY:-}" ]; then
  echo "[start.sh] WARN: neither OPENAI_API_KEY nor MINIMAX_API_KEY set. Workspace will fail preflight." >&2
fi

# Hand off to molecule-runtime. From here, every A2A message routes
# through executor.py → app_server.py → codex app-server child.
exec gosu agent molecule-runtime
