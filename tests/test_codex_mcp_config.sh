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

# ---- case 6: regression — no python imports molecule_runtime -------
# Pre-fix bug: resolver returned `command -v python3` (=/usr/bin/python3,
# stdlib only) without verifying it could import molecule_runtime, then
# codex spawned the MCP subprocess which crashed with ModuleNotFoundError
# before the JSON-RPC handshake completed. Since fix #17 the resolver
# walks each candidate and verifies `import molecule_runtime`; if none
# succeed, falls back to the venv path AND emits a warning so operators
# can debug at install-time instead of canvas-chat-time.
echo "=== case 6: warning fires when no python imports molecule_runtime ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin" \
    WORKSPACE_ID="ws-6" \
  bash "$SCRIPT" > "$WORK/case6.out" 2>&1 || true

assert "case6 emits 'cannot import molecule_runtime' warning" \
  "grep -q 'cannot import molecule_runtime' '$WORK/case6.out'"
assert "case6 last-resort fallback is /opt/molecule-venv/bin/python3" \
  "grep -q 'command = \"/opt/molecule-venv/bin/python3\"' '$WORK/codex/config.toml'"

# ---- case 7: resolver picks first candidate that imports molecule_runtime
# Mock python that pretends `import molecule_runtime` succeeds. Place it
# at the front of PATH and assert the resolver picks it over the system
# python (which has no molecule_runtime in CI).
echo "=== case 7: resolver picks PATH python that can import molecule_runtime ==="
rm -rf "$WORK/codex" "$WORK/fake-bin"
mkdir -p "$WORK/codex" "$WORK/fake-bin"
cat > "$WORK/fake-bin/python3" <<'EOF'
#!/bin/bash
# Mock python: `python3 -c "import molecule_runtime"` succeeds; everything else fails.
case "$*" in
  *"import molecule_runtime"*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/fake-bin/python3"

env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="$WORK/fake-bin:/usr/bin:/bin" \
    WORKSPACE_ID="ws-7" \
  bash "$SCRIPT" > "$WORK/case7.out" 2>&1 || true

assert "case7 picks fake python from PATH (importable)" \
  "grep -q \"command = \\\"$WORK/fake-bin/python3\\\"\" '$WORK/codex/config.toml'"
assert "case7 does NOT emit the cannot-import warning" \
  "! grep -q 'cannot import molecule_runtime' '$WORK/case7.out'"

# ---- case 8: ordering parity — venv candidates BEFORE PATH lookup --
# Anchor the resolver's candidate ordering: /opt/molecule-venv/bin/python3
# must be tried BEFORE `command -v python3`. Without this ordering the
# original bug returns: on a machine with both /opt/molecule-venv/bin/python3
# AND /usr/bin/python3 importable, picking the system one means leaking
# whatever stale molecule_runtime was installed there.
echo "=== case 8: parity — venv candidates appear before PATH in resolver ==="
venv_line=$(grep -nE '/opt/molecule-venv/bin/python3' "$SCRIPT" | head -1 | cut -d: -f1)
path_line=$(grep -nE 'command -v python3' "$SCRIPT" | head -1 | cut -d: -f1)
assert "case8 venv path is referenced in $SCRIPT" "[ -n '$venv_line' ]"
assert "case8 PATH lookup is referenced in $SCRIPT" "[ -n '$path_line' ]"
assert "case8 venv path appears BEFORE PATH lookup (line $venv_line < $path_line)" \
  "[ '$venv_line' -lt '$path_line' ]"

echo
echo "results: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
