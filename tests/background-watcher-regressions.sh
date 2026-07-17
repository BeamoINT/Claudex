#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/claudex-background-watch.XXXXXX")
cleanup() {
  local file pid
  for file in "$tmp/auth.pid" "$tmp/proxy.pid" "$tmp/direct.pid"; do
    [[ -r "$file" ]] || continue
    IFS= read -r pid < "$file" || pid=""
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

home="$tmp/home"
config="$home/.config/claudex"
auth_dir="$home/.cli-proxy-api"
codex_home="$home/.codex"
bin="$tmp/bin"
mkdir -p "$config" "$auth_dir" "$codex_home" "$bin"
cp "$root/settings.json" "$config/settings.json"
cp "$root/preload.cjs" "$config/preload.cjs"
cp "$root/skill-bridge.cjs" "$config/skill-bridge.cjs"
cp "$root/usage-limit" "$config/usage-limit"
cp "$root/codex-session" "$config/codex-session"
chmod +x "$config/usage-limit" "$config/codex-session"
printf '%s\n' \
  'CLAUDEX_PROXY_TOKEN=background-secret-token' \
  "CLAUDEX_CODEX_AUTH_DIR=$auth_dir" \
  'CLAUDEX_SKILL_BRIDGE=off' \
  > "$config/env"
printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"initial-access","refresh_token":"initial-refresh","account_id":"initial-account"}}' \
  > "$codex_home/auth.json"

cat > "$bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == 'cli_auth_credentials_store="file"' && "${3:-}" == login && "${4:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
exit 0
EOF
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == *'/wham/usage'* ]]; then
    printf '%s\n' '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800}}}'
    exit 0
  fi
done
printf '%s\n' '{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}'
EOF
cat > "$bin/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '2.1.210 (test)'; exit 0 ;;
  --help) printf '%s\n' '--model --agents --append-system-prompt --permission-mode --settings --effort --add-dir --plugin-dir'; exit 0 ;;
  auto-mode)
    [[ "${2:-}" == defaults ]] || exit 2
    printf '%s\n' '{"allow":[],"environment":[],"soft_deny":[],"hard_deny":[]}'
    exit 0
    ;;
  agents)
    [[ "${2:-}" == --json ]] || exit 2
    printf 'BASE=%s AUTH=%s PROXY=%s BEDROCK=%s MANTLE=%s VERTEX=%s FOUNDRY_RESOURCE=%s FOUNDRY_KEY=%s MODEL=%s\n' \
      "${ANTHROPIC_BASE_URL:-}" "${ANTHROPIC_AUTH_TOKEN:-}" "${CLAUDEX_PROXY_TOKEN:-}" \
      "${CLAUDE_CODE_USE_BEDROCK:-}" "${ANTHROPIC_BEDROCK_MANTLE_BASE_URL:-}" \
      "${ANTHROPIC_VERTEX_PROJECT_ID:-}" "${ANTHROPIC_FOUNDRY_RESOURCE:-}" \
      "${ANTHROPIC_FOUNDRY_API_KEY:-}" "${ANTHROPIC_MODEL:-}" \
      >> "$FAKE_AGENT_REGISTRY_LOG"
    if [[ -r "$FAKE_AGENT_REGISTRY_FILE" ]]; then cat "$FAKE_AGENT_REGISTRY_FILE"; else printf '%s\n' '[]'; fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$bin/codex" "$bin/curl" "$bin/claude"

registry="$tmp/agents.json"
registry_log="$tmp/agents.log"
printf '%s\n' '[{"id":"managed-bg-test","state":"working"}]' > "$registry"

HOME="$home" PATH="$bin:$PATH" CODEX_HOME="$codex_home" CLAUDEX_CONFIG_DIR="$config" \
  CLAUDEX_CURL_BIN="$bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_TEST_MODE=1 \
  CLAUDEX_TEST_PROCESS_IDENTITY=background-parent-identity CLAUDEX_AUTH_WATCH_SECONDS=1 \
  FAKE_AGENT_REGISTRY_FILE="$registry" FAKE_AGENT_REGISTRY_LOG="$registry_log" \
  CLAUDEX_TEST_AUTH_WATCH_PID_FILE="$tmp/auth.pid" CLAUDEX_TEST_PROXY_WATCH_PID_FILE="$tmp/proxy.pid" \
  CLAUDEX_TEST_AUTH_WATCH_EXIT_FILE="$tmp/auth.exit" CLAUDEX_TEST_PROXY_WATCH_EXIT_FILE="$tmp/proxy.exit" \
  "$root/claudex" --bg background-lifecycle-test >/dev/null

for _ in {1..120}; do
  [[ -s "$tmp/auth.pid" && -s "$tmp/proxy.pid" && -s "$registry_log" ]] && break
  sleep 0.05
done
[[ -s "$tmp/auth.pid" && -s "$tmp/proxy.pid" && -s "$registry_log" ]]
auth_pid=$(<"$tmp/auth.pid")
proxy_pid=$(<"$tmp/proxy.pid")
kill -0 "$auth_pid" 2>/dev/null
kill -0 "$proxy_pid" 2>/dev/null
[[ ! -e "$tmp/auth.exit" && ! -e "$tmp/proxy.exit" ]]
if grep -v '^BASE= AUTH= PROXY= BEDROCK= MANTLE= VERTEX= FOUNDRY_RESOURCE= FOUNDRY_KEY= MODEL=$' "$registry_log" > "$tmp/secret-leaks"; then
  printf '%s\n' 'managed registry query inherited provider credentials' >&2
  exit 1
fi

printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"background-access","refresh_token":"background-refresh","account_id":"background-account"}}' \
  > "$codex_home/auth.json"
for _ in {1..120}; do
  jq -e '.account_id == "background-account"' "$auth_dir/codex-claudex-managed.json" >/dev/null 2>&1 && break
  sleep 0.05
done
jq -e '.account_id == "background-account"' "$auth_dir/codex-claudex-managed.json" >/dev/null

# Session state names and optional metadata are not a discriminator. Every
# record returned by the managed live-session registry keeps both watchers up.
printf '%s\n' '[{"id":"managed-blocked","state":"blocked"},{"id":"managed-waiting","state":"waiting","kind":"subagent"}]' > "$registry"
sleep 3.5
kill -0 "$auth_pid" 2>/dev/null
kill -0 "$proxy_pid" 2>/dev/null
[[ ! -e "$tmp/auth.exit" && ! -e "$tmp/proxy.exit" ]]

# A syntactically valid non-array response violates the registry contract. It
# is unknown rather than empty, so transient CLI/schema failures cannot stop
# credential and proxy supervision.
printf '%s\n' '{"sessions":[]}' > "$registry"
sleep 3.5
kill -0 "$auth_pid" 2>/dev/null
kill -0 "$proxy_pid" 2>/dev/null
[[ ! -e "$tmp/auth.exit" && ! -e "$tmp/proxy.exit" ]]

printf '%s\n' '[]' > "$registry"
for _ in {1..200}; do
  [[ -e "$tmp/auth.exit" && -e "$tmp/proxy.exit" ]] && break
  sleep 0.05
done
[[ -e "$tmp/auth.exit" && -e "$tmp/proxy.exit" ]]

# Direct installed watcher use has the same private boundary as the main
# launcher. Alternate provider selectors, credentials, and model overrides
# must never route or authenticate the first-party registry query.
direct_registry_log="$tmp/direct-agents.log"
printf '%s\n' '[{"id":"direct-managed-session","state":"working"}]' > "$registry"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY=current-process-identity \
  CLAUDEX_AUTH_WATCH_SECONDS=1 HOME="$home" PATH="$bin:$PATH" CODEX_HOME="$codex_home" \
  CLAUDEX_CONFIG_DIR="$config" FAKE_AGENT_REGISTRY_FILE="$registry" \
  FAKE_AGENT_REGISTRY_LOG="$direct_registry_log" CLAUDE_CODE_USE_BEDROCK=1 \
  ANTHROPIC_BASE_URL=https://private.invalid ANTHROPIC_AUTH_TOKEN=private-auth \
  CLAUDEX_PROXY_TOKEN=private-proxy ANTHROPIC_BEDROCK_MANTLE_BASE_URL=https://mantle.invalid \
  ANTHROPIC_VERTEX_PROJECT_ID=private-vertex ANTHROPIC_FOUNDRY_RESOURCE=private-foundry \
  ANTHROPIC_FOUNDRY_API_KEY=private-foundry-key ANTHROPIC_MODEL=private-model \
  "$config/codex-session" watch "$$" stale-parent-identity 1 & direct_watcher=$!
printf '%s\n' "$direct_watcher" > "$tmp/direct.pid"
for _ in {1..100}; do [[ -s "$direct_registry_log" ]] && break; sleep 0.05; done
[[ -s "$direct_registry_log" ]]
if grep -v '^BASE= AUTH= PROXY= BEDROCK= MANTLE= VERTEX= FOUNDRY_RESOURCE= FOUNDRY_KEY= MODEL=$' "$direct_registry_log" > "$tmp/direct-secret-leaks"; then
  printf '%s\n' 'direct watcher registry query inherited private routing' >&2
  exit 1
fi
printf '%s\n' '[]' > "$registry"
wait "$direct_watcher"
rm -f "$tmp/direct.pid"

# A live PID with the wrong start identity is not the launcher's process. The
# foreground watcher must exit instead of following a reused PID indefinitely.
printf '%s\n' '[]' > "$registry"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY=current-process-identity \
  CLAUDEX_AUTH_WATCH_SECONDS=1 CLAUDEX_TEST_AUTH_WATCH_READY_FILE="$tmp/reuse.ready" \
  CLAUDEX_TEST_AUTH_WATCH_EXIT_FILE="$tmp/reuse.exit" HOME="$home" PATH="$bin:$PATH" \
  CODEX_HOME="$codex_home" CLAUDEX_CONFIG_DIR="$config" \
  "$config/codex-session" watch "$$" stale-parent-identity 0 & reuse_watcher=$!
for _ in {1..80}; do [[ -e "$tmp/reuse.exit" ]] && break; sleep 0.05; done
wait "$reuse_watcher"
[[ -e "$tmp/reuse.exit" ]]

printf '%s\n' 'background watcher regressions passed'
