#!/usr/bin/env bash
# tests/test_codex_bridge.sh — exercises codex_bridge.sh's config-
# generation paths without spawning the actual litellm proxy. Stubs
# out litellm + curl so the script runs end-to-end on a CI runner
# that doesn't have litellm installed.
#
# Run via: bash tests/test_codex_bridge.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/codex_bridge.sh"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: codex_bridge.sh missing or not executable at $SCRIPT" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap "rm -rf $WORK" EXIT

# Stub directory shadows the real litellm + curl during the test run.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/litellm" <<'EOF'
#!/usr/bin/env bash
# fake litellm — just sleep so the script's `&` background spawn has a
# real PID to track. Outputs get captured in the bridge log.
echo "fake-litellm: args=$*"
sleep 60
EOF
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl — always reports liveliness OK so the wait-loop short-
# circuits immediately. The real curl is on PATH if any production
# code path needs it.
case "$*" in
  *health/liveliness*) exit 0 ;;
  *) exec /usr/bin/curl "$@" ;;
esac
EOF
chmod +x "$WORK/bin/litellm" "$WORK/bin/curl"

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

run_case() {
  local name="$1"
  shift
  echo "=== $name ==="
  rm -rf "$WORK/codex"
  mkdir -p "$WORK/codex"
  # Subshell — env tweaks only apply to this case.
  (
    PATH="$WORK/bin:$PATH"
    HOME="$WORK"
    CODEX_HOME="$WORK/codex"
    LITELLM_CONFIG="$WORK/litellm.yaml"
    LITELLM_LOG="$WORK/litellm.log"
    LITELLM_PORT=14000
    "$@"
  )
}

# ---- case 1: no alternate-provider key → bridge stays disabled ----
run_case "no key → bridge no-op" env -i HOME="$WORK" CODEX_HOME="$WORK/codex" PATH="$WORK/bin:/usr/bin:/bin" \
  bash "$SCRIPT" > "$WORK/case1.out" 2>&1 || true
assert "case1 emits 'bridge disabled'" "grep -q 'bridge disabled' '$WORK/case1.out'"
assert "case1 does NOT write codex config" "[ ! -f '$WORK/codex/config.toml' ]"
assert "case1 does NOT write litellm config" "[ ! -f '$WORK/litellm.yaml' ]"

# ---- case 2: MINIMAX_API_KEY set → bridge activates ----
run_case "minimax key → bridge writes both configs" \
  env MINIMAX_API_KEY="mm-test-123" PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK" CODEX_HOME="$WORK/codex" \
      LITELLM_CONFIG="$WORK/litellm.yaml" LITELLM_LOG="$WORK/litellm.log" LITELLM_PORT=14000 \
  bash "$SCRIPT" > "$WORK/case2.out" 2>&1 || true

assert "case2 logs activation"   "grep -q 'activating minimax bridge' '$WORK/case2.out'"
assert "case2 logs ready signal" "grep -q 'litellm ready on' '$WORK/case2.out'"
assert "case2 writes litellm config" "[ -f '$WORK/litellm.yaml' ]"
assert "case2 litellm config names model" "grep -q 'model_name: codex-bridge' '$WORK/litellm.yaml'"
assert "case2 litellm config uses minimax provider" "grep -q 'minimax/' '$WORK/litellm.yaml'"
assert "case2 litellm config refers to env key" "grep -q 'os.environ/MINIMAX_API_KEY' '$WORK/litellm.yaml'"
assert "case2 writes codex config.toml" "[ -f '$WORK/codex/config.toml' ]"
assert "case2 codex config sets model_provider to bridge" "grep -q 'model_provider = .minimax-bridge.' '$WORK/codex/config.toml'"
assert "case2 codex config wires base_url to localhost litellm" "grep -q 'base_url = .http://127.0.0.1:14000/v1.' '$WORK/codex/config.toml'"
assert "case2 codex config keeps wire_api responses" "grep -q 'wire_api = .responses.' '$WORK/codex/config.toml'"

# ---- case 3: CODEX_BRIDGE_MODEL override propagates ----
run_case "override CODEX_BRIDGE_MODEL surfaces in litellm config" \
  env MINIMAX_API_KEY="mm-test-123" CODEX_BRIDGE_MODEL="MiniMax-M2.1-lightning" \
      PATH="$WORK/bin:/usr/bin:/bin" HOME="$WORK" CODEX_HOME="$WORK/codex" \
      LITELLM_CONFIG="$WORK/litellm.yaml" LITELLM_LOG="$WORK/litellm.log" LITELLM_PORT=14000 \
  bash "$SCRIPT" > "$WORK/case3.out" 2>&1 || true

assert "case3 picks up override" "grep -q 'minimax/MiniMax-M2.1-lightning' '$WORK/litellm.yaml'"

# Kill any lingering fake litellm bg processes.
pkill -f "fake-litellm" 2>/dev/null || true
pkill -f "$WORK/bin/litellm" 2>/dev/null || true

echo
echo "results: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
