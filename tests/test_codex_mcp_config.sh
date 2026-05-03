#!/usr/bin/env bash
# tests/test_codex_mcp_config.sh — verifies codex_mcp_config.sh appends
# the [mcp_servers.molecule] block to ~/.codex/config.toml with the
# right command/args/env shape, composes correctly with the minimax
# provider block, and is idempotent across reboots.
#
# Run via: bash tests/test_codex_mcp_config.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/codex_mcp_config.sh"
MINIMAX_SCRIPT="${REPO_ROOT}/codex_minimax_config.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: codex_mcp_config.sh missing or not executable at $SCRIPT" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap "rm -rf $WORK" EXIT

PASS=0
FAIL=0

assert() {
  local name="$1"
  local cond="$2"
  if eval "$cond"; then
    echo "  ok: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (condition: $cond)" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ---- case 1: standalone — writes the molecule MCP block ------------
echo "=== case 1: standalone write — block lands with required fields ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin:/usr/local/bin" \
    WORKSPACE_ID="ws-test-aaa" PLATFORM_URL="http://platform:8080" \
    MOLECULE_ORG_ID="org-test-bbb" CONFIGS_DIR="/configs" \
  bash "$SCRIPT" > "$WORK/case1.out" 2>&1 || true

assert "case1 logs a write line" "grep -q '\[codex-mcp\] wrote' '$WORK/case1.out'"
assert "case1 writes config.toml" "[ -f '$WORK/codex/config.toml' ]"
assert "case1 declares [mcp_servers.molecule]" \
  "grep -q '^\[mcp_servers\.molecule\]' '$WORK/codex/config.toml'"
assert "case1 sets args = -m molecule_runtime.a2a_mcp_server" \
  "grep -q 'args = \[\"-m\", \"molecule_runtime.a2a_mcp_server\"\]' '$WORK/codex/config.toml'"
assert "case1 declares [mcp_servers.molecule.env] subtable" \
  "grep -q '^\[mcp_servers\.molecule\.env\]' '$WORK/codex/config.toml'"
assert "case1 propagates WORKSPACE_ID" \
  "grep -q 'WORKSPACE_ID = \"ws-test-aaa\"' '$WORK/codex/config.toml'"
assert "case1 propagates PLATFORM_URL" \
  "grep -q 'PLATFORM_URL = \"http://platform:8080\"' '$WORK/codex/config.toml'"
assert "case1 propagates MOLECULE_ORG_ID" \
  "grep -q 'MOLECULE_ORG_ID = \"org-test-bbb\"' '$WORK/codex/config.toml'"
assert "case1 propagates CONFIGS_DIR" \
  "grep -q 'CONFIGS_DIR = \"/configs\"' '$WORK/codex/config.toml'"
assert "case1 declares env_vars passthrough for inbound secret + PYTHONPATH" \
  "grep -q 'env_vars = \[.*MOLECULE_INBOUND_SECRET.*PLATFORM_INBOUND_SECRET.*PYTHONPATH.*\]' '$WORK/codex/config.toml'"
assert "case1 sets startup_timeout_sec to 30s" \
  "grep -q 'startup_timeout_sec = 30' '$WORK/codex/config.toml'"

# ---- case 2: composes with minimax block (real-world boot order) ---
echo "=== case 2: composes with codex_minimax_config.sh (full boot order) ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"

# Step 1: minimax script writes provider block (overwrite mode).
env -i MINIMAX_API_KEY="mm-test-123" HOME="$WORK" CODEX_HOME="$WORK/codex" \
    PATH="/usr/bin:/bin:/usr/local/bin" \
  bash "$MINIMAX_SCRIPT" > "$WORK/case2-minimax.out" 2>&1 || true

# Step 2: mcp script appends molecule block.
env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin:/usr/local/bin" \
    WORKSPACE_ID="ws-2" PLATFORM_URL="http://platform:8080" \
  bash "$SCRIPT" > "$WORK/case2-mcp.out" 2>&1 || true

assert "case2 keeps the minimax provider block" \
  "grep -q '^\[model_providers\.minimax\]' '$WORK/codex/config.toml'"
assert "case2 keeps model_provider = minimax line" \
  "grep -q 'model_provider = \"minimax\"' '$WORK/codex/config.toml'"
assert "case2 also has the molecule MCP block" \
  "grep -q '^\[mcp_servers\.molecule\]' '$WORK/codex/config.toml'"
assert "case2 writes molecule env subtable" \
  "grep -q '^\[mcp_servers\.molecule\.env\]' '$WORK/codex/config.toml'"

# ---- case 3: idempotent — re-running doesn't duplicate the block ---
echo "=== case 3: idempotent (reboot) — single molecule block remains ==="
# Re-run the mcp script against an already-configured config.toml.
env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin:/usr/local/bin" \
    WORKSPACE_ID="ws-2-rebooted" PLATFORM_URL="http://platform:8080" \
  bash "$SCRIPT" > "$WORK/case3.out" 2>&1 || true

assert "case3 has exactly one [mcp_servers.molecule] header" \
  "[ \"\$(grep -cE '^\[mcp_servers\.molecule\]\$' '$WORK/codex/config.toml')\" = '1' ]"
# Also assert exactly one env subtable header — the first version of
# the strip awk only matched the parent header and left orphaned
# `[mcp_servers.molecule.env]` blocks behind on every reboot, which
# meant codex would parse the OLDEST WORKSPACE_ID (the first env
# subtable wins on duplicate-key parsing). Hard to detect from outside.
assert "case3 has exactly one [mcp_servers.molecule.env] subtable header" \
  "[ \"\$(grep -cE '^\[mcp_servers\.molecule\.env\]\$' '$WORK/codex/config.toml')\" = '1' ]"
assert "case3 picked up the new WORKSPACE_ID" \
  "grep -q 'WORKSPACE_ID = \"ws-2-rebooted\"' '$WORK/codex/config.toml'"
assert "case3 dropped the old WORKSPACE_ID" \
  "! grep -q 'WORKSPACE_ID = \"ws-2\"\$' '$WORK/codex/config.toml'"
assert "case3 still has the minimax provider block intact" \
  "grep -q '^\[model_providers\.minimax\]' '$WORK/codex/config.toml'"

# ---- case 4: PLATFORM_URL falls back to a2a_client.py default ------
echo "=== case 4: missing PLATFORM_URL falls back to default ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin:/usr/local/bin" \
    WORKSPACE_ID="ws-4" \
  bash "$SCRIPT" > "$WORK/case4.out" 2>&1 || true

assert "case4 falls back to http://platform:8080 default" \
  "grep -q 'PLATFORM_URL = \"http://platform:8080\"' '$WORK/codex/config.toml'"

# ---- case 5: MOLECULE_MCP_PYTHON override --------------------------
echo "=== case 5: MOLECULE_MCP_PYTHON override ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin:/usr/local/bin" \
    MOLECULE_MCP_PYTHON="/opt/venv/bin/python3.11" WORKSPACE_ID="ws-5" \
  bash "$SCRIPT" > "$WORK/case5.out" 2>&1 || true

assert "case5 picks up python override" \
  "grep -q 'command = \"/opt/venv/bin/python3.11\"' '$WORK/codex/config.toml'"

echo
echo "results: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
