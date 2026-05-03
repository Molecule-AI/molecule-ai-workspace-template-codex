#!/usr/bin/env bash
# tests/test_codex_minimax_config.sh — verifies codex_minimax_config.sh
# writes the official MiniMax provider config when MINIMAX_API_KEY is
# set, no-ops when it isn't, and honors CODEX_MINIMAX_MODEL +
# MINIMAX_API_BASE overrides.
#
# Run via: bash tests/test_codex_minimax_config.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/codex_minimax_config.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: codex_minimax_config.sh missing or not executable at $SCRIPT" >&2
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

# ---- case 1: no MINIMAX_API_KEY → no-op ----------------------------
echo "=== case 1: no key → no-op (codex falls through to OpenAI default) ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin" \
  bash "$SCRIPT" > "$WORK/case1.out" 2>&1 || true
assert "case1 logs no-op message" "grep -q 'no MINIMAX_API_KEY' '$WORK/case1.out'"
assert "case1 does not write config.toml" "[ ! -f '$WORK/codex/config.toml' ]"

# ---- case 2: MINIMAX_API_KEY set → writes official config ----------
echo "=== case 2: minimax key → writes official provider config ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env MINIMAX_API_KEY="mm-test-123" HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin" \
  bash "$SCRIPT" > "$WORK/case2.out" 2>&1 || true

assert "case2 logs a write line" "grep -q 'wrote' '$WORK/case2.out'"
assert "case2 writes config.toml" "[ -f '$WORK/codex/config.toml' ]"
assert "case2 sets default model to codex-MiniMax-M2.7" \
  "grep -q 'model = .codex-MiniMax-M2.7.' '$WORK/codex/config.toml'"
assert "case2 sets model_provider = minimax" \
  "grep -q 'model_provider = .minimax.' '$WORK/codex/config.toml'"
assert "case2 sets wire_api = chat" \
  "grep -q 'wire_api = .chat.' '$WORK/codex/config.toml'"
assert "case2 sets base_url to api.minimax.io" \
  "grep -q 'base_url = .https://api.minimax.io/v1.' '$WORK/codex/config.toml'"
assert "case2 sets env_key = MINIMAX_API_KEY" \
  "grep -q 'env_key = .MINIMAX_API_KEY.' '$WORK/codex/config.toml'"
assert "case2 disables openai auth" \
  "grep -q 'requires_openai_auth = false' '$WORK/codex/config.toml'"
assert "case2 includes retry+timeout knobs from MiniMax doc" \
  "grep -q 'request_max_retries = 4' '$WORK/codex/config.toml' && \
   grep -q 'stream_max_retries = 10' '$WORK/codex/config.toml' && \
   grep -q 'stream_idle_timeout_ms = 300000' '$WORK/codex/config.toml'"

# ---- case 3: CODEX_MINIMAX_MODEL override --------------------------
echo "=== case 3: model override propagates ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env MINIMAX_API_KEY="mm-test-123" CODEX_MINIMAX_MODEL="MiniMax-M2.1" \
    HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin" \
  bash "$SCRIPT" > "$WORK/case3.out" 2>&1 || true

assert "case3 picks up model override" \
  "grep -q 'model = .MiniMax-M2.1.' '$WORK/codex/config.toml'"

# ---- case 5: WORKSPACE_CONFIG_PATH (config.yaml model patch) -------
echo "=== case 5: patches /configs/config.yaml model field ==="
rm -rf "$WORK/codex" "$WORK/configs"
mkdir -p "$WORK/codex" "$WORK/configs"
cat > "$WORK/configs/config.yaml" <<EOF
name: test-ws
runtime: codex
a2a:
  port: 8000
  streaming: true
EOF
env MINIMAX_API_KEY="mm-test-123" HOME="$WORK" CODEX_HOME="$WORK/codex" \
    WORKSPACE_CONFIG_PATH="$WORK/configs" PATH="/usr/bin:/bin" \
  bash "$SCRIPT" > "$WORK/case5.out" 2>&1 || true

assert "case5 logs config.yaml patch" "grep -q 'patched .*config.yaml' '$WORK/case5.out'"
assert "case5 appends model to config.yaml" \
  "grep -q \"model: 'codex-MiniMax-M2.7'\" '$WORK/configs/config.yaml'"

# ---- case 6: existing model in config.yaml gets replaced -----------
echo "=== case 6: replaces existing model line in config.yaml ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
cat > "$WORK/configs/config.yaml" <<EOF
name: test-ws
model: anthropic:claude-opus-4-7
runtime: codex
EOF
env MINIMAX_API_KEY="mm-test-123" HOME="$WORK" CODEX_HOME="$WORK/codex" \
    WORKSPACE_CONFIG_PATH="$WORK/configs" PATH="/usr/bin:/bin" \
  bash "$SCRIPT" > "$WORK/case6.out" 2>&1 || true

assert "case6 model replaced (no anthropic line)" \
  "! grep -q 'anthropic:claude-opus-4-7' '$WORK/configs/config.yaml'"
assert "case6 model set to codex-MiniMax-M2.7" \
  "grep -q \"model: 'codex-MiniMax-M2.7'\" '$WORK/configs/config.yaml'"
assert "case6 has exactly one model: line" \
  "[ \"\$(grep -cE '^model:' '$WORK/configs/config.yaml')\" = '1' ]"

# ---- case 4: MINIMAX_API_BASE override (China region) --------------
echo "=== case 4: base_url override (China region) ==="
rm -rf "$WORK/codex"
mkdir -p "$WORK/codex"
env MINIMAX_API_KEY="mm-test-123" MINIMAX_API_BASE="https://api.minimaxi.com/v1" \
    HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="/usr/bin:/bin" \
  bash "$SCRIPT" > "$WORK/case4.out" 2>&1 || true

assert "case4 picks up base_url override" \
  "grep -q 'base_url = .https://api.minimaxi.com/v1.' '$WORK/codex/config.toml'"

echo
echo "results: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
