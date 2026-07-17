#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'failure_code=$?; printf "test.zsh: command failed at line %s (exit %s)\n" "$LINENO" "$failure_code" >&2; exit "$failure_code"' ERR

mkdir -p "$tmp/home/.config/claudex" "$tmp/home/.cli-proxy-api" "$tmp/home/.codex" "$tmp/bin"
: > "$tmp/home/.config/claudex/cliproxyapi.yaml"
printf '%s\n' \
  'CLAUDEX_PROXY_TOKEN=test-token' \
  "CLAUDEX_CODEX_AUTH_DIR=$tmp/home/.cli-proxy-api" \
  "CLAUDEX_PROXY_CONFIG=$tmp/home/.config/claudex/cliproxyapi.yaml" \
  > "$tmp/home/.config/claudex/env"
cp "$root/settings.json" "$tmp/home/.config/claudex/settings.json"
cp "$root/usage-limit" "$tmp/home/.config/claudex/usage-limit"
cp "$root/codex-session" "$tmp/home/.config/claudex/codex-session"
cp "$root/preload.cjs" "$tmp/home/.config/claudex/preload.cjs"
cp "$root/skill-bridge.cjs" "$tmp/home/.config/claudex/skill-bridge.cjs"
mkdir -p "$tmp/home/.claude/skills/existing-claude" "$tmp/home/.agents/skills/existing-codex"
printf '%s\n' '---' 'name: existing-claude' 'description: Existing Claude test skill' '---' '' 'Claude instructions.' > "$tmp/home/.claude/skills/existing-claude/SKILL.md"
printf '%s\n' '---' 'name: existing-codex' 'description: Existing Codex test skill' '---' '' 'Codex instructions.' > "$tmp/home/.agents/skills/existing-codex/SKILL.md"
chmod +x "$tmp/home/.config/claudex/codex-session"

# Values sourced from Claudex's Unix env file must reach the Node skill bridge.
skill_env_home="$tmp/skill-env-home"
skill_env_claude="$tmp/custom-claude-home"
mkdir -p "$skill_env_home/.config/claudex" "$skill_env_home/.agents/skills/env-codex" "$skill_env_claude/skills/env-claude"
cp "$root/skill-bridge.cjs" "$skill_env_home/.config/claudex/skill-bridge.cjs"
printf '%s\n' \
  'CLAUDEX_SKILL_BRIDGE=on' \
  'CLAUDEX_SKILL_PLUGINS=off' \
  'CLAUDEX_SKILL_DOLLAR_REFERENCES=off' \
  "CLAUDEX_CLAUDE_CONFIG_DIR=$skill_env_claude" \
  "CLAUDEX_CODEX_ADMIN_SKILLS_DIR=$tmp/missing-admin-skills" \
  > "$skill_env_home/.config/claudex/env"
printf '%s\n' '---' 'name: env-claude' 'description: Env Claude skill' '---' '' 'Claude.' > "$skill_env_claude/skills/env-claude/SKILL.md"
printf '%s\n' '---' 'name: env-codex' 'description: Env Codex skill' '---' '' 'Codex.' > "$skill_env_home/.agents/skills/env-codex/SKILL.md"
skill_env_output=$(HOME="$skill_env_home" PATH="$tmp/bin:$PATH" "$root/claudex" skills)
[[ "$skill_env_output" == *$'/env-claude\t'* ]]
[[ "$skill_env_output" == *$'/env-codex\t'* ]]
[[ "$skill_env_output" == *'0 isolated compatibility plugins'* ]]
cat > "$tmp/home/.codex/auth.json" <<'EOF'
{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T01:00:00Z","tokens":{"access_token":"codex-source-access","refresh_token":"codex-source-refresh","id_token":"codex-source-id","account_id":"account-test"}}
EOF
cat > "$tmp/home/.cli-proxy-api/codex-test.json" <<'EOF'
{"type":"codex","access_token":"secret-access-token","refresh_token":"secret-refresh-token","account_id":"account-test","email":"private@example.com"}
EOF

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
arguments=("$@")
for (( index = 0; index < ${#arguments[@]}; index++ )); do
  argument="${arguments[$index]}"
  if [[ "$argument" == *'test-token'* || "$argument" == *'secret-access-token'* ]]; then
    printf '%s\n' 'credential leaked into curl arguments' >&2
    exit 90
  fi
  if [[ "$argument" == '--header' && "${arguments[$((index + 1))]:-}" == /dev/fd/* ]]; then
    printf '%s\n' 'curl header file path is missing the required @ prefix' >&2
    exit 91
  fi
  if [[ "$argument" == *'/wham/usage'* ]]; then
    [[ "${FAKE_USAGE_FAIL:-0}" != 1 ]] || exit 22
    if [[ "${FAKE_USAGE_CHANGED:-0}" == 1 ]]; then printf '%s\n' '{"new_usage_schema":true}'; exit; fi
    printf '%s\n' '{"user_id":"private-user","account_id":"private-account","email":"private@example.com","plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":565127,"reset_at":1784666240},"secondary_window":null},"code_review_rate_limit":null,"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":1784705933},"secondary_window":null}}],"credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"rate_limit_reset_credits":{"available_count":1}}'
    exit
  fi
done
if [[ -n "${FAKE_PROXY_READY_FILE:-}" && ! -e "$FAKE_PROXY_READY_FILE" ]]; then exit 7; fi
if [[ -n "${FAKE_ONLY_MODEL:-}" ]]; then
  printf '{"data":[{"id":"%s"}]}\n' "$FAKE_ONLY_MODEL"
  exit
fi
printf '%s\n' '{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}'
EOF
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' '2.1.210 (test)'
  exit
fi
if [[ "${1:-}" == "--help" ]]; then
  if [[ "${FAKE_CLAUDE_HELP_NO_MODEL:-0}" == 1 ]]; then
    printf '%s\n' '--effort --settings'
  elif [[ "${FAKE_CLAUDE_HELP_PROSE_ONLY:-0}" == 1 ]]; then
    printf '%s\n' '  --model <model>  Model for this session'
    printf '%s\n' '  --bare           Minimal mode; explicit context may use --agents, --append-system-prompt, --permission-mode, --add-dir, or --plugin-dir'
  else
    printf '%s\n' '--model --agents --append-system-prompt --permission-mode --settings --effort --add-dir --plugin-dir'
  fi
  exit
fi
if [[ "${1:-}" == "auto-mode" && "${2:-}" == "defaults" ]]; then
  [[ "${FAKE_AUTO_MODE_DEFAULTS_FAIL:-0}" != 1 ]] || exit 1
  if [[ "${FAKE_AUTO_MODE_DEFAULT_VERSION:-1}" == 2 ]]; then
    printf '%s\n' '{"allow":["Updated default allow rule"],"environment":["Updated default environment rule"],"soft_deny":["Updated soft deny"],"hard_deny":["Data Exfiltration: updated hard deny"]}'
  else
    printf '%s\n' '{"allow":["Default allow rule"],"environment":["Default environment rule"],"soft_deny":["Default soft deny"],"hard_deny":["Data Exfiltration: default hard deny"]}'
  fi
  exit
fi
if [[ "${1:-}" == "update" ]]; then
  [[ -z "${FAKE_UPDATE_LOG:-}" ]] || printf '%s\n' "$$" >> "$FAKE_UPDATE_LOG"
  [[ -z "${FAKE_UPDATE_ENV_LOG:-}" ]] || {
    printf 'PROXY_TOKEN=%s\n' "${CLAUDEX_PROXY_TOKEN:-}" >> "$FAKE_UPDATE_ENV_LOG"
    printf 'AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}" >> "$FAKE_UPDATE_ENV_LOG"
    printf 'MANAGED=%s\n' "${CLAUDEX_MANAGED_SESSION:-}" >> "$FAKE_UPDATE_ENV_LOG"
    printf 'SUBAGENT=%s\n' "${CLAUDE_CODE_SUBAGENT_MODEL:-}" >> "$FAKE_UPDATE_ENV_LOG"
  }
  [[ -z "${FAKE_UPDATE_READY_FILE:-}" ]] || : > "$FAKE_UPDATE_READY_FILE"
  if [[ -n "${FAKE_UPDATE_WAIT_FILE:-}" ]]; then
    while [[ ! -e "$FAKE_UPDATE_WAIT_FILE" ]]; do sleep 0.02; done
  fi
  [[ -z "${FAKE_UPDATE_DELAY:-}" ]] || sleep "$FAKE_UPDATE_DELAY"
  [[ -z "${FAKE_UPDATE_DONE_FILE:-}" ]] || : > "$FAKE_UPDATE_DONE_FILE"
  exit "${FAKE_UPDATE_EXIT:-0}"
fi
if [[ -n "${FAKE_CLAUDE_SIGNAL_READY_FILE:-}" ]]; then
  signal_sleeper=""
  finish_signal_test() {
    printf '%s\n' "$1" > "$FAKE_CLAUDE_SIGNAL_RECEIVED_FILE"
    [[ -z "$signal_sleeper" ]] || kill "$signal_sleeper" 2>/dev/null || true
    [[ -z "$signal_sleeper" ]] || wait "$signal_sleeper" 2>/dev/null || true
    exit 0
  }
  trap 'finish_signal_test TERM' TERM
  trap 'finish_signal_test INT' INT
  trap 'finish_signal_test HUP' HUP
  printf '%s\n' "$$" > "$FAKE_CLAUDE_SIGNAL_PID_FILE"
  : > "$FAKE_CLAUDE_SIGNAL_READY_FILE"
  sleep 300 &
  signal_sleeper=$!
  wait "$signal_sleeper"
  exit $?
fi
if [[ "${FAKE_CLAUDE_RESUME:-0}" == 1 ]]; then
  project_key=$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')
  project_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$project_key"
  mkdir -p "$project_dir"
  printf '{"sessionId":"123e4567-e89b-12d3-a456-426614174000","cwd":"%s","isSidechain":false}\n' "$PWD" > "$project_dir/123e4567-e89b-12d3-a456-426614174000.jsonl"
  if [[ "${FAKE_FOREIGN_RESUME:-0}" == 1 ]]; then
    sleep 0.1
    printf '%s\n' '{"sessionId":"223e4567-e89b-12d3-a456-426614174000","cwd":"/foreign/project","isSidechain":false}' > "$project_dir/223e4567-e89b-12d3-a456-426614174000.jsonl"
  fi
  if [[ "${FAKE_SAME_CWD_RESUME:-0}" == 1 ]]; then
    sleep 0.1
    printf '{"sessionId":"323e4567-e89b-12d3-a456-426614174000","cwd":"%s","isSidechain":false}\n' "$PWD" > "$project_dir/323e4567-e89b-12d3-a456-426614174000.jsonl"
  fi
  printf '%s\n' 'Resume this session with:'
  printf '%s\n' 'claude --resume 123e4567-e89b-12d3-a456-426614174000'
  exit "${FAKE_CLAUDE_RESUME_EXIT:-0}"
fi
[[ -z "${FAKE_CLAUDE_DELAY:-}" ]] || sleep "$FAKE_CLAUDE_DELAY"
if [[ "${FAKE_PROXY_RECOVERY:-0}" == 1 ]]; then
  rm -f "$FAKE_PROXY_READY_FILE"
  for attempt in {1..100}; do
    [[ -e "$FAKE_PROXY_READY_FILE" ]] && break
    sleep 0.1
  done
  if [[ -e "$FAKE_PROXY_READY_FILE" ]]; then printf '%s\n' 'PROXY_RECOVERED=1'
  else printf '%s\n' 'PROXY_RECOVERED=0'
  fi
fi
if [[ "${FAKE_PROXY_TRANSIENT_ONCE:-0}" == 1 ]]; then
  rm -f "$FAKE_PROXY_READY_FILE"
  sleep 1.2
  : > "$FAKE_PROXY_READY_FILE"
  sleep 1.2
fi
printf '%s\n' "AUTO=${CLAUDE_CODE_AUTO_MODE_MODEL}"
printf '%s\n' "BG=${CLAUDE_CODE_BG_CLASSIFIER_MODEL}"
printf '%s\n' "SUBAGENT=${CLAUDE_CODE_SUBAGENT_MODEL}"
printf '%s\n' "ADDITIONAL_CLAUDE_MD=${CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD:-}"
printf '%s\n' "NO_SESSION_PERSISTENCE=${CLAUDEX_NO_SESSION_PERSISTENCE:-}"
printf '%s\n' "CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY}"
printf '%s\n' "RETRIES=${CLAUDE_CODE_MAX_RETRIES}"
printf '%s\n' "CONTEXT=${CLAUDE_CODE_MAX_CONTEXT_TOKENS}"
printf '%s\n' "COMPACT=${CLAUDE_CODE_AUTO_COMPACT_WINDOW}"
printf '%s\n' "NO_FLICKER=${CLAUDE_CODE_NO_FLICKER}"
printf '%s\n' "ACCESSIBILITY=${CLAUDE_CODE_ACCESSIBILITY}"
printf '%s\n' "DISABLE_1M=${CLAUDE_CODE_DISABLE_1M_CONTEXT:-}"
printf '%s\n' "OPUS=${ANTHROPIC_DEFAULT_OPUS_MODEL}"
printf '%s\n' "OPUS_NAME=${ANTHROPIC_DEFAULT_OPUS_MODEL_NAME}"
printf '%s\n' "FABLE=${ANTHROPIC_DEFAULT_FABLE_MODEL}"
printf '%s\n' "FABLE_NAME=${ANTHROPIC_DEFAULT_FABLE_MODEL_NAME}"
printf '%s\n' "MODE=${CLAUDEX_SESSION_MODE:-}"
printf '%s\n' "MODEL_MODE=${CLAUDEX_MODEL_MODE:-}"
printf '%s\n' "BASE=${ANTHROPIC_BASE_URL:-}"
printf '%s\n' "USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK:-}"
printf '%s\n' "USE_VERTEX=${CLAUDE_CODE_USE_VERTEX:-}"
printf '%s\n' "USE_FOUNDRY=${CLAUDE_CODE_USE_FOUNDRY:-}"
printf '%s\n' "BEDROCK_BASE=${ANTHROPIC_BEDROCK_BASE_URL:-}"
printf '%s\n' "VERTEX_BASE=${ANTHROPIC_VERTEX_BASE_URL:-}"
printf '%s\n' "FOUNDRY_BASE=${ANTHROPIC_FOUNDRY_BASE_URL:-}"
printf '%s\n' "API_KEY=${ANTHROPIC_API_KEY:-}"
printf '%s\n' "OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
printf '%s\n' "CUSTOM_HEADERS=${ANTHROPIC_CUSTOM_HEADERS:-}"
printf '%s\n' "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-}"
printf '%s\n' "CUSTOM_MODEL=${ANTHROPIC_CUSTOM_MODEL_OPTION:-}"
printf '%s\n' "OPUS_DESCRIPTION=${ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION:-}"
printf '%s\n' "OPUS_CAPABILITIES=${ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES:-}"
printf '%s\n' "CODEX_AUTH_FILE=${CLAUDEX_CODEX_AUTH_FILE:-}"
printf '%s\n' "CODEX_SOURCE_AUTH_FILE=${CLAUDEX_CODEX_SOURCE_AUTH_FILE:-}"
printf '%s\n' "CONFIG=${CLAUDE_CONFIG_DIR:-}"
printf '%s\n' "BUN=${BUN_OPTIONS:-}"
printf '%s\n' "INTERACTIVE=${CLAUDEX_INTERACTIVE_TUI:-}"
printf '%s\n' "CHATGPT_PLAN=${CLAUDEX_CHATGPT_PLAN_LABEL:-}"
printf '%s\n' "INSTRUCTION_BRIDGE=${CLAUDEX_INSTRUCTION_BRIDGE:-}"
printf '%s\n' "PROXY_TOKEN_SET=${CLAUDEX_PROXY_TOKEN:+yes}"
printf '%s\n' "MANAGED=${CLAUDEX_MANAGED_SESSION:-}"
if [[ "${ANTHROPIC_AUTH_TOKEN:-}" == native-provider-token ]]; then printf '%s\n' 'PROVIDER_TOKEN_OK=yes'
else printf '%s\n' 'PROVIDER_TOKEN_OK=no'
fi
printf '%s\n' "ARGC=$#"
printf '%s\n' "ARGS=$*"
exit "${FAKE_CLAUDE_EXIT:-0}"
EOF
cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_CODEX_LOGGED_OUT:-0}" == 1 ]]; then exit 1; fi
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == logout ]]; then exit "${FAKE_CODEX_LOGOUT_EXIT:-0}"; fi
if [[ "${1:-}" == -c && "${2:-}" == 'cli_auth_credentials_store="file"' ]]; then
  if [[ "${3:-}" == login && "${4:-}" == status ]]; then exit 0; fi
  if [[ "${3:-}" == logout ]]; then exit "${FAKE_CODEX_LOGOUT_EXIT:-0}"; fi
  if [[ "${3:-}" == login ]]; then
    [[ -z "${FAKE_CODEX_LOGIN_LOG:-}" ]] || printf '%s\n' login >> "$FAKE_CODEX_LOGIN_LOG"
    exit 0
  fi
fi
if [[ "${1:-}" == native-test ]]; then
  printf '%s\n' "NATIVE_CODEX_ARGS=$*"
  printf '%s\n' "NATIVE_CODEX_ARGC=$#"
  printf '%s\n' "NATIVE_CODEX_ARG2=${2:-}"
  printf '%s\n' "NATIVE_CODEX_CONFIG=${CLAUDE_CONFIG_DIR:-}"
  printf '%s\n' "NATIVE_CODEX_HOME=${CODEX_HOME:-}"
  printf '%s\n' "NATIVE_CODEX_PROXY_TOKEN_SET=${CLAUDEX_PROXY_TOKEN:+yes}"
  exit 0
fi
[[ "${1:-}" == app-server ]] || exit 2
while IFS= read -r line; do
  case "$line" in
    *'"id":1'*) printf '%s\n' '{"id":1,"result":{"userAgent":"test","codexHome":"/tmp","platformFamily":"unix","platformOs":"linux"}}' ;;
    *'"id":2'*) printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":84,"windowDurationMins":10080,"resetsAt":1784666240},"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"individualLimit":null,"planType":"pro","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":84,"windowDurationMins":10080,"resetsAt":1784666240},"secondary":null,"credits":null,"individualLimit":null,"planType":"pro","rateLimitReachedType":null}},"rateLimitResetCredits":{"availableCount":1,"credits":null}}}' ;;
  esac
done
EOF
cat > "$tmp/bin/cliproxyapi" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-version" ]]; then
  printf '%s\n' 'CLIProxyAPI test'
  printf '%s\n' 'extra version detail'
  exit 1
fi
if [[ -n "${FAKE_PROXY_READY_FILE:-}" ]]; then
  [[ "${FAKE_PROXY_NEVER_READY:-0}" == 1 ]] || : > "$FAKE_PROXY_READY_FILE"
  [[ -z "${FAKE_PROXY_START_LOG:-}" ]] || printf '%s\n' "$$" >> "$FAKE_PROXY_START_LOG"
  [[ -z "${FAKE_PROXY_ENV_LOG:-}" ]] || {
    printf 'BASE_URL=%s\n' "${ANTHROPIC_BASE_URL:-}"
    printf 'AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}"
    printf 'API_KEY=%s\n' "${ANTHROPIC_API_KEY:-}"
    printf 'PROXY_TOKEN=%s\n' "${CLAUDEX_PROXY_TOKEN:-}"
    printf 'CLAUDE_CONFIG=%s\n' "${CLAUDE_CONFIG_DIR:-}"
    printf 'AUTO_MODEL=%s\n' "${CLAUDE_CODE_AUTO_MODE_MODEL:-}"
    printf 'BG_MODEL=%s\n' "${CLAUDE_CODE_BG_CLASSIFIER_MODEL:-}"
    printf 'SUBAGENT_MODEL=%s\n' "${CLAUDE_CODE_SUBAGENT_MODEL:-}"
    printf 'BUN_OPTIONS=%s\n' "${BUN_OPTIONS:-}"
  } >> "$FAKE_PROXY_ENV_LOG"
  trap 'exit 0' TERM INT
  while :; do sleep 1; done
fi
printf '%s\n' 'CLIProxyAPI test'
printf '%s\n' 'extra version detail'
exit 1
EOF
# Never let the isolated fake-home suite execute the developer machine's real
# Homebrew. Proxy recovery probes brew before falling back to PATH, and a cold
# Homebrew startup can consume the fake Claude process's entire recovery window.
cat > "$tmp/bin/brew" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --prefix ]]; then printf '%s\n' '/nonexistent/homebrew'; exit 0; fi
exit 1
EOF
# The sandbox used by this regression suite can deny the real ps command.
# Keep the process-identity fixture isolated to the test PATH so production
# launchers always derive identity from the operating system.
cat > "$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
[[ "${CLAUDEX_TEST_PS_FAIL:-0}" != 1 ]] || exit 1
printf '%s\n' "${CLAUDEX_TEST_PROCESS_IDENTITY:-test-process-identity}"
EOF
chmod +x "$tmp/bin/"*

run_wrapper() {
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
    CLAUDEX_SKIP_PROXY_WATCHER=1 \
    "$root/claudex" "$@"
}

cat > "$tmp/launcher-signal-driver.cjs" <<'EOF'
const fs = require('node:fs');
const os = require('node:os');
const { spawn } = require('node:child_process');

const child = spawn(process.argv[2], process.argv.slice(3), {
  env: process.env,
  stdio: 'ignore',
});
fs.writeFileSync(process.env.CLAUDEX_TEST_WRAPPER_PID_FILE, `${child.pid}\n`);
child.once('error', (error) => {
  console.error(error);
  process.exit(1);
});
child.once('exit', (code, signal) => {
  process.exit(code ?? 128 + (os.constants.signals[signal] || 2));
});
EOF

# Native harness routes must bypass every compatibility-layer dependency while
# preserving argv. A managed parent is scrubbed; an ordinary native Claude
# route retains caller-owned provider settings.
native_codex_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_NODE_BIN=/missing/node \
  CLAUDEX_PROXY_TOKEN=must-not-leak CODEX_HOME=/native/codex/home \
  CLAUDE_CONFIG_DIR=/native/codex/profile "$root/claudex" codex native-test 'arg with spaces')
[[ "$native_codex_output" == *'NATIVE_CODEX_ARGS=native-test arg with spaces'* ]]
[[ "$native_codex_output" == *'NATIVE_CODEX_ARGC=2'* ]]
[[ "$native_codex_output" == *'NATIVE_CODEX_ARG2=arg with spaces'* ]]
[[ "$native_codex_output" == *'NATIVE_CODEX_HOME=/native/codex/home'* ]]
[[ "$native_codex_output" == *'NATIVE_CODEX_PROXY_TOKEN_SET='* ]]
[[ "$native_codex_output" != *'NATIVE_CODEX_PROXY_TOKEN_SET=yes'* ]]

native_claude_profile="$tmp/native-claude-profile"
managed_preload="--preload $tmp/home/.config/claudex/preload.cjs"
native_claude_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_NODE_BIN=/missing/node \
  CLAUDEX_CLAUDE_CONFIG_DIR="$native_claude_profile" CLAUDE_CONFIG_DIR=/managed/profile \
  ANTHROPIC_BASE_URL=https://managed.invalid ANTHROPIC_AUTH_TOKEN=managed-secret \
  ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5.6-sol CLAUDE_CODE_AUTO_MODE_MODEL=gpt-5.6-terra \
  CLAUDEX_INTERACTIVE_TUI=1 CLAUDEX_MANAGED_SESSION=1 BUN_OPTIONS="$managed_preload --preload /user/preload.cjs" \
  "$root/claudex" claude native-test 'arg with spaces')
[[ "$native_claude_output" == *'ARGC=2'* && "$native_claude_output" == *'ARGS=native-test arg with spaces'* ]]
[[ "$native_claude_output" == *$'BASE=\n'* ]]
[[ "$native_claude_output" == *"CONFIG=$native_claude_profile"* ]]
[[ "$native_claude_output" == *'BUN=--preload /user/preload.cjs'* ]]
[[ "$native_claude_output" == *$'OPUS=\n'* && "$native_claude_output" == *$'AUTO=\n'* ]]
[[ "$native_claude_output" == *$'INTERACTIVE=\n'* ]]
[[ "$native_claude_output" == *$'PROXY_TOKEN_SET=\n'* ]]

native_user_claude_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_NODE_BIN=/missing/node \
  CLAUDE_CONFIG_DIR=/user/claude-profile ANTHROPIC_BASE_URL=https://custom-provider.invalid \
  ANTHROPIC_AUTH_TOKEN=native-provider-token CLAUDEX_PROXY_TOKEN=must-not-leak \
  ANTHROPIC_API_KEY=native-api-key CLAUDE_CODE_OAUTH_TOKEN=native-oauth-token \
  ANTHROPIC_CUSTOM_HEADERS='X-Native: preserved' ANTHROPIC_MODEL=claude-native \
  ANTHROPIC_CUSTOM_MODEL_OPTION=claude-native-custom \
  CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1 \
  ANTHROPIC_BEDROCK_BASE_URL=https://bedrock.invalid ANTHROPIC_VERTEX_BASE_URL=https://vertex.invalid \
  ANTHROPIC_FOUNDRY_BASE_URL=https://foundry.invalid \
  ANTHROPIC_DEFAULT_OPUS_MODEL=claude-custom CLAUDE_CODE_AUTO_MODE_MODEL=custom-auto \
  CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 BUN_OPTIONS='--preload /user/native-preload.cjs' \
  "$root/claudex" claude native-user-settings)
[[ "$native_user_claude_output" == *'CONFIG=/user/claude-profile'* ]]
[[ "$native_user_claude_output" == *'OPUS=claude-custom'* && "$native_user_claude_output" == *'AUTO=custom-auto'* ]]
[[ "$native_user_claude_output" == *'ADDITIONAL_CLAUDE_MD=1'* ]]
[[ "$native_user_claude_output" == *'BUN=--preload /user/native-preload.cjs'* ]]
[[ "$native_user_claude_output" == *'BASE=https://custom-provider.invalid'* ]]
[[ "$native_user_claude_output" == *'PROVIDER_TOKEN_OK=yes'* ]]
[[ "$native_user_claude_output" == *'API_KEY=native-api-key'* && "$native_user_claude_output" == *'OAUTH_TOKEN=native-oauth-token'* ]]
[[ "$native_user_claude_output" == *'CUSTOM_HEADERS=X-Native: preserved'* && "$native_user_claude_output" == *'ANTHROPIC_MODEL=claude-native'* ]]
[[ "$native_user_claude_output" == *'CUSTOM_MODEL=claude-native-custom'* ]]
[[ "$native_user_claude_output" == *'USE_BEDROCK=1'* && "$native_user_claude_output" == *'USE_VERTEX=1'* ]]
[[ "$native_user_claude_output" == *'USE_FOUNDRY=1'* && "$native_user_claude_output" == *'BEDROCK_BASE=https://bedrock.invalid'* ]]
[[ "$native_user_claude_output" == *'VERTEX_BASE=https://vertex.invalid'* && "$native_user_claude_output" == *'FOUNDRY_BASE=https://foundry.invalid'* ]]
[[ "$native_user_claude_output" == *$'PROXY_TOKEN_SET=\n'* ]]

native_broken_env_home="$tmp/native-broken-env-home"
mkdir -p "$native_broken_env_home/.config/claudex"
printf '%s\n' 'return 77' > "$native_broken_env_home/.config/claudex/env"
native_broken_env=$(HOME="$native_broken_env_home" PATH="$tmp/bin:$PATH" \
  "$root/claudex" claude native-broken-env)
[[ "$native_broken_env" == *'ARGS=native-broken-env'* ]]
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" FAKE_CLAUDE_EXIT=37 \
    "$root/claudex" claude native-exit >/dev/null 2>&1; then
  native_exit_status=0
else
  native_exit_status=$?
fi
[[ "$native_exit_status" == 37 ]]

hosted_remote_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
  CLAUDE_CONFIG_DIR=/user/claude-profile ANTHROPIC_BASE_URL=https://custom-provider.invalid \
  ANTHROPIC_AUTH_TOKEN=native-provider-token CLAUDEX_PROXY_TOKEN=must-not-leak \
  ANTHROPIC_API_KEY=hosted-api-key CLAUDE_CODE_OAUTH_TOKEN=hosted-oauth-token \
  ANTHROPIC_CUSTOM_HEADERS='X-Hosted: remove' ANTHROPIC_MODEL=gpt-hosted \
  ANTHROPIC_CUSTOM_MODEL_OPTION=gpt-hosted-custom \
  ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION=managed-description \
  ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES=managed-capabilities \
  CLAUDE_CODE_AUTO_MODE_MODEL=gpt-hosted-auto CLAUDE_CODE_MAX_CONTEXT_TOKENS=400000 \
  CLAUDEX_PROXY_URL=http://127.0.0.1:9999 CLAUDEX_CHATGPT_PLAN_LABEL=ChatGPT-Proxied \
  "$root/claudex" --remote-control=pairing-name)
[[ "$hosted_remote_output" == *'ARGS=--remote-control=pairing-name'* ]]
[[ "$hosted_remote_output" == *'CONFIG=/user/claude-profile'* ]]
[[ "$hosted_remote_output" == *$'BASE=\n'* && "$hosted_remote_output" == *'PROVIDER_TOKEN_OK=no'* ]]
[[ "$hosted_remote_output" == *$'PROXY_TOKEN_SET=\n'* ]]
[[ "$hosted_remote_output" == *$'API_KEY=\n'* && "$hosted_remote_output" == *$'OAUTH_TOKEN=\n'* ]]
[[ "$hosted_remote_output" == *$'CUSTOM_HEADERS=\n'* && "$hosted_remote_output" == *$'ANTHROPIC_MODEL=\n'* ]]
[[ "$hosted_remote_output" == *$'CUSTOM_MODEL=\n'* && "$hosted_remote_output" == *$'OPUS_DESCRIPTION=\n'* ]]
[[ "$hosted_remote_output" == *$'OPUS_CAPABILITIES=\n'* && "$hosted_remote_output" == *$'AUTO=\n'* ]]
[[ "$hosted_remote_output" == *$'CONTEXT=\n'* && "$hosted_remote_output" == *$'CHATGPT_PLAN=\n'* ]]
hosted_rc_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$root/claudex" --rc pair-name)
[[ "$hosted_rc_output" == *'ARGC=2'* && "$hosted_rc_output" == *'ARGS=--rc pair-name'* ]]
hosted_review_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$root/claudex" ultrareview --help)
[[ "$hosted_review_output" == *'ARGS=ultrareview --help'* ]]
positional_remote_output=$(HOME="$native_broken_env_home" PATH="$tmp/bin:$PATH" \
  ANTHROPIC_API_KEY=positional-api-key "$root/claudex" remote-control)
[[ "$positional_remote_output" == *'ARGS=remote-control'* && "$positional_remote_output" == *$'API_KEY=\n'* ]]
debug_hosted_output=$(HOME="$native_broken_env_home" PATH="$tmp/bin:$PATH" \
  "$root/claudex" -d hosted --remote-control=debug-session)
[[ "$debug_hosted_output" == *'ARGS=-d hosted --remote-control=debug-session'* && "$debug_hosted_output" == *$'BASE=\n'* ]]
missing_maintenance_home="$tmp/missing-maintenance-home"
mkdir -p "$missing_maintenance_home"
debug_maintenance_output=$(HOME="$missing_maintenance_home" PATH="$tmp/bin:$PATH" \
  "$root/claudex" --debug=api mcp --help)
[[ "$debug_maintenance_output" == *'ARGS=--debug=api mcp --help'* && "$debug_maintenance_output" == *$'BASE=\n'* ]]
trailing_version_output=$(HOME="$missing_maintenance_home" PATH="$tmp/bin:$PATH" \
  "$root/claudex" literal-prompt --version)
[[ "$trailing_version_output" == *'ARGS=literal-prompt --version'* && "$trailing_version_output" == *$'BASE=\n'* ]]
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" FAKE_CLAUDE_EXIT=41 \
    "$root/claudex" --remote-control >/dev/null 2>&1; then
  hosted_exit_status=0
else
  hosted_exit_status=$?
fi
[[ "$hosted_exit_status" == 41 ]]

auth_recovery_helper="$tmp/auth-recovery-helper"
cat > "$auth_recovery_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:-missing}" >> "$CLAUDEX_TEST_AUTH_RECOVERY_LOG"
case "${1:-}" in
  sync)
    if [[ ! -e "$CLAUDEX_TEST_AUTH_RECOVERY_MARKER" ]]; then
      : > "$CLAUDEX_TEST_AUTH_RECOVERY_MARKER"
      exit 11
    fi
    ;;
  login|watch|status) ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$auth_recovery_helper"

bash -n "$root/claudex"
bash -n "$root/statusline"
bash -n "$root/usage-limit"
bash -n "$root/install.sh"
bash -n "$root/bootstrap.sh"
sh -n "$root/install.zsh"
node --check "$root/preload.cjs"
node --check "$root/skill-bridge.cjs"
node --check "$root/bin/claudex-package.mjs"
node "$root/tests/skill-bridge.test.cjs"
node "$root/tests/skill-contract.test.cjs"
node "$root/tests/skill-security.test.cjs"

skills_output=$(run_wrapper skills)
[[ "$skills_output" == *'/existing-claude'* ]]
[[ "$skills_output" == *'/existing-codex'* ]]
old_node_bin="$tmp/old-node-bin"
mkdir -p "$old_node_bin"
cat > "$old_node_bin/node" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$old_node_bin/node"
if PATH="$old_node_bin:$PATH" run_wrapper skills >"$tmp/old-node.stdout" 2>"$tmp/old-node.stderr"; then
  printf '%s\n' 'expected a pre-18 Node runtime to be rejected' >&2
  exit 1
fi
grep -F 'Node.js 18 or newer is required for skill compatibility' "$tmp/old-node.stderr" >/dev/null

configured_node_bin="$tmp/configured-node-bin"
mkdir -p "$configured_node_bin"
ln -s "$(command -v node)" "$configured_node_bin/node"
CLAUDEX_NODE_BIN="$configured_node_bin" PATH="$old_node_bin:$PATH" run_wrapper skills \
  >"$tmp/configured-node.stdout" 2>"$tmp/configured-node.stderr"
[[ "$(<"$tmp/configured-node.stderr")" == *'claudex skills:'* || ! -s "$tmp/configured-node.stderr" ]]
if CLAUDEX_NODE_BIN=relative/node run_wrapper skills >"$tmp/relative-node.stdout" 2>"$tmp/relative-node.stderr"; then
  printf '%s\n' 'expected a relative CLAUDEX_NODE_BIN to be rejected' >&2
  exit 1
fi
grep -F 'CLAUDEX_NODE_BIN must be an absolute directory' "$tmp/relative-node.stderr" >/dev/null

deleted_cwd=$(mktemp -d "$tmp/deleted-cwd.XXXXXX")
deleted_cwd_output=$(
  cd "$deleted_cwd"
  rmdir "$deleted_cwd"
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
    "$root/claudex" --version 2>&1
)
[[ "$deleted_cwd_output" == *'the previous working directory no longer exists'* ]]
[[ "$deleted_cwd_output" == *'2.1.210 (test)'* ]]

auth_recovery_log="$tmp/auth-recovery.log"
auth_recovery_marker="$tmp/auth-recovery.marker"
interactive_auth_output=$(
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CI=0 CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
    CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
    CLAUDEX_CODEX_SESSION_HELPER="$auth_recovery_helper" \
    CLAUDEX_TEST_AUTH_RECOVERY_LOG="$auth_recovery_log" CLAUDEX_TEST_AUTH_RECOVERY_MARKER="$auth_recovery_marker" \
    CLAUDEX_TEST_TTY_INPUT=1 CLAUDEX_TEST_TTY_OUTPUT=1 \
    "$root/claudex" --terra auth-recovery-test 2>&1
)
[[ "$interactive_auth_output" == *'Codex sign-in is required. Opening the official Codex browser login'* ]]
[[ "$interactive_auth_output" == *'AUTO=gpt-5.6-terra'* ]]
[[ "$(grep -c '^sync$' "$auth_recovery_log")" == 2 ]]
[[ "$(grep -c '^login$' "$auth_recovery_log")" == 1 ]]

rm -f "$auth_recovery_log" "$auth_recovery_marker"
if noninteractive_auth_output=$(
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
    CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
    CLAUDEX_CODEX_SESSION_HELPER="$auth_recovery_helper" \
    CLAUDEX_TEST_AUTH_RECOVERY_LOG="$auth_recovery_log" CLAUDEX_TEST_AUTH_RECOVERY_MARKER="$auth_recovery_marker" \
    "$root/claudex" --terra auth-recovery-test 2>&1
); then
  printf '%s\n' 'expected noninteractive Codex auth failure to remain prompt-free' >&2
  exit 1
fi
[[ "$noninteractive_auth_output" == *'Run `claudex --login` in an interactive terminal'* ]]
[[ "$noninteractive_auth_output" != *'Opening the official Codex browser login'* ]]
[[ "$(grep -c '^sync$' "$auth_recovery_log")" == 1 ]]
! grep -q '^login$' "$auth_recovery_log"

rm -f "$auth_recovery_log" "$auth_recovery_marker"
if ci_auth_output=$(
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
    CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 CI=1 \
    CLAUDEX_CODEX_SESSION_HELPER="$auth_recovery_helper" \
    CLAUDEX_TEST_AUTH_RECOVERY_LOG="$auth_recovery_log" CLAUDEX_TEST_AUTH_RECOVERY_MARKER="$auth_recovery_marker" \
    CLAUDEX_TEST_TTY_INPUT=1 CLAUDEX_TEST_TTY_OUTPUT=1 \
    "$root/claudex" --terra auth-recovery-test 2>&1
); then
  printf '%s\n' 'expected CI Codex auth failure to remain prompt-free' >&2
  exit 1
fi
[[ "$ci_auth_output" != *'Opening the official Codex browser login'* ]]
! grep -q '^login$' "$auth_recovery_log"
input_alias_output=$(CLAUDEX_TEST_TTY_INPUT=1 node -e '
  const preload = require(process.argv[1]);
  process.stdout.write(Buffer.from(preload.rewriteSolplanInput("/model solplan\r")).toString("hex"));
' "$root/preload.cjs")
[[ "$input_alias_output" == 2f6d6f64656c206f707573706c616e0d ]]
input_listener_output=$(printf '/model solplan\r' | CLAUDEX_TEST_TTY_INPUT=1 node --require "$root/preload.cjs" -e '
  process.stdin.once("data", (chunk) => process.stdout.write(Buffer.from(chunk).toString("hex")));
')
[[ "$input_listener_output" == 2f6d6f64656c206f707573706c616e0d ]]
jq -e '
  .model == "opus"
  and .permissions.defaultMode == "auto"
  and (.autoMode | not)
  and .autoCompactEnabled == true
  and .autoCompactWindow == 280000
  and .precomputeCompactionEnabled == true
  and .verbose == false
  and .tui == "fullscreen"
  and (.modelOverrides | not)
  and (.availableModels | index("gpt-5.6-sol") != null)
  and (.availableModels | index("gpt-5.6-terra") != null)
  and (.availableModels | index("gpt-5.6-luna") != null)
  and (.availableModels | index("opusplan") != null)
  and .statusLine.command == "__CLAUDEX_STATUSLINE_COMMAND__"
  and (.env | not)
' "$root/settings.json" >/dev/null

legacy_auto_config="$tmp/legacy-auto-config"
mkdir -p "$legacy_auto_config"
cp "$tmp/home/.config/claudex/env" "$legacy_auto_config/env"
jq '.autoMode = {
    allow: ["Explicit Action Approval: legacy managed seed"],
    environment: ["User designated task boundary: legacy managed seed"]
  }' "$root/settings.json" > "$legacy_auto_config/settings.json"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CONFIG_DIR="$legacy_auto_config" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 FAKE_AUTO_MODE_DEFAULTS_FAIL=1 \
  "$root/claudex" auto-mode config >/dev/null
jq -e '.autoMode | not' "$legacy_auto_config/settings.json" >/dev/null

custom_fallback_config="$tmp/custom-fallback-config"
mkdir -p "$custom_fallback_config"
cp "$tmp/home/.config/claudex/env" "$custom_fallback_config/env"
jq '.autoMode = {allow: ["User custom allow rule"]}' \
  "$root/settings.json" > "$custom_fallback_config/settings.json"
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CONFIG_DIR="$custom_fallback_config" \
    CLAUDEX_SKIP_AUTO_UPDATE=1 FAKE_AUTO_MODE_DEFAULTS_FAIL=1 \
    "$root/claudex" auto-mode config >/dev/null 2>&1; then
  printf '%s\n' 'expected unavailable defaults with custom auto-mode rules to fail safely' >&2
  exit 1
fi
jq -e '.autoMode.allow == ["User custom allow rule"]' \
  "$custom_fallback_config/settings.json" >/dev/null

jq '.autoMode = {
    allow: ["User custom allow rule"],
    environment: ["User custom environment rule"],
    soft_deny: ["User custom soft deny rule"],
    hard_deny: ["User custom hard deny rule"]
  }' \
  "$tmp/home/.config/claudex/settings.json" > "$tmp/custom-auto-mode-settings.json"
mv "$tmp/custom-auto-mode-settings.json" "$tmp/home/.config/claudex/settings.json"
default_output=$(run_wrapper --terra test-prompt)
state_file="$tmp/home/.config/claudex/.claude.json"
jq -e '
  any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-sol" and .label == "GPT-5.6 Sol")
  and any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-terra" and .label == "GPT-5.6 Terra")
  and any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-luna" and .label == "GPT-5.6 Luna")
  and any(.additionalModelOptionsCache[]?; .value == "opusplan" and .label == "GPT-5.6 Solplan")
' "$state_file" >/dev/null
jq '.additionalModelOptionsCache += [{"value":"gpt-5.6-sol","label":"GPT-5.6 Sol","description":"stale duplicate"}]' \
  "$state_file" > "$tmp/duplicated-model-cache.json"
mv "$tmp/duplicated-model-cache.json" "$state_file"
run_wrapper --version >/dev/null
jq -e '[.additionalModelOptionsCache[] | select(.value == "gpt-5.6-sol")] as $sol
  | ($sol | length) == 1
  and $sol[0].description == "Frontier capability for planning and the hardest engineering work"' \
  "$state_file" >/dev/null
[[ "$default_output" == *'AUTO=gpt-5.6-terra'* ]]
[[ "$default_output" == *'BG=gpt-5.6-luna'* ]]
[[ "$default_output" == *$'SUBAGENT=\n'* ]]
[[ "$default_output" == *'ADDITIONAL_CLAUDE_MD=1'* ]]
[[ "$default_output" == *'INSTRUCTION_BRIDGE=on'* ]]
[[ "$default_output" == *'CONCURRENCY=3'* ]]
[[ "$default_output" == *'RETRIES=15'* ]]
[[ "$default_output" == *'CONTEXT=400000'* ]]
[[ "$default_output" == *'COMPACT=280000'* ]]
[[ "$default_output" == *'NO_FLICKER=1'* ]]
[[ "$default_output" == *'ACCESSIBILITY=1'* ]]
[[ "$default_output" == *'DISABLE_1M=1'* ]]
[[ "$default_output" == *'OPUS=gpt-5.6-sol'* ]]
[[ "$default_output" == *'OPUS_NAME=GPT-5.6 Sol'* ]]
[[ "$default_output" == *'FABLE=gpt-5.6-sol'* ]]
[[ "$default_output" == *'FABLE_NAME=GPT-5.6 Sol'* ]]
[[ "$default_output" == *'BASE=http://127.0.0.1:8318'* ]]
[[ "$default_output" == *"BUN=--preload $tmp/home/.config/claudex/preload.cjs"* ]]
[[ "$default_output" == *$'INTERACTIVE=\n'* ]]
[[ "$default_output" == *'--permission-mode auto'* ]]
[[ "$default_output" == *'--model gpt-5.6-terra'* ]]
[[ "$default_output" == *'--add-dir '*'/skill-bridge/generations/'* ]]
[[ "$default_output" == *'--plugin-dir '*'/claudex-codex-skill-references'* ]]
[[ "$default_output" == *'Do not spawn or delegate to additional agents'* ]]
[[ "$default_output" == *'Unless you are a teammate in a native Agent Team that the user explicitly requested'* ]]
[[ "$default_output" == *'keep at most 3 delegated workers active at once'* ]]
[[ "$default_output" == *'Before every final answer, call TaskList and reconcile every entry'* ]]
[[ "$default_output" == *'Never leave stale in_progress tasks after their work is done'* ]]
[[ "$default_output" == *'operate as a Codex coding agent inside Claude Code'* ]]
[[ "$default_output" == *'Ask as few questions as possible'* ]]
[[ "$default_output" == *'Never repeat a question the user already answered'* ]]
[[ "$default_output" == *'Do not call EnterPlanMode'* ]]
[[ "$default_output" == *'"Terra (high)"'* ]]
[[ "$default_output" == *'"Luna (medium)"'* ]]
[[ "$default_output" == *'Terra (high) - Audit JSON parser bugs'* ]]
[[ "$default_output" != *'"claudex-deep"'* ]]
[[ "$default_output" != *'"claudex-builder"'* ]]
[[ "$default_output" != *'"claudex-fast"'* ]]
[[ "$default_output" == *'Sol capacity is reserved for the leader'* ]]
[[ "$default_output" == *'Create a native Agent Team only when the user explicitly requests one'* ]]
[[ "$default_output" == *'outside an explicitly requested native Agent Team'* ]]
[[ "$default_output" != *'"model":"gpt-5.6-sol"'* ]]

managed_provider_output=$(CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1 \
  ANTHROPIC_BEDROCK_BASE_URL=https://bedrock.invalid ANTHROPIC_VERTEX_BASE_URL=https://vertex.invalid \
  ANTHROPIC_FOUNDRY_BASE_URL=https://foundry.invalid ANTHROPIC_API_KEY=provider-api-key \
  CLAUDE_CODE_OAUTH_TOKEN=provider-oauth ANTHROPIC_CUSTOM_HEADERS='X-Provider: remove' \
  ANTHROPIC_MODEL=claude-provider ANTHROPIC_CUSTOM_MODEL_OPTION=claude-provider-custom \
  run_wrapper provider-boundary-test)
[[ "$managed_provider_output" == *$'USE_BEDROCK=\n'* && "$managed_provider_output" == *$'USE_VERTEX=\n'* ]]
[[ "$managed_provider_output" == *$'USE_FOUNDRY=\n'* && "$managed_provider_output" == *$'BEDROCK_BASE=\n'* ]]
[[ "$managed_provider_output" == *$'VERTEX_BASE=\n'* && "$managed_provider_output" == *$'FOUNDRY_BASE=\n'* ]]
[[ "$managed_provider_output" == *$'API_KEY=\n'* && "$managed_provider_output" == *$'OAUTH_TOKEN=\n'* ]]
[[ "$managed_provider_output" == *$'CUSTOM_HEADERS=\n'* && "$managed_provider_output" == *$'ANTHROPIC_MODEL=\n'* ]]
[[ "$managed_provider_output" == *$'CUSTOM_MODEL=\n'* ]]

explicit_subagent_output=$(CLAUDE_CODE_SUBAGENT_MODEL=user-selected-subagent run_wrapper subagent-model-test)
[[ "$explicit_subagent_output" == *'SUBAGENT=user-selected-subagent'* ]]
instruction_bridge_off=$(CLAUDEX_INSTRUCTION_BRIDGE=off run_wrapper instruction-bridge-off)
[[ "$instruction_bridge_off" == *'INSTRUCTION_BRIDGE=off'* ]]
if CLAUDEX_INSTRUCTION_BRIDGE=invalid run_wrapper instruction-bridge-invalid >/dev/null 2>&1; then
  printf '%s\n' 'expected an invalid instruction bridge mode to fail' >&2
  exit 1
fi

if CLAUDEX_PROXY_URL=https://proxy.example.test run_wrapper remote-proxy-test \
    >"$tmp/remote-without-optin.stdout" 2>"$tmp/remote-without-optin.stderr"; then
  printf '%s\n' 'expected a non-loopback proxy to require explicit opt-in' >&2
  exit 1
fi
grep -F 'refusing to send the proxy credential to a non-loopback URL' "$tmp/remote-without-optin.stderr" >/dev/null
remote_proxy_output=$(CLAUDEX_PROXY_URL=https://proxy.example.test CLAUDEX_ALLOW_REMOTE_PROXY=1 \
  run_wrapper remote-proxy-test)
[[ "$remote_proxy_output" == *'BASE=https://proxy.example.test'* ]]
if CLAUDEX_PROXY_URL=http://proxy.example.test CLAUDEX_ALLOW_REMOTE_PROXY=1 run_wrapper remote-proxy-test \
    >"$tmp/insecure-remote.stdout" 2>"$tmp/insecure-remote.stderr"; then
  printf '%s\n' 'expected an opted-in remote proxy to require HTTPS' >&2
  exit 1
fi

interactive_wrapper_output=$(CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper --terra interactive-render-test)
[[ "$interactive_wrapper_output" == *'INTERACTIVE=1'* ]]
[[ "$interactive_wrapper_output" == *'CHATGPT_PLAN=ChatGPT Pro'* ]]
printf '%s\n' '{malformed' > "$tmp/home/.config/claudex/usage-cache/limits.json"
repaired_plan_output=$(CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper --terra repaired-plan-cache-test)
[[ "$repaired_plan_output" == *'CHATGPT_PLAN=ChatGPT Pro'* ]]
jq -e '.plan_type == "pro"' "$tmp/home/.config/claudex/usage-cache/limits.json" >/dev/null

warning_bridge="$tmp/warning-skill-bridge.cjs"
cat > "$warning_bridge" <<'EOF'
#!/usr/bin/env node
process.stdout.write(JSON.stringify({
  addDirs: [], pluginDirs: [],
  warnings: ['Unsafe skill ignored', 'Unsafe skill ignored', 'Plugin fallback\nusing last known good snapshot', 'Bidi \u202E safe', 'x'.repeat(700)],
}));
EOF
rm -f "$tmp/home/.config/claudex/run/skill-warning-state"
CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=inherited CLAUDEX_SKILL_BRIDGE_HELPER="$warning_bridge" run_wrapper warning-test \
  >"$tmp/warning-first.stdout" 2>"$tmp/warning-first.stderr"
[[ "$(grep -c 'Unsafe skill ignored' "$tmp/warning-first.stderr")" == 1 ]]
grep -F 'Plugin fallback using last known good snapshot' "$tmp/warning-first.stderr" >/dev/null
grep -F 'Bidi safe' "$tmp/warning-first.stderr" >/dev/null
if LC_ALL=C grep -q $'\342\200\256' "$tmp/warning-first.stderr"; then
  printf '%s\n' 'skill warning retained a Unicode bidi control' >&2
  exit 1
fi
awk 'length($0) > 540 { exit 1 }' "$tmp/warning-first.stderr"
grep -F 'ADDITIONAL_CLAUDE_MD=inherited' "$tmp/warning-first.stdout" >/dev/null
CLAUDEX_SKILL_BRIDGE_HELPER="$warning_bridge" run_wrapper warning-test \
  >"$tmp/warning-second.stdout" 2>"$tmp/warning-second.stderr"
[[ ! -s "$tmp/warning-second.stderr" ]]
jq -e '
  (.autoMode.allow | index("Default allow rule") != null)
  and ([.autoMode.allow[] | select(. == "User custom allow rule")] | length == 1)
  and (.autoMode.allow | any(startswith("Explicit Action Approval:")))
  and (.autoMode.environment | index("Default environment rule") != null)
  and ([.autoMode.environment[] | select(. == "User custom environment rule")] | length == 1)
  and (.autoMode.environment | any(startswith("User designated task boundary:")))
  and (.autoMode.environment | any(startswith("Explicitly approved development transfer:")))
  and ([.autoMode.soft_deny[] | select(. == "Default soft deny")] | length == 1)
  and ([.autoMode.soft_deny[] | select(. == "User custom soft deny rule")] | length == 1)
  and (.autoMode.soft_deny | any(startswith("Approved Private Development Transfer")))
  and ([.autoMode.hard_deny[] | select(. == "User custom hard deny rule")] | length == 1)
  and (.autoMode.hard_deny | any(startswith("Data Exfiltration:")
    and contains("Claudex scoped private development transfer exception:")
    and contains("public destination") and contains("credentials or secrets") and contains("different host")))
' "$tmp/home/.config/claudex/settings.json" >/dev/null
FAKE_AUTO_MODE_DEFAULT_VERSION=2 run_wrapper --terra test-prompt >/dev/null
jq -e '
  (.autoMode.allow | index("Default allow rule") == null)
  and (.autoMode.allow | index("Updated default allow rule") != null)
  and ([.autoMode.allow[] | select(. == "User custom allow rule")] | length == 1)
  and (.autoMode.environment | index("Default environment rule") == null)
  and (.autoMode.environment | index("Updated default environment rule") != null)
  and ([.autoMode.environment[] | select(. == "User custom environment rule")] | length == 1)
  and (.autoMode.soft_deny | index("Default soft deny") == null)
  and (.autoMode.soft_deny | index("Updated soft deny") != null)
  and ([.autoMode.soft_deny[] | select(. == "User custom soft deny rule")] | length == 1)
  and (.autoMode.hard_deny | any(startswith("Data Exfiltration: updated hard deny") and contains("Claudex scoped private development transfer exception:")))
  and ([.autoMode.hard_deny[] | select(. == "User custom hard deny rule")] | length == 1)
' "$tmp/home/.config/claudex/settings.json" >/dev/null

proxy_lock="$tmp/home/.config/claudex/run/proxy-start.lock"
stop_fake_managed_proxy() {
  local metadata="$tmp/home/.config/claudex/run/managed-proxy" pid=""
  if [[ -r "$metadata" ]]; then
    pid=$(awk -F= '$1 == "pid" { print $2; exit }' "$metadata")
    [[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true
    rm -f "$metadata"
  fi
}

# Proxy startup uses the shared generation protocol itself. Force the portable
# publication path and a complete publication failure before exercising races.
proxy_fallback_ready="$tmp/proxy-fallback-ready"
proxy_fallback_log="$tmp/proxy-fallback.log"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SKIP_AUTH_SYNC=1 CLAUDEX_SKILL_BRIDGE=off CLAUDEX_TEST_FORCE_HARDLINK_FAILURE=1 \
  CLAUDEX_TEST_PROXY_REACHABLE_FILE="$proxy_fallback_ready" \
  FAKE_PROXY_READY_FILE="$proxy_fallback_ready" FAKE_PROXY_START_LOG="$proxy_fallback_log" \
  "$root/claudex" proxy-fallback-test >/dev/null
[[ -e "$proxy_fallback_ready" && "$(wc -l < "$proxy_fallback_log" | tr -d ' ')" == 1 && ! -e "$proxy_lock" ]]
stop_fake_managed_proxy
rm -f "$proxy_fallback_ready" "$proxy_fallback_log"

proxy_partial_attempt="$tmp/proxy-partial-attempt"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SKIP_AUTH_SYNC=1 CLAUDEX_SKILL_BRIDGE=off CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE=1 \
  CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE_MATCH=proxy-start.lock \
  CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE="$proxy_partial_attempt" \
  FAKE_PROXY_READY_FILE="$tmp/proxy-partial-ready" FAKE_PROXY_NEVER_READY=1 \
  "$root/claudex" proxy-partial-test >"$tmp/proxy-partial.out" 2>"$tmp/proxy-partial.err" &
proxy_partial_pid=$!
for _ in {1..1000}; do grep -q '^blocked ' "$proxy_partial_attempt" 2>/dev/null && break; sleep 0.02; done
grep -q '^blocked ' "$proxy_partial_attempt"
[[ ! -e "$proxy_lock" ]] && ! compgen -G "$proxy_lock.quarantine.*" >/dev/null
kill -TERM "$proxy_partial_pid" 2>/dev/null || true
wait "$proxy_partial_pid" 2>/dev/null || true

# A recent legacy ownerless lock is preserved. The attempt marker makes the
# assertion independent of scheduler timing.
mkdir -p "$proxy_lock"
proxy_ownerless_attempt="$tmp/proxy-ownerless-attempt"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SKIP_AUTH_SYNC=1 CLAUDEX_SKILL_BRIDGE=off CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE="$proxy_ownerless_attempt" \
  FAKE_PROXY_READY_FILE="$tmp/proxy-ownerless-ready" FAKE_PROXY_NEVER_READY=1 \
  "$root/claudex" proxy-ownerless-test >"$tmp/proxy-ownerless.out" 2>"$tmp/proxy-ownerless.err" &
proxy_ownerless_pid=$!
for _ in {1..1000}; do grep -q '^blocked ' "$proxy_ownerless_attempt" 2>/dev/null && break; sleep 0.02; done
grep -q '^blocked ' "$proxy_ownerless_attempt"
[[ -d "$proxy_lock" && ! -e "$proxy_lock/owner" && ! -e "$proxy_lock/generation" ]]
kill -TERM "$proxy_ownerless_pid" 2>/dev/null || true
wait "$proxy_ownerless_pid" 2>/dev/null || true
rm -rf "$proxy_lock"

# A creator paused before publication cannot overwrite a later generation.
proxy_race_ready="$tmp/proxy-race-ready"
proxy_race_log="$tmp/proxy-race.log"
proxy_race_base=(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SKIP_AUTH_SYNC=1 CLAUDEX_SKILL_BRIDGE=off CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity \
  CLAUDEX_TEST_LOCK_MATCH=proxy-start.lock CLAUDEX_TEST_PROXY_REACHABLE_FILE="$proxy_race_ready" \
  FAKE_PROXY_READY_FILE="$proxy_race_ready" FAKE_PROXY_START_LOG="$proxy_race_log")
env "${proxy_race_base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/proxy-a-mkdir" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/proxy-a-continue" \
  CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE="$tmp/proxy-a-attempt" \
  "$root/claudex" proxy-a-test >/dev/null &
proxy_a=$!
for _ in {1..1000}; do [[ -e "$tmp/proxy-a-mkdir" ]] && break; sleep 0.02; done
[[ -e "$tmp/proxy-a-mkdir" ]]
touch -t 200001010000 "$proxy_lock"
env "${proxy_race_base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/proxy-b-publish" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/proxy-b-continue" \
  "$root/claudex" proxy-b-test >/dev/null &
proxy_b=$!
for _ in {1..1000}; do [[ -e "$tmp/proxy-b-publish" ]] && break; sleep 0.02; done
[[ -e "$tmp/proxy-b-publish" ]]
proxy_b_nonce=$(awk -F= '$1 == "nonce" { print $2; exit }' "$proxy_lock/owner")
: > "$tmp/proxy-a-continue"
for _ in {1..1000}; do grep -q '^blocked ' "$tmp/proxy-a-attempt" 2>/dev/null && break; sleep 0.02; done
grep -q '^blocked ' "$tmp/proxy-a-attempt"
[[ "$(awk -F= '$1 == "nonce" { print $2; exit }' "$proxy_lock/owner")" == "$proxy_b_nonce" ]]
: > "$tmp/proxy-b-continue"
wait "$proxy_b"
wait "$proxy_a"
[[ "$(wc -l < "$proxy_race_log" | tr -d ' ')" == 1 && ! -e "$proxy_lock" ]]
stop_fake_managed_proxy
rm -f "$proxy_race_ready" "$proxy_race_log"

# A stale X remover that moves Y cannot admit Z. Y restores its own generation
# when it resumes, then starts the single proxy instance.
mkdir -p "$proxy_lock"
printf '%s\n' proxy-x > "$proxy_lock/generation"
printf 'pid=99999999\nidentity=dead\nnonce=proxy-x\n' > "$proxy_lock/owner"
touch -t 200001010000 "$proxy_lock"
env "${proxy_race_base[@]}" CLAUDEX_TEST_LOCK_BEFORE_RENAME_READY="$tmp/proxy-x-before" \
  CLAUDEX_TEST_LOCK_BEFORE_RENAME_CONTINUE="$tmp/proxy-x-before-continue" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_READY="$tmp/proxy-x-after" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_CONTINUE="$tmp/proxy-x-after-continue" \
  "$root/claudex" proxy-x-test >/dev/null &
proxy_x=$!
for _ in {1..1000}; do [[ -e "$tmp/proxy-x-before" ]] && break; sleep 0.02; done
[[ -e "$tmp/proxy-x-before" ]]
env "${proxy_race_base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/proxy-y-publish" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/proxy-y-continue" \
  CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE="$tmp/proxy-y-recovered" \
  "$root/claudex" proxy-y-test >/dev/null &
proxy_y=$!
for _ in {1..1000}; do [[ -e "$tmp/proxy-y-publish" ]] && break; sleep 0.02; done
[[ -e "$tmp/proxy-y-publish" ]]
proxy_y_nonce=$(awk -F= '$1 == "nonce" { print $2; exit }' "$proxy_lock/owner")
: > "$tmp/proxy-x-before-continue"
for _ in {1..1000}; do [[ -e "$tmp/proxy-x-after" ]] && break; sleep 0.02; done
[[ -e "$tmp/proxy-x-after" ]]
env "${proxy_race_base[@]}" CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE="$tmp/proxy-z-attempt" \
  "$root/claudex" proxy-z-test >/dev/null &
proxy_z=$!
for _ in {1..1000}; do grep -q '^blocked ' "$tmp/proxy-z-attempt" 2>/dev/null && break; sleep 0.02; done
grep -q '^blocked ' "$tmp/proxy-z-attempt"
[[ "$(awk -F= '$1 == "nonce" { print $2; exit }' "$proxy_lock/owner")" == "$proxy_y_nonce" ]]
: > "$tmp/proxy-y-continue"
for _ in {1..1000}; do [[ -e "$tmp/proxy-y-recovered" ]] && break; sleep 0.02; done
[[ -e "$tmp/proxy-y-recovered" ]]
: > "$tmp/proxy-x-after-continue"
wait "$proxy_y"
wait "$proxy_x"
wait "$proxy_z"
[[ "$(wc -l < "$proxy_race_log" | tr -d ' ')" == 1 && ! -e "$proxy_lock" ]]
stop_fake_managed_proxy

# Releasing an old owner never deletes a replacement generation.
rm -f "$proxy_race_ready" "$proxy_race_log"
proxy_release_attempt="$tmp/proxy-release-attempt"
env "${proxy_race_base[@]}" CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE="$proxy_release_attempt" \
  FAKE_PROXY_NEVER_READY=1 "$root/claudex" proxy-release-test >/dev/null 2>"$tmp/proxy-release.err" &
proxy_release_pid=$!
for _ in {1..1000}; do
  grep -q '^acquired ' "$proxy_release_attempt" 2>/dev/null && [[ -s "$proxy_race_log" ]] && break
  sleep 0.02
done
grep -q '^acquired ' "$proxy_release_attempt"
[[ -s "$proxy_race_log" ]]
mv "$proxy_lock" "$tmp/displaced-proxy-lock"
mkdir -p "$proxy_lock"
printf '%s\n' proxy-replacement > "$proxy_lock/generation"
printf 'pid=%s\nidentity=%s\nnonce=proxy-replacement\n' "$$" test-process-identity > "$proxy_lock/owner"
kill -TERM "$proxy_release_pid" 2>/dev/null || true
wait "$proxy_release_pid" 2>/dev/null || true
grep -F 'nonce=proxy-replacement' "$proxy_lock/owner" >/dev/null
rm -rf "$proxy_lock" "$tmp/displaced-proxy-lock"
stop_fake_managed_proxy

# A reused live PID with a different start identity is stale, while a genuinely
# live record remains protected regardless of directory age.
rm -f "$proxy_race_ready" "$proxy_race_log"
mkdir -p "$proxy_lock"
printf '%s\n' proxy-reused-pid > "$proxy_lock/generation"
printf 'pid=%s\nidentity=stale-process-identity\nnonce=proxy-reused-pid\n' "$$" > "$proxy_lock/owner"
touch -t 200001010000 "$proxy_lock"
env "${proxy_race_base[@]}" "$root/claudex" proxy-reused-pid-test >/dev/null
[[ -e "$proxy_race_ready" && -s "$proxy_race_log" && ! -e "$proxy_lock" ]]
stop_fake_managed_proxy

# A genuinely old ownerless legacy directory is reclaimable after its
# conservative transition window.
rm -f "$proxy_race_ready" "$proxy_race_log"
mkdir -p "$proxy_lock"
touch -t 200001010000 "$proxy_lock"
env "${proxy_race_base[@]}" "$root/claudex" proxy-stale-ownerless-test >/dev/null
[[ -e "$proxy_race_ready" && -s "$proxy_race_log" && ! -e "$proxy_lock" ]]
stop_fake_managed_proxy

proxy_ready_file="$tmp/proxy-ready"
proxy_start_log="$tmp/proxy-start.log"
proxy_env_log="$tmp/proxy-env.log"
: > "$proxy_ready_file"
proxy_recovery_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=0 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SKIP_AUTH_SYNC=1 CLAUDEX_SKILL_BRIDGE=off CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity \
  CLAUDEX_TEST_PROXY_REACHABLE_FILE="$proxy_ready_file" \
  ANTHROPIC_BASE_URL=https://caller.invalid ANTHROPIC_AUTH_TOKEN=caller-anthropic-secret \
  ANTHROPIC_API_KEY=caller-api-secret CLAUDEX_PROXY_TOKEN=test-token \
  CLAUDE_CODE_AUTO_MODE_MODEL=caller-auto CLAUDE_CODE_BG_CLASSIFIER_MODEL=caller-background \
  CLAUDE_CODE_SUBAGENT_MODEL=caller-subagent BUN_OPTIONS='--preload /caller/preload.cjs' \
  FAKE_PROXY_READY_FILE="$proxy_ready_file" FAKE_PROXY_START_LOG="$proxy_start_log" FAKE_PROXY_ENV_LOG="$proxy_env_log" \
  FAKE_PROXY_RECOVERY=1 "$root/claudex" recovery-test)
[[ "$proxy_recovery_output" == *'PROXY_RECOVERED=1'* ]]
[[ "$(wc -l < "$proxy_start_log" | tr -d ' ')" == 1 ]]
[[ "$(<"$proxy_env_log")" == $'BASE_URL=\nAUTH_TOKEN=\nAPI_KEY=\nPROXY_TOKEN=\nCLAUDE_CONFIG=\nAUTO_MODEL=\nBG_MODEL=\nSUBAGENT_MODEL=\nBUN_OPTIONS=' ]]
[[ ! -e "$tmp/home/.config/claudex/run/proxy-start.lock" ]]

# Lock age alone must never evict a live proxy-start owner. Simulate a slow
# startup, backdate only its lock directory, and verify a waiting launcher
# leaves that exact ownership generation in place.
live_owner_ready_file="$tmp/live-owner-proxy-ready"
live_owner_start_log="$tmp/live-owner-proxy-start.log"
live_owner_lock="$tmp/home/.config/claudex/run/proxy-start.lock"
rm -f "$live_owner_ready_file" "$live_owner_start_log"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SKIP_AUTH_SYNC=1 CLAUDEX_SKILL_BRIDGE=off CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity \
  FAKE_PROXY_READY_FILE="$live_owner_ready_file" FAKE_PROXY_START_LOG="$live_owner_start_log" FAKE_PROXY_NEVER_READY=1 \
  "$root/claudex" live-owner-first >"$tmp/live-owner-first.out" 2>"$tmp/live-owner-first.err" &
live_owner_first_pid=$!
for _ in {1..1000}; do
  [[ -s "$live_owner_start_log" && -r "$live_owner_lock/owner" && -r "$live_owner_lock/generation" ]] && break
  sleep 0.02
done
[[ -s "$live_owner_start_log" && -r "$live_owner_lock/owner" && -r "$live_owner_lock/generation" ]]
live_owner_record=$(<"$live_owner_lock/owner")
live_owner_generation=$(<"$live_owner_lock/generation")
touch -t 202001010000 "$live_owner_lock"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SKIP_AUTH_SYNC=1 CLAUDEX_SKILL_BRIDGE=off CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity \
  CLAUDEX_TEST_PROXY_LOCK_ATTEMPT_FILE="$tmp/live-owner-second-attempt" \
  FAKE_PROXY_READY_FILE="$live_owner_ready_file" FAKE_PROXY_START_LOG="$live_owner_start_log" FAKE_PROXY_NEVER_READY=1 \
  "$root/claudex" live-owner-second >"$tmp/live-owner-second.out" 2>"$tmp/live-owner-second.err" &
live_owner_second_pid=$!
for _ in {1..1000}; do grep -q '^blocked ' "$tmp/live-owner-second-attempt" 2>/dev/null && break; sleep 0.02; done
grep -q '^blocked ' "$tmp/live-owner-second-attempt"
live_owner_record_after=""
[[ ! -r "$live_owner_lock/owner" ]] || live_owner_record_after=$(<"$live_owner_lock/owner")
live_owner_generation_after=""
[[ ! -r "$live_owner_lock/generation" ]] || live_owner_generation_after=$(<"$live_owner_lock/generation")
kill -TERM "$live_owner_second_pid" "$live_owner_first_pid" 2>/dev/null || true
wait "$live_owner_second_pid" 2>/dev/null || true
wait "$live_owner_first_pid" 2>/dev/null || true
if [[ -r "$tmp/home/.config/claudex/run/managed-proxy" ]]; then
  live_owner_proxy_pid=$(awk -F= '$1 == "pid" { print $2; exit }' "$tmp/home/.config/claudex/run/managed-proxy")
  [[ -z "$live_owner_proxy_pid" ]] || kill -TERM "$live_owner_proxy_pid" 2>/dev/null || true
  rm -f "$tmp/home/.config/claudex/run/managed-proxy"
fi
rm -rf "$live_owner_lock"
[[ -n "$live_owner_record_after" ]]
[[ "$live_owner_record_after" == "$live_owner_record" ]]
[[ "$live_owner_generation_after" == "$live_owner_generation" ]]

transient_proxy_start_log="$tmp/transient-proxy-start.log"
: > "$proxy_ready_file"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 CLAUDEX_SKIP_PROXY_WATCHER=0 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity \
  CLAUDEX_TEST_PROXY_REACHABLE_FILE="$proxy_ready_file" \
  FAKE_PROXY_READY_FILE="$proxy_ready_file" FAKE_PROXY_START_LOG="$transient_proxy_start_log" \
  FAKE_PROXY_TRANSIENT_ONCE=1 "$root/claudex" transient-health-test >/dev/null
[[ ! -s "$transient_proxy_start_log" ]]
existing_managed_proxy_file="$tmp/home/.config/claudex/run/managed-proxy"
if [[ -r "$existing_managed_proxy_file" ]]; then
  existing_managed_proxy_pid=$(awk -F= '$1 == "pid" { print $2; exit }' "$existing_managed_proxy_file")
  [[ -z "$existing_managed_proxy_pid" ]] || kill -TERM "$existing_managed_proxy_pid" 2>/dev/null || true
  rm -f "$existing_managed_proxy_file"
fi

proxy_auth_curl="$tmp/bin/curl-proxy-auth"
cat > "$proxy_auth_curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (( $# > 0 )); do
  case "$1" in --output) output="$2"; shift ;; esac
  shift
done
[[ -n "$output" ]]
state=$(<"$FAKE_PROXY_HEALTH_STATE")
case "$state" in
  healthy)
    printf '%s\n' '{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}' > "$output"
    printf '%s' 200
    ;;
  unauthorized) printf '%s\n' '{}' > "$output"; printf '%s' 401 ;;
  *) printf '%s\n' '{}' > "$output"; printf '%s' 503 ;;
esac
EOF
auth_proxy_bin="$tmp/bin/cliproxyapi-auth-test"
cat > "$auth_proxy_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_PROXY_START_STATE:-healthy}" > "$FAKE_PROXY_HEALTH_STATE"
printf '%s\n' "$$" >> "$FAKE_PROXY_AUTH_START_LOG"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
chmod +x "$proxy_auth_curl" "$auth_proxy_bin"
proxy_auth_state="$tmp/proxy-auth-state"
proxy_auth_log="$tmp/proxy-auth-start.log"
managed_proxy_file="$tmp/home/.config/claudex/run/managed-proxy"
mkdir -p "$(dirname "$managed_proxy_file")"

# A 401/403 is recoverable only when mode-restricted PID metadata proves that
# Claudex owns the tracked process. The old process must be replaced exactly
# once and the new managed process remains healthy for the session.
printf '%s\n' unauthorized > "$proxy_auth_state"
sleep 60 & tracked_proxy_pid=$!
tracked_proxy_identity=test-process-identity
printf 'pid=%s\nidentity=%s\n' "$tracked_proxy_pid" "$tracked_proxy_identity" > "$managed_proxy_file"
if ! managed_401_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$proxy_auth_curl" \
  CLAUDEX_PROXY_BIN="$auth_proxy_bin" CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 \
  CLAUDEX_SKIP_PROXY_WATCHER=1 FAKE_PROXY_HEALTH_STATE="$proxy_auth_state" \
  FAKE_PROXY_AUTH_START_LOG="$proxy_auth_log" FAKE_PROXY_START_STATE=healthy \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY="$tracked_proxy_identity" \
  "$root/claudex" managed-401-test 2>"$tmp/managed-401.stderr"); then
  cat "$tmp/managed-401.stderr" >&2
  exit 1
fi
[[ "$managed_401_output" == *'ARGS='*'managed-401-test'* ]]
if kill -0 "$tracked_proxy_pid" 2>/dev/null; then
  printf '%s\n' 'expected the tracked unauthorized proxy to be replaced' >&2
  exit 1
fi
[[ "$(wc -l < "$proxy_auth_log" | tr -d ' ')" == 1 ]]
replacement_proxy_pid=$(awk -F= '$1 == "pid" { print $2; exit }' "$managed_proxy_file")
kill -TERM "$replacement_proxy_pid" 2>/dev/null || true
for _ in {1..50}; do kill -0 "$replacement_proxy_pid" 2>/dev/null || break; sleep 0.02; done
rm -f "$managed_proxy_file"

# Without current managed ownership metadata, the same authentication failure
# is fail-closed and must never start or terminate an arbitrary listener.
printf '%s\n' unauthorized > "$proxy_auth_state"
: > "$proxy_auth_log"
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$proxy_auth_curl" \
    CLAUDEX_PROXY_BIN="$auth_proxy_bin" CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 \
    CLAUDEX_SKIP_PROXY_WATCHER=1 FAKE_PROXY_HEALTH_STATE="$proxy_auth_state" \
    FAKE_PROXY_AUTH_START_LOG="$proxy_auth_log" CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY="$tracked_proxy_identity" \
    "$root/claudex" unmanaged-401-test \
    >"$tmp/unmanaged-401.stdout" 2>"$tmp/unmanaged-401.stderr"; then
  printf '%s\n' 'expected an unmanaged 401 listener to fail closed' >&2
  exit 1
fi
grep -F 'not proven Claudex-managed' "$tmp/unmanaged-401.stderr" >/dev/null
[[ ! -s "$proxy_auth_log" && ! -e "$managed_proxy_file" ]]

# A child that starts but never becomes authenticated must be terminated and
# must not leave PID metadata that could authorize a later destructive retry.
printf '%s\n' unavailable > "$proxy_auth_state"
: > "$proxy_auth_log"
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$proxy_auth_curl" \
    CLAUDEX_PROXY_BIN="$auth_proxy_bin" CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_AUTH_WATCHER=1 \
    CLAUDEX_SKIP_PROXY_WATCHER=1 FAKE_PROXY_HEALTH_STATE="$proxy_auth_state" \
    FAKE_PROXY_AUTH_START_LOG="$proxy_auth_log" FAKE_PROXY_START_STATE=unauthorized \
    CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY="$tracked_proxy_identity" \
    "$root/claudex" never-ready-proxy-test >"$tmp/never-ready.stdout" 2>"$tmp/never-ready.stderr"; then
  printf '%s\n' 'expected a newly spawned unauthorized proxy to fail readiness' >&2
  exit 1
fi
never_ready_pid=$(tail -1 "$proxy_auth_log")
[[ "$never_ready_pid" =~ ^[0-9]+$ ]]
[[ ! -e "$managed_proxy_file" ]]
if kill -0 "$never_ready_pid" 2>/dev/null; then
  printf '%s\n' 'newly spawned failed proxy was not terminated' >&2
  exit 1
fi

auto_output=$(run_wrapper --auto --luna test-prompt)
[[ "$auto_output" == *'--permission-mode auto'* ]]
[[ "$auto_output" == *'--model gpt-5.6-luna'* ]]
configured_model_output=$(CLAUDEX_MODEL=gpt-5.6-luna run_wrapper test-prompt)
[[ "$configured_model_output" == *'--model gpt-5.6-luna'* ]]
configured_model_override=$(CLAUDEX_MODEL=gpt-5.6-luna run_wrapper --terra test-prompt)
[[ "$configured_model_override" == *'--model gpt-5.6-terra'* ]]
if CLAUDEX_MODEL=claude-sonnet-5 run_wrapper test-prompt >/dev/null 2>&1; then
  printf '%s\n' 'expected invalid default model to fail before proxy startup' >&2
  exit 1
fi

ultracode_output=$(run_wrapper --ultracode --sol test-prompt)
[[ "$ultracode_output" == *'MODE=ultracode'* ]]
[[ "$ultracode_output" == *'--effort xhigh'* ]]
[[ "$ultracode_output" == *'"ultracode":true'* ]]
[[ "$ultracode_output" == *'"workflows":true'* ]]

max_output=$(run_wrapper --max-effort test-prompt)
[[ "$max_output" == *'MODE=max'* ]]
[[ "$max_output" == *'--effort max'* ]]

explicit_forwarded_model=$(run_wrapper --model gpt-5.6-luna test-prompt)
[[ "$explicit_forwarded_model" == *'--model gpt-5.6-luna test-prompt'* ]]
[[ "$explicit_forwarded_model" != *'--model gpt-5.6-luna --model gpt-5.6-luna'* ]]
explicit_forwarded_alias=$(run_wrapper --model sonnet test-prompt)
[[ "$explicit_forwarded_alias" == *'--model sonnet test-prompt'* ]]
[[ "$explicit_forwarded_alias" != *'--model gpt-5.6-terra --model sonnet'* ]]
explicit_forwarded_solplan=$(run_wrapper --model opusplan test-prompt)
[[ "$explicit_forwarded_solplan" == *'--model opusplan test-prompt'* ]]
[[ "$explicit_forwarded_solplan" == *'MODEL_MODE=solplan'* ]]
fallback_launch=$(FAKE_ONLY_MODEL=gpt-5.6-luna run_wrapper --model gpt-5.6-sol --fallback-model haiku fallback-test)
[[ "$fallback_launch" == *'--model gpt-5.6-sol --fallback-model haiku fallback-test'* ]]
fallback_equals=$(FAKE_ONLY_MODEL=gpt-5.6-terra run_wrapper --model=gpt-5.6-sol --fallback-model=sonnet fallback-equals)
[[ "$fallback_equals" == *'--model=gpt-5.6-sol --fallback-model=sonnet fallback-equals'* ]]
if run_wrapper --model= >/dev/null 2>&1; then
  printf '%s\n' 'empty explicit model unexpectedly launched' >&2
  exit 1
fi
if run_wrapper --model solplan >/dev/null 2>&1; then
  printf '%s\n' 'unsupported CLI solplan alias unexpectedly launched' >&2
  exit 1
fi
if run_wrapper --terra --model gpt-5.6-luna >/dev/null 2>&1; then
  printf '%s\n' 'conflicting model selectors unexpectedly launched' >&2
  exit 1
fi

delimiter_prompt=$(run_wrapper --max-effort -- --settings)
[[ "$delimiter_prompt" == *'--effort max -- --settings'* ]]
delimiter_permission=$(run_wrapper -- --permission-mode)
[[ "$delimiter_permission" == *'--permission-mode auto'* ]]
[[ "$delimiter_permission" == *'-- --permission-mode'* ]]

model_shaped_prompt_value=$(run_wrapper --append-system-prompt --model literal-prompt-value)
[[ "$model_shaped_prompt_value" == *'--append-system-prompt --model literal-prompt-value'* ]]
[[ "$model_shaped_prompt_value" == *'--model gpt-5.6-sol'* ]]
settings_shaped_prompt_value=$(run_wrapper --max-effort --append-system-prompt --settings literal-prompt)
[[ "$settings_shaped_prompt_value" == *'--effort max'* ]]
[[ "$settings_shaped_prompt_value" == *'--append-system-prompt --settings literal-prompt'* ]]
agent_shaped_value=$(run_wrapper --agent --permission-mode agent-value-test)
[[ "$agent_shaped_value" == *'--permission-mode auto'* ]]
[[ "$agent_shaped_value" == *'--agent --permission-mode agent-value-test'* ]]

restricted_tools=$(run_wrapper --tools '' --print restricted-tools-test)
[[ "$restricted_tools" != *'Before every final answer, call TaskList'* ]]
complete_tools=$(run_wrapper --tools 'Bash Agent TaskList' --print complete-tools-test)
[[ "$complete_tools" == *'Before every final answer, call TaskList'* ]]
disallowed_lifecycle_tools=$(run_wrapper --disallowedTools 'TaskList Agent' restricted-tools-test)
[[ "$disallowed_lifecycle_tools" != *'Before every final answer, call TaskList'* ]]
disallowed_unrelated_tools=$(run_wrapper --disallowed-tools 'Bash WebFetch' unrelated-tools-test)
[[ "$disallowed_unrelated_tools" == *'Before every final answer, call TaskList'* ]]

no_persistence_launch=$(run_wrapper --no-session-persistence --print test-prompt)
[[ "$no_persistence_launch" == *'NO_SESSION_PERSISTENCE=1'* ]]

solplan_output=$(run_wrapper --solplan test-prompt)
[[ "$solplan_output" == *'--model opusplan'* ]]
[[ "$solplan_output" == *'OPUS=gpt-5.6-sol'* ]]
[[ "$solplan_output" == *$'SUBAGENT=\n'* ]]

resume_footer_output=$(FAKE_CLAUDE_RESUME=1 CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper)
[[ "$resume_footer_output" != *$'\033[2A'* ]]
[[ "$resume_footer_output" == *$'Resume this session with Claudex:\nclaudex --resume 123e4567-e89b-12d3-a456-426614174000'* ]]
background_footer_output=$(FAKE_CLAUDE_RESUME=1 CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper --bg)
[[ "$background_footer_output" != *'Resume this session with Claudex:'* ]]

if interrupted_resume_output=$(FAKE_CLAUDE_RESUME=1 FAKE_CLAUDE_RESUME_EXIT=130 CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper); then
  interrupted_resume_exit=0
else
  interrupted_resume_exit=$?
fi
[[ "$interrupted_resume_exit" == 130 ]]
[[ "$interrupted_resume_output" != *$'\033[2A'* ]]
[[ "$interrupted_resume_output" == *$'Resume this session with Claudex:\nclaudex --resume 123e4567-e89b-12d3-a456-426614174000'* ]]

assert_launcher_signal_forwarding() {
  local signal="$1" expected_exit="$2" label
  label=$(printf '%s' "$signal" | tr '[:upper:]' '[:lower:]')
  local wrapper_pid_file="$tmp/launcher-$label.pid"
  local claude_pid_file="$tmp/claude-$label.pid"
  local ready_file="$tmp/claude-$label.ready"
  local received_file="$tmp/claude-$label.received"
  local driver_pid wrapper_pid child_pid driver_exit=0 attempt
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
    CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_SKIP_PROXY_WATCHER=1 \
    CLAUDEX_TEST_WRAPPER_PID_FILE="$wrapper_pid_file" \
    FAKE_CLAUDE_SIGNAL_PID_FILE="$claude_pid_file" \
    FAKE_CLAUDE_SIGNAL_READY_FILE="$ready_file" \
    FAKE_CLAUDE_SIGNAL_RECEIVED_FILE="$received_file" \
    node "$tmp/launcher-signal-driver.cjs" "$root/claudex" --claude-chrome --print signal-test &
  driver_pid=$!
  for attempt in {1..250}; do
    [[ -s "$wrapper_pid_file" && -s "$claude_pid_file" && -e "$ready_file" ]] && break
    sleep 0.02
  done
  [[ -s "$wrapper_pid_file" && -s "$claude_pid_file" && -e "$ready_file" ]]
  read -r wrapper_pid < "$wrapper_pid_file"
  read -r child_pid < "$claude_pid_file"
  kill -s "$signal" "$wrapper_pid"
  set +e
  wait "$driver_pid"
  driver_exit=$?
  set -e
  [[ "$driver_exit" == "$expected_exit" ]]
  [[ "$(cat "$received_file")" == "$signal" ]]
  for attempt in {1..100}; do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.02
  done
  ! kill -0 "$child_pid" 2>/dev/null
}

assert_launcher_signal_forwarding TERM 143
assert_launcher_signal_forwarding INT 130
assert_launcher_signal_forwarding HUP 129

bare_output=$(run_wrapper --bare --print test-prompt)
[[ "$bare_output" != *'--agents'* ]]
[[ "$bare_output" != *'--add-dir'* ]]
[[ "$bare_output" != *'--append-system-prompt'* ]]
[[ "$bare_output" != *'--permission-mode'* ]]

trailing_bare_output=$(run_wrapper literal-prompt --bare --print)
[[ "$trailing_bare_output" != *'--agents'* && "$trailing_bare_output" != *'--add-dir'* ]]
[[ "$trailing_bare_output" != *'--append-system-prompt'* && "$trailing_bare_output" != *'--permission-mode'* ]]
trailing_model_output=$(run_wrapper literal-prompt --model gpt-5.6-luna)
[[ "$trailing_model_output" == *'literal-prompt --model gpt-5.6-luna'* ]]
[[ "$trailing_model_output" != *'--model gpt-5.6-sol literal-prompt --model gpt-5.6-luna'* ]]

prose_only_capabilities=$(FAKE_CLAUDE_HELP_PROSE_ONLY=1 CLAUDEX_SKILL_BRIDGE=off \
  run_wrapper --print prose-capability-test)
[[ "$prose_only_capabilities" != *'--agents'* && "$prose_only_capabilities" != *'--append-system-prompt'* ]]
[[ "$prose_only_capabilities" != *'--permission-mode'* && "$prose_only_capabilities" != *'--add-dir'* ]]

for optional_form in '--debug=api' '-dapi' '--from-pr=42' '--prompt-suggestions=false' '--resume=session-123' '-rsession-123' '--worktree=audit' '-waudit'; do
  optional_output=$(run_wrapper "$optional_form" --bare --print optional-form-test)
  [[ "$optional_output" == *"$optional_form"* ]]
  [[ "$optional_output" != *'--agents'* && "$optional_output" != *'--permission-mode'* ]]
done

worktree_bridge_probe="$tmp/worktree-skill-bridge.cjs"
worktree_bridge_log="$tmp/worktree-skill-bridge.log"
cat > "$worktree_bridge_probe" <<'EOF'
#!/usr/bin/env node
'use strict';
require('fs').writeFileSync(process.env.CLAUDEX_TEST_WORKTREE_BRIDGE_LOG, process.argv.slice(2).join('\n') + '\n');
process.stdout.write(JSON.stringify({ addDirs: [], pluginDirs: [], instructions: [], warnings: [] }) + '\n');
EOF
assert_worktree_bridge_mode() {
  : > "$worktree_bridge_log"
  CLAUDEX_SKILL_BRIDGE_HELPER="$worktree_bridge_probe" \
    CLAUDEX_TEST_WORKTREE_BRIDGE_LOG="$worktree_bridge_log" \
    run_wrapper "$@" --print worktree-bridge-test >/dev/null
  grep -Fx -- '--global-only' "$worktree_bridge_log" >/dev/null
}
assert_worktree_bridge_mode --worktree
assert_worktree_bridge_mode --worktree audit-tree
assert_worktree_bridge_mode --worktree=audit-tree
assert_worktree_bridge_mode -w
assert_worktree_bridge_mode -w audit-tree
assert_worktree_bridge_mode -w=audit-tree
assert_worktree_bridge_mode -waudit-tree
: > "$worktree_bridge_log"
CLAUDEX_SKILL_BRIDGE_HELPER="$worktree_bridge_probe" \
  CLAUDEX_TEST_WORKTREE_BRIDGE_LOG="$worktree_bridge_log" \
  run_wrapper --print ordinary-bridge-test >/dev/null
! grep -Fx -- '--global-only' "$worktree_bridge_log" >/dev/null

maintenance_output=$(CLAUDE_CODE_DISABLE_1M_CONTEXT=inherited run_wrapper mcp list)
[[ "$maintenance_output" == *'BASE='* ]]
[[ "$maintenance_output" != *"BASE=http"* ]]
[[ "$maintenance_output" == *$'DISABLE_1M=\n'* ]]
[[ "$maintenance_output" != *'--agents'* ]]

managed_maintenance_output=$(CLAUDEX_MANAGED_SESSION=1 CLAUDEX_PROXY_TOKEN=must-not-leak \
  ANTHROPIC_BASE_URL=https://managed.invalid ANTHROPIC_AUTH_TOKEN=managed-secret \
  BUN_OPTIONS="--preload $tmp/home/.config/claudex/preload.cjs --preload /user/preload.cjs" \
  run_wrapper doctor maintenance-sentinel)
[[ "$managed_maintenance_output" == *$'BASE=\n'* ]]
[[ "$managed_maintenance_output" == *$'PROXY_TOKEN_SET=\n'* ]]
[[ "$managed_maintenance_output" == *$'MANAGED=\n'* ]]
[[ "$managed_maintenance_output" == *'BUN=--preload /user/preload.cjs'* ]]

for maintenance_command in agents attach auth auto-mode doctor gateway install kill logs mcp plugin plugins project respawn rm setup-token stop update upgrade; do
  command_output=$(run_wrapper "$maintenance_command" --help)
  [[ "$command_output" != *'--agents'* ]]
  [[ "$command_output" != *'--append-system-prompt'* ]]
  [[ "$command_output" != *'--permission-mode'* ]]
  [[ "$command_output" != *'BASE=http'* ]]
done
prefixed_maintenance=$(CLAUDEX_NODE_BIN=relative/node run_wrapper --verbose mcp list)
[[ "$prefixed_maintenance" == *'ARGS=--verbose mcp list'* ]]
[[ "$prefixed_maintenance" != *'--agents'* && "$prefixed_maintenance" != *'BASE=http'* ]]

passthrough_output=$(run_wrapper --continue --resume session-123 --fork-session --from-pr 42 \
  --worktree audit-tree --tmux --ide --remote-control --plugin-dir /tmp/plugin \
  --mcp-config /tmp/mcp.json --strict-mcp-config --output-format json \
  --input-format stream-json --json-schema '{}' --session-id 00000000-0000-4000-8000-000000000000 \
  --debug chrome --verbose --brief --bg --chrome --no-chrome test-prompt)
for expected_argument in --continue '--resume session-123' --fork-session '--from-pr 42' \
  '--worktree audit-tree' --tmux --ide --remote-control '--plugin-dir /tmp/plugin' \
  '--mcp-config /tmp/mcp.json' --strict-mcp-config '--output-format json' \
  '--input-format stream-json' '--json-schema {}' --session-id '--debug chrome' \
  --verbose --brief --bg --chrome --no-chrome; do
  [[ "$passthrough_output" == *"$expected_argument"* ]]
done

explicit_permission_output=$(run_wrapper --permission-mode plan test-prompt)
[[ "$explicit_permission_output" == *'--permission-mode plan'* ]]
[[ "$explicit_permission_output" != *'--permission-mode auto'* ]]

explicit_agents_output=$(run_wrapper --agents '{}' test-prompt)
[[ "$explicit_agents_output" == *'--agents {}'* ]]
[[ "$explicit_agents_output" != *'"Terra (high)"'* ]]
[[ "$explicit_agents_output" == *'Ask as few questions as possible'* ]]
[[ "$explicit_agents_output" == *'Never repeat a question the user already answered'* ]]
[[ "$explicit_agents_output" == *'Treat the user'"'"'s explicit approval as decisive'* ]]
explicit_agent_output=$(run_wrapper --agent reviewer test-prompt)
[[ "$explicit_agent_output" == *'--agent reviewer test-prompt'* ]]
[[ "$explicit_agent_output" != *'"Terra (high)"'* ]]
[[ "$explicit_agent_output" != *'Before every final answer, call TaskList'* ]]
explicit_permission_equals=$(run_wrapper --permission-mode=plan test-prompt)
[[ "$explicit_permission_equals" == *'--permission-mode=plan test-prompt'* ]]
[[ "$explicit_permission_equals" != *'--permission-mode auto'* ]]
kebab_allowed_tools=$(run_wrapper --allowed-tools 'Read Edit' tools-alias-test)
[[ "$kebab_allowed_tools" == *'--allowed-tools Read Edit tools-alias-test'* ]]
[[ "$kebab_allowed_tools" == *'Before every final answer, call TaskList'* ]]

chrome_output=$(CLAUDE_CODE_DISABLE_1M_CONTEXT=inherited run_wrapper --claude-chrome --print chrome-test)
[[ "$chrome_output" == *'ARGS=--chrome --print chrome-test'* ]]
[[ "$chrome_output" == *$'CONFIG=\n'* ]]
[[ "$chrome_output" == *$'BUN=\n'* ]]
[[ "$chrome_output" == *$'DISABLE_1M=\n'* ]]
[[ "$chrome_output" == *$'AUTO=\n'* ]]
[[ "$chrome_output" == *$'BG=\n'* ]]
[[ "$chrome_output" == *$'SUBAGENT=\n'* ]]
[[ "$chrome_output" == *$'OPUS=\n'* ]]
[[ "$chrome_output" == *$'FABLE=\n'* ]]
[[ "$chrome_output" == *$'ADDITIONAL_CLAUDE_MD=\n'* ]]
[[ "$chrome_output" == *$'PROXY_TOKEN_SET=\n'* ]]
chrome_configured_model=$(CLAUDEX_MODEL=gpt-5.6-luna run_wrapper --claude-chrome --print chrome-test)
[[ "$chrome_configured_model" != *'--model gpt-5.6-luna'* ]]

inherited_chrome=$(ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5.6-sol \
  ANTHROPIC_DEFAULT_FABLE_MODEL=gpt-5.6-sol CLAUDE_CODE_AUTO_MODE_MODEL=gpt-5.6-terra \
  CLAUDE_CODE_BG_CLASSIFIER_MODEL=gpt-5.6-luna CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-terra \
  CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1 \
  ANTHROPIC_BEDROCK_BASE_URL=https://bedrock.invalid ANTHROPIC_VERTEX_BASE_URL=https://vertex.invalid \
  ANTHROPIC_FOUNDRY_BASE_URL=https://foundry.invalid \
  CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 run_wrapper --claude-chrome --print chrome-test)
[[ "$inherited_chrome" == *$'AUTO=\n'* && "$inherited_chrome" == *$'BG=\n'* ]]
[[ "$inherited_chrome" == *$'SUBAGENT=\n'* && "$inherited_chrome" == *$'OPUS=\n'* ]]
[[ "$inherited_chrome" == *$'FABLE=\n'* && "$inherited_chrome" == *'ADDITIONAL_CLAUDE_MD=1'* ]]
[[ "$inherited_chrome" == *$'USE_BEDROCK=\n'* && "$inherited_chrome" == *$'USE_VERTEX=\n'* ]]
[[ "$inherited_chrome" == *$'USE_FOUNDRY=\n'* && "$inherited_chrome" == *$'BEDROCK_BASE=\n'* ]]
[[ "$inherited_chrome" == *$'VERTEX_BASE=\n'* && "$inherited_chrome" == *$'FOUNDRY_BASE=\n'* ]]
managed_inherited_chrome=$(CLAUDEX_MANAGED_SESSION=1 CLAUDEX_PROXY_TOKEN=must-not-leak \
  CLAUDE_CODE_SUBAGENT_MODEL=user-selected-subagent CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1 \
  run_wrapper --claude-chrome --print chrome-test)
[[ "$managed_inherited_chrome" == *$'SUBAGENT=\n'* ]]
[[ "$managed_inherited_chrome" == *$'ADDITIONAL_CLAUDE_MD=\n'* ]]
[[ "$managed_inherited_chrome" == *$'PROXY_TOKEN_SET=\n'* ]]

FAKE_CLAUDE_HELP_NO_MODEL=1 run_wrapper --version >/dev/null
FAKE_CLAUDE_HELP_NO_MODEL=1 run_wrapper update >/dev/null
CLAUDEX_NODE_BIN=relative/node run_wrapper --version >/dev/null
CLAUDEX_NODE_BIN=relative/node run_wrapper update >/dev/null
if self_update_status=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_NODE_BIN=relative/node \
    CLAUDEX_SELF_UPDATE_HELPER="$root/self-update" "$root/claudex" self-update --status 2>&1); then
  self_update_status_code=0
else
  self_update_status_code=$?
fi
[[ "$self_update_status_code" == 1 ]]
[[ "$self_update_status" != *'CLAUDEX_NODE_BIN'* ]]

prompt_flag_output=$(run_wrapper --print --terra)
[[ "$prompt_flag_output" == *' --print --terra'* ]]
[[ "$prompt_flag_output" != *'--model gpt-5.6-terra'* ]]
option_value_output=$(run_wrapper --append-system-prompt --manual --print test-prompt)
[[ "$option_value_output" == *'--append-system-prompt --manual --print test-prompt'* ]]

doctor_output=$(run_wrapper --doctor)
[[ "$doctor_output" == *'CLIProxyAPI: CLIProxyAPI test'* ]]
[[ "$doctor_output" == *'Default permission mode: auto'* ]]
[[ "$doctor_output" == *'Auto mode classifier: gpt-5.6-terra'* ]]
[[ "$doctor_output" == *'Auto mode provider: Codex/OpenAI through the authenticated loopback bridge'* ]]
[[ "$doctor_output" == *'Delegated models: native routing for each agent (Sol is reserved for the leader)'* ]]
[[ "$doctor_output" == *'Managed agents: Terra (high), Luna (medium)'* ]]
[[ "$doctor_output" == *'Agent concurrency: 3'* ]]
[[ "$doctor_output" == *'Task lifecycle: owned by Sol with final response reconciliation'* ]]
[[ "$doctor_output" == *'API retries: 15'* ]]
[[ "$doctor_output" == *'Context window: 400000 tokens'* ]]
[[ "$doctor_output" == *'Automatic compaction window: 280000 tokens (precompute enabled)'* ]]
[[ "$doctor_output" == *'Context status: stable session (transient zero suppressed)'* ]]
[[ "$doctor_output" == *'Codex usage: status line refresh every 300s'* ]]
[[ "$doctor_output" == *'Rendering: stable mode with native terminal cursor'* ]]
[[ "$doctor_output" == *'Codex authentication: ready (shared ChatGPT session)'* ]]
[[ "$doctor_output" == *'Claude Code updates: on'* ]]
[[ "$doctor_output" == *'Plan mode policy: conservative'* ]]
[[ "$doctor_output" == *'Terminal UI: fullscreen (launch command hidden while Claudex is open)'* ]]
[[ "$doctor_output" == *'Header model name: GPT-5.6 Sol'* ]]
[[ "$doctor_output" == *'Mouse pointer: pointer'* ]]
[[ "$doctor_output" == *'gpt-5.6-terra: advertised'* ]]
[[ "$doctor_output" != *'extra version detail'* ]]

cp "$tmp/home/.config/claudex/settings.json" "$tmp/settings-before-unknown.json"
jq '.model = "gpt-unrecognized"' "$tmp/settings-before-unknown.json" > "$tmp/home/.config/claudex/settings.json"
unknown_doctor=$(run_wrapper --doctor)
[[ "$unknown_doctor" == *'Saved model: gpt-unrecognized (gpt-unrecognized)'* ]]
[[ "$unknown_doctor" == *'Header model name: gpt-unrecognized'* ]]
mv "$tmp/settings-before-unknown.json" "$tmp/home/.config/claudex/settings.json"

mv "$tmp/bin/claude" "$tmp/bin/claude.off"
if HOME="$tmp/home" PATH="$tmp/bin:/opt/homebrew/bin:/usr/bin:/bin" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  "$root/claudex" --doctor >"$tmp/no-claude.out" 2>"$tmp/no-claude.err"; then
  printf '%s\n' 'expected doctor without Claude Code to fail' >&2
  exit 1
fi
mv "$tmp/bin/claude.off" "$tmp/bin/claude"
grep -F 'Claude Code was not found' "$tmp/no-claude.err" >/dev/null

usage_output=$(run_wrapper --usage-limit)
[[ "$usage_output" == *'Codex usage limits (Pro plan)'* ]]
[[ "$usage_output" == *'Codex 7-day: 18% remaining (82% used)'* ]]
[[ "$usage_output" == *'GPT-5.3-Codex-Spark 7-day: 100% remaining (0% used)'* ]]
[[ "$usage_output" == *'Rate-limit reset credits: 1'* ]]
[[ "$usage_output" != *'secret-access-token'* ]]
[[ "$usage_output" != *'private@example.com'* ]]
jq -e '
  .plan_type == "pro"
  and .rate_limit.primary_window.used_percent == 82
  and (.user_id | not)
  and (.account_id | not)
  and (.email | not)
  and (.access_token | not)
' "$tmp/home/.config/claudex/usage-cache/limits.json" >/dev/null
if [[ "$(uname -s)" == Darwin ]]; then
  cache_mode=$(stat -f '%Lp' "$tmp/home/.config/claudex/usage-cache/limits.json")
  cache_dir_mode=$(stat -f '%Lp' "$tmp/home/.config/claudex/usage-cache")
else
  cache_mode=$(stat -c '%a' "$tmp/home/.config/claudex/usage-cache/limits.json")
  cache_dir_mode=$(stat -c '%a' "$tmp/home/.config/claudex/usage-cache")
fi
[[ "$cache_mode" == 600 ]]
[[ "$cache_dir_mode" == 700 ]]

fallback_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  FAKE_USAGE_FAIL=1 CLAUDEX_USAGE_SOURCE=web "$root/claudex" --usage-limit 2>&1)
[[ "$fallback_output" == *'live refresh failed; showing the last cached snapshot'* ]]
[[ "$fallback_output" == *'Codex 7-day: 18% remaining (82% used)'* ]]

appserver_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  FAKE_USAGE_FAIL=1 "$root/claudex" --usage-limit)
[[ "$appserver_output" == *'Codex 7-day: 16% remaining (84% used)'* ]]
[[ "$appserver_output" == *'Source: app-server'* ]]
[[ "$appserver_output" == *'Warning: Codex capacity is at or below the configured 20% alert threshold.'* ]]

changed_schema_output=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  FAKE_USAGE_CHANGED=1 "$root/claudex" --usage-limit)
[[ "$changed_schema_output" == *'Source: app-server'* ]]
[[ "$changed_schema_output" == *'Codex 7-day: 16% remaining (84% used)'* ]]

cat > "$tmp/home/.cli-proxy-api/codex-alt.json" <<'EOF'
{"type":"codex","access_token":"alternate-secret","account_id":"account-alt","email":"alternate@example.com"}
EOF
accounts_output=$(run_wrapper --accounts)
[[ "$accounts_output" == *'private@example.com'* ]]
[[ "$accounts_output" == *'alternate@example.com'* ]]
selected_output=$(run_wrapper --account private@example.com)
[[ "$selected_output" == *'Selected Codex usage account: private@example.com'* ]]
[[ "$(<"$tmp/home/.config/claudex/codex-usage-account")" == codex-test.json ]]
auto_account_output=$(run_wrapper --account auto)
[[ "$auto_account_output" == *'automatic'* ]]
[[ ! -e "$tmp/home/.config/claudex/codex-usage-account" ]]
[[ ! -e "$tmp/home/.config/claudex/usage-cache/summary" ]]
FAKE_USAGE_FAIL=1 run_wrapper --usage-limit >/dev/null

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_PERMISSION_MODE=broken "$root/claudex" >/dev/null 2>&1; then
  printf '%s\n' 'expected invalid permission mode to fail' >&2
  exit 1
fi
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_AUTO_MODE_MODEL=claude-sonnet-5 "$root/claudex" >/dev/null 2>&1; then
  printf '%s\n' 'expected Anthropic auto-mode classifier override to fail' >&2
  exit 1
fi

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_AUTO_COMPACT_WINDOW=99999 "$root/claudex" >/dev/null 2>&1; then
  printf '%s\n' 'expected invalid auto-compact window to fail' >&2
  exit 1
fi

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_MOUSE_POINTER_SHAPE=beam "$root/claudex" >/dev/null 2>&1; then
  printf '%s\n' 'expected invalid mouse pointer shape to fail' >&2
  exit 1
fi

if [[ "$(uname -s)" == Darwin ]]; then
  cursor_output=$(script -q /dev/null env \
    HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
    "$root/claudex" --luna cursor-test)
  [[ "$cursor_output" == *$'\033]22;pointer\033\\'* ]]
  [[ "$cursor_output" == *$'\033]22;default\033\\'* ]]
fi

status_output=$(printf '%s\n' '{"session_id":"stable-session","model":{"id":"gpt-5.6-sol"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":42.9,"total_input_tokens":171600,"context_window_size":400000}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline" 2>"$tmp/statusline.stderr")
[[ ! -s "$tmp/statusline.stderr" ]]
[[ "$status_output" == *'GPT-5.6 Sol'* ]]
[[ "$status_output" == *'xhigh effort'* ]]
[[ "$status_output" == *'42% context'* ]]
[[ "$status_output" == *'Codex 7d 16% left'* ]]
[[ "$status_output" != *$'\033]0;'* ]]

hostile_status=$(printf '%s\n' '{"session_id":"hostile-session","model":{"id":"hostile\u001b]0;MODEL-OSC\u0007\u009d0;MODEL-C1-OSC\u009c\u001b[31mMODEL-CSI\u001b[0m\u009b31mMODEL-C1\u061cMODEL-ALM\u200eMODEL-LRM\u200fMODEL-RLM\u202eMODEL-BIDI"},"effort":{"level":"high\u001b]8;;https://attacker.invalid\u0007max\u001b]8;;\u0007"},"context_window":{"used_percentage":5}}' | \
  CLAUDEX_USAGE_DISPLAY=off CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$hostile_status" == $'\033[38;5;81mClaudex\033[0m · \033[1mhostile\033[0m · high effort · 5% context' ]]
[[ "$hostile_status" != *'MODEL-OSC'* && "$hostile_status" != *'MODEL-C1-OSC'* && "$hostile_status" != *'https://attacker.invalid'* ]]
hostile_unstyled=${hostile_status//$'\033[38;5;81m'/}
hostile_unstyled=${hostile_unstyled//$'\033[1m'/}
hostile_unstyled=${hostile_unstyled//$'\033[0m'/}
[[ "$hostile_unstyled" != *$'\033'* && "$hostile_unstyled" != *$'\007'* && "$hostile_unstyled" != *$'\302\233'* ]]
[[ "$hostile_unstyled" != *$'\330\234'* && "$hostile_unstyled" != *$'\342\200\216'* && "$hostile_unstyled" != *$'\342\200\217'* && "$hostile_unstyled" != *$'\342\200\256'* ]]

safe_unicode_status=$(printf '%s\n' '{"session_id":"safe-label-session","model":{"id":"safe-\u6a21\u578b"},"effort":{"level":"future-tier"},"context_window":{"used_percentage":6}}' | \
  CLAUDEX_USAGE_DISPLAY=off CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$safe_unicode_status" == *$'\033[1msafe-模型\033[0m · future-tier effort · 6% context' ]]

suffix_only_status=$(printf '%s\n' '{"session_id":"suffix-only-session","model":{"id":"\u001b]0;ignored\u0007gpt-5.6-sol","display_name":"safe fallback"},"effort":{"level":"\u001b]0;ignored\u0007max"},"context_window":{"used_percentage":7}}' | \
  CLAUDEX_USAGE_DISPLAY=off CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$suffix_only_status" == $'\033[38;5;81mClaudex\033[0m · \033[1msafe fallback\033[0m · adaptive effort · 7% context' ]]

# Use byte escapes rather than locale-sensitive \u escapes. Bash intentionally
# leaves \u escapes literal in a plain C locale, which would turn this control-
# sequence fixture into printable text and produce a false sanitizer failure.
printf '%s\n' $'safe summary \033]0;CACHE-OSC\007 \302\2350;CACHE-C1-OSC\302\234 \033[31mCACHE-CSI\033[0m \302\23331mCACHE-C1 \342\200\256CACHE-BIDI' \
  > "$tmp/home/.config/claudex/usage-cache/summary"
date +%s > "$tmp/home/.config/claudex/usage-cache/last-success"
hostile_cache_status=$(printf '%s\n' '{"session_id":"hostile-cache","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":5}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$hostile_cache_status" == *'safe summary'* ]]
[[ "$hostile_cache_status" != *'CACHE-OSC'* && "$hostile_cache_status" != *'CACHE-C1-OSC'* ]]
hostile_cache_unstyled=${hostile_cache_status//$'\033[38;5;81m'/}
hostile_cache_unstyled=${hostile_cache_unstyled//$'\033[1m'/}
hostile_cache_unstyled=${hostile_cache_unstyled//$'\033[0m'/}
[[ "$hostile_cache_unstyled" != *$'\033'* && "$hostile_cache_unstyled" != *$'\007'* && "$hostile_cache_unstyled" != *$'\302\233'* && "$hostile_cache_unstyled" != *$'\342\200\256'* ]]

status_refresh_config="$tmp/status-refresh-private-env"
status_refresh_helper="$tmp/status-refresh-private-env-helper"
status_refresh_log="$tmp/status-refresh-private-env.log"
mkdir -p "$status_refresh_config"
cat > "$status_refresh_helper" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  "MANTLE=${ANTHROPIC_BEDROCK_MANTLE_BASE_URL:-}" \
  "VERTEX_PROJECT=${ANTHROPIC_VERTEX_PROJECT_ID:-}" \
  "FOUNDRY_RESOURCE=${ANTHROPIC_FOUNDRY_RESOURCE:-}" \
  "FOUNDRY_API_KEY=${ANTHROPIC_FOUNDRY_API_KEY:-}" \
  > "$STATUS_REFRESH_PRIVATE_ENV_LOG"
EOF
chmod +x "$status_refresh_helper"
printf '%s\n' '{"session_id":"private-refresh","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":5}}' | \
  CLAUDE_CONFIG_DIR="$status_refresh_config" CLAUDEX_USAGE_LIMIT_BIN="$status_refresh_helper" \
  STATUS_REFRESH_PRIVATE_ENV_LOG="$status_refresh_log" \
  ANTHROPIC_BEDROCK_MANTLE_BASE_URL='https://mantle.private.invalid' \
  ANTHROPIC_VERTEX_PROJECT_ID='private-vertex-project' \
  ANTHROPIC_FOUNDRY_RESOURCE='private-foundry-resource' \
  ANTHROPIC_FOUNDRY_API_KEY='private-foundry-secret' \
  "$root/statusline" >/dev/null
for _ in {1..100}; do [[ -s "$status_refresh_log" ]] && break; sleep 0.02; done
[[ "$(<"$status_refresh_log")" == $'MANTLE=\nVERTEX_PROJECT=\nFOUNDRY_RESOURCE=\nFOUNDRY_API_KEY=' ]]

printf '%s\n' 'Codex 7d 16% left · Review 7d 9% left · Extra-long-capacity-window 30d 8% left' \
  > "$tmp/home/.config/claudex/usage-cache/summary"
date +%s > "$tmp/home/.config/claudex/usage-cache/last-success"
narrow_status=$(printf '%s\n' '{"session_id":"narrow-session","model":{"id":"gpt-5.6-sol"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":42.9}}' | \
  CLAUDEX_STATUSLINE_COLUMNS=40 CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
narrow_plain=$(printf '%s' "$narrow_status" | sed $'s/\033\\[[0-9;]*m//g')
[[ ${#narrow_plain} -le 40 ]]
[[ "$narrow_plain" == *'GPT-5.6 Sol'* ]]
[[ "$narrow_plain" == *'42% context'* ]]
[[ "$narrow_plain" != *'Extra-long-capacity-window'* ]]
[[ "$narrow_status" == *$'\033[38;5;81mClaudex\033[0m'* ]]

tiny_status=$(printf '%s\n' '{"session_id":"tiny-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":42.9}}' | \
  CLAUDEX_STATUSLINE_COLUMNS=18 CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
tiny_plain=$(printf '%s' "$tiny_status" | sed $'s/\033\\[[0-9;]*m//g')
[[ ${#tiny_plain} -le 18 ]]
[[ "$tiny_plain" == *'…' ]]

solplan_settings="$tmp/home/.config/claudex/settings.json"
solplan_settings_backup="$tmp/settings-before-solplan.json"
cp "$solplan_settings" "$solplan_settings_backup"
jq '.model = "opusplan"' "$solplan_settings_backup" > "$solplan_settings"
solplan_status=$(printf '%s\n' '{"session_id":"solplan-session","model":{"id":"gpt-5.6-terra"},"effort":{"level":"high"},"context_window":{"used_percentage":12}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$solplan_status" == *'GPT-5.6 Solplan'* ]]
mv "$solplan_settings_backup" "$solplan_settings"

ultracode_status=$(printf '%s\n' '{"session_id":"ultracode-session","model":{"id":"gpt-5.6-sol"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":10,"total_input_tokens":40000,"context_window_size":400000}}' | \
  CLAUDEX_SESSION_MODE=ultracode CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$ultracode_status" == *'ultracode effort'* ]]

transient_status=$(printf '%s\n' '{"session_id":"stable-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":0,"context_window_size":400000,"current_usage":null}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$transient_status" == *'42% context'* ]]
[[ "$transient_status" != *'0% context'* ]]

nonpersistent_status=$(printf '%s\n' '{"session_id":"stable-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":0,"context_window_size":400000,"current_usage":null}}' | \
  CLAUDEX_NO_SESSION_PERSISTENCE=1 CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$nonpersistent_status" != *'% context'* ]]
printf '%s\n' '{"session_id":"ephemeral-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":25}}' | \
  CLAUDEX_NO_SESSION_PERSISTENCE=1 CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline" >/dev/null
[[ ! -e "$tmp/home/.config/claudex/statusline-cache/ephemeral-session" ]]

fresh_status=$(printf '%s\n' '{"session_id":"fresh-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":0,"context_window_size":400000,"current_usage":null}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$fresh_status" != *'% context'* ]]

small_status=$(printf '%s\n' '{"session_id":"small-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":100,"context_window_size":400000}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$small_status" == *'<1% context'* ]]

invalid_status=$(printf '%s\n' 'not-json' | CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$invalid_status" == *'Unknown model'* ]]

node "$root/scripts/check-preload.mjs"
node "$root/tests/windows-private-environment.test.cjs"

solplan_input_regression=$(CLAUDEX_TEST_TTY_INPUT=1 node - "$root/preload.cjs" <<'NODE'
const assert = require('node:assert/strict');
const preload = require(process.argv[2]);
assert.equal(preload.rewriteSolplanInput('/model solplan \r'), '/model opusplan\r');
assert.equal(process.env.CLAUDEX_MODEL_MODE, 'solplan');
assert.equal(preload.rewriteSolplanInput('/model gpt-5.6-terra\r'), '/model gpt-5.6-terra\r');
assert.equal(process.env.CLAUDEX_MODEL_MODE, undefined);
preload.rewriteSolplanInput('/model solplan');
preload.rewriteSolplanInput('\x03');
assert.equal(preload.rewriteSolplanInput('\r'), '\r');
process.stdout.write('ok');
NODE
)
[[ "$solplan_input_regression" == ok ]]

[[ "$(node "$root/bin/claudex-package.mjs" --package-version)" == "$(node -p "require('$root/package.json').version")" ]]

install_home="$tmp/install home"
mkdir -p "$install_home/.codex"
cp "$tmp/home/.codex/auth.json" "$install_home/.codex/auth.json"
install_output=$(HOME="$install_home" PATH="$tmp/bin:$PATH" \
  CLAUDEX_PROXY_TOKEN='installer-test-token' \
  CLAUDEX_PROXY_CONFIG="$install_home/.config/claudex/cliproxyapi.yaml" \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
  "$root/install.sh")
[[ -x "$install_home/.local/bin/claudex" ]]
[[ -x "$install_home/.config/claudex/statusline" ]]
[[ -x "$install_home/.config/claudex/usage-limit" ]]
[[ -x "$install_home/.config/claudex/codex-session" ]]
[[ -r "$install_home/.config/claudex/preload.cjs" ]]
[[ -x "$install_home/.config/claudex/self-update" ]]
[[ -r "$install_home/.config/claudex/skills/usage-limit/SKILL.md" ]]
[[ -r "$install_home/.config/claudex/skill-bridge.cjs" ]]
[[ -r "$install_home/.config/claudex/settings.json" ]]
[[ -r "$install_home/.config/claudex/env" ]]
[[ -r "$install_home/.config/claudex/install.json" ]]
[[ "$install_output" != *'installer-test-token'* ]]
printf -v expected_statusline '%q' "$install_home/.config/claudex/statusline"
jq -e --arg expected "/usr/bin/env bash $expected_statusline" \
  '.statusLine.command == $expected and .tui == "fullscreen"' \
  "$install_home/.config/claudex/settings.json" >/dev/null
installed_env=$(<"$install_home/.config/claudex/env")
[[ "$installed_env" == *'CLAUDEX_PROXY_TOKEN=installer-test-token'* ]]
[[ "$installed_env" == *'CLAUDEX_PROXY_CONFIG='* ]]
[[ "$installed_env" == *'CLAUDEX_PROXY_URL=http://127.0.0.1:8318'* ]]
[[ "$installed_env" == *'CLAUDEX_CODEX_AUTH_DIR='* ]]
[[ -r "$install_home/.config/claudex/cliproxyapi.yaml" ]]
[[ "$(<"$install_home/.config/claudex/cliproxyapi.yaml")" == *'host: "127.0.0.1"'* ]]
[[ "$(<"$install_home/.config/claudex/cliproxyapi.yaml")" == *'port: 8318'* ]]
[[ "$(<"$install_home/.config/claudex/cliproxyapi.yaml")" == *'request-retry: 3'* ]]
[[ "$(<"$install_home/.config/claudex/cliproxyapi.yaml")" == *'transient-error-cooldown-seconds: 1'* ]]
[[ "$(<"$install_home/.config/claudex/cliproxyapi.yaml")" == *'bootstrap-retries: 2'* ]]
jq -e --arg version "$(node -p "require('$root/package.json').version")" \
  '.schema == 1 and .version == $version and .method == "git" and .repository == "BeamoINT/Claudex"' \
  "$install_home/.config/claudex/install.json" >/dev/null

# An explicit installer login always opens Codex login, even when the existing
# file-backed session is already valid.
explicit_login_log="$tmp/explicit-installer-login.log"
HOME="$install_home" PATH="$tmp/bin:$PATH" FAKE_CODEX_LOGIN_LOG="$explicit_login_log" \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
  "$root/install.sh" --login >/dev/null
[[ "$(wc -l < "$explicit_login_log" | tr -d ' ')" == 1 ]]

# A failure after env, proxy config, and managed-file activation restores the
# complete prior generation instead of leaving a mixed direct installation.
rollback_env_before=$(<"$install_home/.config/claudex/env")
rollback_proxy_before=$(<"$install_home/.config/claudex/cliproxyapi.yaml")
printf '%s\n' rollback-statusline-sentinel > "$install_home/.config/claudex/statusline"
if HOME="$install_home" PATH="$tmp/bin:$PATH" CLAUDEX_PROXY_TOKEN='must-not-survive' \
  CLAUDEX_INSTALL_METHOD=invalid CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
  "$root/install.sh" >"$tmp/installer-rollback.stdout" 2>"$tmp/installer-rollback.stderr"; then
  printf '%s\n' 'expected injected late installer failure' >&2
  exit 1
fi
grep -F 'restored the previous managed installation' "$tmp/installer-rollback.stderr" >/dev/null
[[ "$(<"$install_home/.config/claudex/env")" == "$rollback_env_before" ]]
[[ "$(<"$install_home/.config/claudex/cliproxyapi.yaml")" == "$rollback_proxy_before" ]]
[[ "$(<"$install_home/.config/claudex/statusline")" == rollback-statusline-sentinel ]]
[[ -z "$(find "$install_home/.config/claudex" -maxdepth 1 -name '.install-transaction.*' -print -quit)" ]]

# A durable transaction journal is recovered after an ungraceful process loss
# before a new installer generation is snapshotted.
crash_transaction="$install_home/.config/claudex/.install-transaction.crash-test"
mkdir -p "$crash_transaction/backup"
crash_targets=(
  "$install_home/.local/bin/claudex"
  "$install_home/.config/claudex/env"
  "$install_home/.config/claudex/cliproxyapi.yaml"
  "$install_home/.config/claudex/bin/cliproxyapi"
  "$install_home/.config/claudex/settings.json"
  "$install_home/.config/claudex/statusline"
  "$install_home/.config/claudex/usage-limit"
  "$install_home/.config/claudex/codex-session"
  "$install_home/.config/claudex/preload.cjs"
  "$install_home/.config/claudex/skill-bridge.cjs"
  "$install_home/.config/claudex/self-update"
  "$install_home/.config/claudex/skills/usage-limit/SKILL.md"
  "$install_home/.config/claudex/install.json"
)
: > "$crash_transaction/manifest"
for crash_index in "${!crash_targets[@]}"; do
  crash_target=${crash_targets[$crash_index]}
  if [[ -f "$crash_target" ]]; then
    cp -p "$crash_target" "$crash_transaction/backup/$crash_index"
    printf '1\t%s\n' "$crash_target" >> "$crash_transaction/manifest"
  else
    printf '0\t%s\n' "$crash_target" >> "$crash_transaction/manifest"
  fi
done
printf '%s\n' committing > "$crash_transaction/state"
printf '%s\n' 'CLAUDEX_PROXY_TOKEN=corrupted-crash-token' > "$install_home/.config/claudex/env"
recovery_output=$(HOME="$install_home" PATH="$tmp/bin:$PATH" \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 "$root/install.sh")
[[ "$recovery_output" == *'Recovered the previous interrupted Claudex installation'* ]]
[[ "$(<"$install_home/.config/claudex/env")" == *'CLAUDEX_PROXY_TOKEN=installer-test-token'* ]]
[[ ! -e "$crash_transaction" ]]

grep -F -- '--retry-connrefused' "$root/install.sh" >/dev/null
grep -F 'download_with_retry "$claude_installer"' "$root/install.sh" >/dev/null
grep -F 'download_with_retry "$archive" "$url"' "$root/install.sh" >/dev/null

custom_proxy_config="$tmp/custom-claudex-proxy.yaml"
custom_proxy_bin="$tmp/custom-claudex-proxy"
custom_auth_dir="$tmp/custom-claudex-auth"
awk -v proxy_config="$custom_proxy_config" -v proxy_bin="$custom_proxy_bin" -v auth_dir="$custom_auth_dir" '
  /^CLAUDEX_PROXY_URL=/ { print "CLAUDEX_PROXY_URL=http://127.0.0.1:9123"; next }
  /^CLAUDEX_PROXY_CONFIG=/ { print "CLAUDEX_PROXY_CONFIG=" proxy_config; next }
  /^CLAUDEX_PROXY_BIN=/ { print "CLAUDEX_PROXY_BIN=" proxy_bin; next }
  /^CLAUDEX_CODEX_AUTH_DIR=/ { print "CLAUDEX_CODEX_AUTH_DIR=" auth_dir; next }
  { print }
' "$install_home/.config/claudex/env" > "$tmp/installer-custom-env"
mv "$tmp/installer-custom-env" "$install_home/.config/claudex/env"
HOME="$install_home" PATH="$tmp/bin:$PATH" CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
  "$root/install.sh" >/dev/null
custom_installed_env=$(<"$install_home/.config/claudex/env")
[[ "$custom_installed_env" == *'CLAUDEX_PROXY_URL=http://127.0.0.1:9123'* ]]
[[ "$custom_installed_env" == *"CLAUDEX_PROXY_CONFIG=$custom_proxy_config"* ]]
[[ "$custom_installed_env" == *"CLAUDEX_PROXY_BIN=$custom_proxy_bin"* ]]
[[ "$custom_installed_env" == *"CLAUDEX_CODEX_AUTH_DIR=$custom_auth_dir"* ]]
[[ "$(<"$install_home/.config/claudex/cliproxyapi.yaml")" == *"auth-dir: \"$custom_auth_dir\""* ]]
invocation_proxy_config="$tmp/invocation-claudex-proxy.yaml"
invocation_proxy_bin="$tmp/invocation-claudex-proxy"
invocation_auth_dir="$tmp/invocation-claudex-auth"
HOME="$install_home" PATH="$tmp/bin:$PATH" \
  CLAUDEX_PROXY_TOKEN='invocation-test-token' CLAUDEX_PROXY_URL='http://127.0.0.1:9234' \
  CLAUDEX_PROXY_CONFIG="$invocation_proxy_config" CLAUDEX_PROXY_BIN="$invocation_proxy_bin" \
  CLAUDEX_CODEX_AUTH_DIR="$invocation_auth_dir" CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 \
  CLAUDEX_SKIP_SERVICE_START=1 "$root/install.sh" >/dev/null
invocation_installed_env=$(<"$install_home/.config/claudex/env")
[[ "$invocation_installed_env" == *'CLAUDEX_PROXY_TOKEN=invocation-test-token'* ]]
[[ "$invocation_installed_env" == *'CLAUDEX_PROXY_URL=http://127.0.0.1:9234'* ]]
[[ "$invocation_installed_env" == *"CLAUDEX_PROXY_CONFIG=$invocation_proxy_config"* ]]
[[ "$invocation_installed_env" == *"CLAUDEX_PROXY_BIN=$invocation_proxy_bin"* ]]
[[ "$invocation_installed_env" == *"CLAUDEX_CODEX_AUTH_DIR=$invocation_auth_dir"* ]]

# Changing only the managed loopback port migrates the matching managed URL,
# while a genuinely custom endpoint remains authoritative.
HOME="$install_home" PATH="$tmp/bin:$PATH" CLAUDEX_PROXY_PORT=9345 \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 "$root/install.sh" >/dev/null
port_migrated_env=$(<"$install_home/.config/claudex/env")
[[ "$port_migrated_env" == *'CLAUDEX_PROXY_URL=http://127.0.0.1:9345'* ]]
HOME="$install_home" PATH="$tmp/bin:$PATH" CLAUDEX_PROXY_PORT=9456 CLAUDEX_PROXY_URL='https://proxy.example.test' \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 "$root/install.sh" >/dev/null
custom_url_env=$(<"$install_home/.config/claudex/env")
[[ "$custom_url_env" == *'CLAUDEX_PROXY_URL=https://proxy.example.test'* ]]
if HOME="$install_home" PATH="$tmp/bin:$PATH" CLAUDEX_PROXY_PORT='invalid-port' \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 "$root/install.sh" >/dev/null 2>&1; then
  printf '%s\n' 'expected invalid installer proxy port to fail' >&2
  exit 1
fi

package_home="$tmp/package home"
mkdir -p "$package_home/.codex"
cp "$tmp/home/.codex/auth.json" "$package_home/.codex/auth.json"
package_setup_output=$(HOME="$package_home" PATH="$tmp/bin:$PATH" \
  CLAUDEX_INSTALL_METHOD=homebrew CLAUDEX_PROXY_TOKEN='package-test-token' CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 \
  CLAUDEX_SKIP_SERVICE_START=1 CLAUDEX_SKIP_AUTO_UPDATE=1 node "$root/bin/claudex-package.mjs" --package-setup)
[[ "$package_setup_output" != *'Add this directory to PATH:'* ]]
jq -e --arg version "$(node -p "require('$root/package.json').version")" \
  '.package == "claudex-codex" and .version == $version and .method == "homebrew"' \
  "$package_home/.config/claudex/package-manager.json" >/dev/null
[[ -x "$package_home/.config/claudex/package-bin/claudex" ]]
rm -f "$package_home/.config/claudex/preload.cjs"
HOME="$package_home" PATH="$tmp/bin:$PATH" \
  CLAUDEX_INSTALL_METHOD=homebrew CLAUDEX_PROXY_TOKEN='package-test-token' CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 \
  CLAUDEX_SKIP_SERVICE_START=1 CLAUDEX_SKIP_AUTO_UPDATE=1 node "$root/bin/claudex-package.mjs" --version >/dev/null
[[ -r "$package_home/.config/claudex/preload.cjs" ]]

package_conflict_home="$tmp/package conflict home"
package_conflict_bin="$tmp/package-manager-bin"
mkdir -p "$package_conflict_home/.codex" "$package_conflict_bin"
cp "$tmp/home/.codex/auth.json" "$package_conflict_home/.codex/auth.json"
ln -s "$root/bin/claudex-package.mjs" "$package_conflict_bin/claudex"
HOME="$package_conflict_home" PATH="$tmp/bin:$PATH" CLAUDEX_BIN_DIR="$package_conflict_bin" \
  CLAUDEX_INSTALL_METHOD=homebrew CLAUDEX_PROXY_TOKEN='package-conflict-token' CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 \
  CLAUDEX_SKIP_SERVICE_START=1 CLAUDEX_SKIP_AUTO_UPDATE=1 node "$root/bin/claudex-package.mjs" --package-setup >/dev/null
[[ "$(readlink "$package_conflict_bin/claudex")" == "$root/bin/claudex-package.mjs" ]]
[[ -x "$package_conflict_home/.config/claudex/package-bin/claudex" ]]

# A missing Codex CLI is installed into the user's normal ~/.local prefix, and
# an interactive installation performs the required official login exactly once.
codex_install_home="$tmp/codex install home"
codex_install_bin="$tmp/codex-install-bin"
mkdir -p "$codex_install_home/.config/claudex/bin" "$codex_install_home/.codex" "$codex_install_bin"
for command in claude curl; do ln -s "$tmp/bin/$command" "$codex_install_bin/$command"; done
ln -s "$(command -v jq)" "$codex_install_bin/jq"
ln -s "$(command -v node)" "$codex_install_bin/node"
cat > "$codex_install_bin/npm" <<'EOF'
#!/usr/bin/env bash
prefix=""
while (( $# > 0 )); do
  if [[ "$1" == --prefix ]]; then prefix="$2"; shift 2; continue; fi
  shift
done
[[ -n "$prefix" ]] || exit 2
mkdir -p "$prefix/bin"
cat > "$prefix/bin/codex" <<'CODEX'
#!/usr/bin/env bash
if [[ "${1:-}" == login && "${2:-}" == status ]]; then [[ -r "$HOME/.codex/auth.json" ]]; exit; fi
if [[ "${1:-}" == -c && "${3:-}" == login ]]; then
  mkdir -p "$HOME/.codex"
  printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"installed-access","refresh_token":"installed-refresh","account_id":"installed-account"}}' > "$HOME/.codex/auth.json"
  printf '%s\n' login >> "$FAKE_CODEX_LOGIN_LOG"
  exit 0
fi
exit 2
CODEX
chmod +x "$prefix/bin/codex"
EOF
cat > "$codex_install_home/.config/claudex/bin/cliproxyapi" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -version ]] && { printf '%s\n' 'Version: 7.2.80'; exit; }
exit 0
EOF
chmod +x "$codex_install_bin/npm" "$codex_install_home/.config/claudex/bin/cliproxyapi"
codex_login_log="$tmp/codex-install-login.log"
HOME="$codex_install_home" PATH="$codex_install_bin:/usr/bin:/bin" \
  FAKE_CODEX_LOGIN_LOG="$codex_login_log" CLAUDEX_TEST_INTERACTIVE_INSTALL=1 \
  CLAUDEX_SKIP_SERVICE_START=1 "$root/install.sh" >/dev/null
[[ -x "$codex_install_home/.local/bin/codex" ]]
[[ "$(wc -l < "$codex_login_log" | tr -d ' ')" == 1 ]]
[[ ! -e "$codex_install_home/.config/claudex/run/install.lock" ]]

# Archive updates from releases that predate the skill bridge set skip-deps.
# They must still be able to migrate a standalone-Codex installation that has
# no Node runtime instead of rolling back on every automatic update attempt.
node_migration_home="$tmp/node migration home"
node_migration_bin="$tmp/node-migration-bin"
mkdir -p "$node_migration_home/.config/claudex" "$node_migration_home/.codex" "$node_migration_bin"
cp "$tmp/home/.codex/auth.json" "$node_migration_home/.codex/auth.json"
for command in claude codex curl; do ln -s "$tmp/bin/$command" "$node_migration_bin/$command"; done
ln -s "$(command -v jq)" "$node_migration_bin/jq"
cat > "$node_migration_bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'install node' ]]
ln -sf "$FAKE_REAL_NODE" "$FAKE_NODE_MIGRATION_BIN/node"
printf '%s\n' "$*" >> "$FAKE_NODE_MIGRATION_LOG"
EOF
chmod +x "$node_migration_bin/brew"
cat > "$node_migration_home/.config/claudex/install.json" <<EOF
{"schema":1,"version":"1.4.4","method":"archive","binDir":"$node_migration_home/.local/bin","repository":"BeamoINT/Claudex"}
EOF
node_migration_log="$tmp/node-migration.log"
real_node_for_migration=$(command -v node)
HOME="$node_migration_home" PATH="$node_migration_bin:/usr/bin:/bin" \
  CLAUDEX_INSTALL_METHOD=archive CLAUDEX_PROXY_TOKEN='node-migration-token' \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
  FAKE_REAL_NODE="$real_node_for_migration" FAKE_NODE_MIGRATION_BIN="$node_migration_bin" \
  FAKE_NODE_MIGRATION_LOG="$node_migration_log" "$root/install.sh" >/dev/null
grep -Fx 'install node' "$node_migration_log" >/dev/null
[[ -r "$node_migration_home/.config/claudex/skill-bridge.cjs" ]]

# The website bootstrap executes only a checksum-valid, path-safe release and
# removes its extraction directory after the installer returns.
bootstrap_fixture="$tmp/bootstrap-fixture"
bootstrap_version=9.8.7
bootstrap_root="$bootstrap_fixture/claudex-$bootstrap_version"
bootstrap_tmp="$tmp/bootstrap-tmp"
mkdir -p "$bootstrap_root" "$bootstrap_tmp" "$tmp/bootstrap-bin"
printf '%s\n' '{"version":"9.8.7"}' > "$bootstrap_root/package.json"
for required in claudex codex-session settings.json; do : > "$bootstrap_root/$required"; done
cat > "$bootstrap_root/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${CLAUDEX_INSTALL_METHOD:-}:$*" > "$FAKE_BOOTSTRAP_INSTALL_LOG"
EOF
chmod +x "$bootstrap_root/install.sh"
(cd "$bootstrap_fixture" && tar -czf "claudex-$bootstrap_version.tar.gz" "claudex-$bootstrap_version")
bootstrap_archive="$bootstrap_fixture/claudex-$bootstrap_version.tar.gz"
bootstrap_digest=$(shasum -a 256 "$bootstrap_archive" | awk '{print $1}')
printf '%s  %s\n' "$bootstrap_digest" "claudex-$bootstrap_version.tar.gz" > "$bootstrap_fixture/SHA256SUMS"
cat > "$tmp/bootstrap-bin/curl" <<'EOF'
#!/usr/bin/env bash
output=""; url=""
while (( $# > 0 )); do
  case "$1" in --output) output="$2"; shift 2 ;; --write-out) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
if [[ "$output" == /dev/null ]]; then printf '%s' 'https://github.com/BeamoINT/Claudex/releases/tag/v9.8.7'; exit; fi
case "$url" in */SHA256SUMS) cp "$FAKE_BOOTSTRAP_FIXTURE/SHA256SUMS" "$output" ;; *) cp "$FAKE_BOOTSTRAP_FIXTURE/claudex-9.8.7.tar.gz" "$output" ;; esac
EOF
chmod +x "$tmp/bootstrap-bin/curl"
bootstrap_install_log="$tmp/bootstrap-install.log"
PATH="$tmp/bootstrap-bin:/usr/bin:/bin" TMPDIR="$bootstrap_tmp" \
  FAKE_BOOTSTRAP_FIXTURE="$bootstrap_fixture" FAKE_BOOTSTRAP_INSTALL_LOG="$bootstrap_install_log" \
  "$root/bootstrap.sh" --login >/dev/null
[[ "$(<"$bootstrap_install_log")" == 'archive:--login' ]]
[[ -z "$(find "$bootstrap_tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]
printf x >> "$bootstrap_archive"
if PATH="$tmp/bootstrap-bin:/usr/bin:/bin" TMPDIR="$bootstrap_tmp" \
  FAKE_BOOTSTRAP_FIXTURE="$bootstrap_fixture" FAKE_BOOTSTRAP_INSTALL_LOG="$bootstrap_install_log" \
  "$root/bootstrap.sh" >/dev/null 2>&1; then
  printf '%s\n' 'expected tampered bootstrap archive to fail' >&2
  exit 1
fi

auth_status=$(run_wrapper --auth-status)
[[ "$auth_status" == *'Codex authentication: ready (shared ChatGPT session)'* ]]

# A Codex Desktop/CLI account change is picked up while Claudex is still open.
mkdir -p "$tmp/home/.config/claudex/usage-cache/refresh.lock"
printf '%s\n' old > "$tmp/home/.config/claudex/usage-cache/limits.json"
printf '%s\n' codex-test.json > "$tmp/home/.config/claudex/codex-usage-account"
sleep 10 & auth_watch_parent=$!
auth_watch_ready="$tmp/auth-watch-ready"
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CODEX_AUTH_DIR="$tmp/home/.cli-proxy-api" \
  CLAUDEX_AUTH_WATCH_SECONDS=1 CLAUDEX_AUTH_WATCH_READY_FILE="$auth_watch_ready" \
  "$tmp/home/.config/claudex/codex-session" watch "$auth_watch_parent" &
auth_watcher=$!
for _ in {1..50}; do [[ -s "$auth_watch_ready" ]] && break; sleep 0.02; done
[[ -s "$auth_watch_ready" ]]
cat > "$tmp/home/.codex/auth.json" <<'EOF'
{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T02:00:00Z","tokens":{"access_token":"codex-switched-access","refresh_token":"codex-switched-refresh","id_token":"codex-switched-id","account_id":"account-switched"}}
EOF
for _ in {1..50}; do
  if jq -e '.account_id == "account-switched" and .access_token == "codex-switched-access"' \
      "$tmp/home/.cli-proxy-api/codex-claudex-managed.json" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
jq -e '.account_id == "account-switched" and .access_token == "codex-switched-access"' \
  "$tmp/home/.cli-proxy-api/codex-claudex-managed.json" >/dev/null
[[ ! -e "$tmp/home/.config/claudex/codex-usage-account" ]]
[[ ! -e "$tmp/home/.config/claudex/usage-cache/limits.json" ]]
kill "$auth_watch_parent" 2>/dev/null || true
wait "$auth_watch_parent" 2>/dev/null || true
wait "$auth_watcher"

# Restore the fixture account for the remaining lifecycle checks.
cat > "$tmp/home/.codex/auth.json" <<'EOF'
{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T03:00:00Z","tokens":{"access_token":"codex-source-access","refresh_token":"codex-source-refresh","id_token":"codex-source-id","account_id":"account-test"}}
EOF
HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CODEX_AUTH_DIR="$tmp/home/.cli-proxy-api" \
  "$tmp/home/.config/claudex/codex-session" sync

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 FAKE_CODEX_LOGGED_OUT=1 \
  "$root/claudex" --sol test-prompt >"$tmp/logged-out.stdout" 2>"$tmp/logged-out.stderr"; then
  printf '%s\n' 'expected logged-out Codex session to fail' >&2
  exit 1
fi
grep -F 'Codex is logged out. Run `codex login` (or `claudex --login`) and retry.' "$tmp/logged-out.stderr" >/dev/null

bridge_file="$tmp/home/.cli-proxy-api/codex-claudex-managed.json"
cat > "$bridge_file" <<'EOF'
{"type":"codex","access_token":"disabled-access","refresh_token":"disabled-refresh","account_id":"account-test","last_refresh":"2099-01-01T00:00:00Z","disabled":true,"expired":true}
EOF
run_wrapper --auth-status >/dev/null
jq -e '.access_token == "codex-source-access" and .disabled == false and .expired == false' "$bridge_file" >/dev/null || {
  printf '%s\n' 'disabled bridge credential was not repaired' >&2
  jq '{access_token, disabled, expired, last_refresh}' "$bridge_file" >&2
  exit 1
}

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" FAKE_CODEX_LOGOUT_EXIT=9 \
  "$root/claudex" --logout >/dev/null 2>&1; then
  printf '%s\n' 'expected failed Codex logout to propagate' >&2
  exit 1
fi
[[ ! -e "$bridge_file" ]]

cat > "$tmp/home/.cli-proxy-api/codex-disabled.json" <<'EOF'
{"type":"codex","access_token":"disabled","account_id":"disabled-account","email":"disabled@example.com","disabled":true}
EOF
disabled_accounts=$(run_wrapper --accounts)
[[ "$disabled_accounts" == *'disabled@example.com (disabled)'* ]]
if run_wrapper --account disabled@example.com >/dev/null 2>&1; then
  printf '%s\n' 'expected disabled usage account selection to fail' >&2
  exit 1
fi

foreign_resume_output=$(FAKE_CLAUDE_RESUME=1 FAKE_FOREIGN_RESUME=1 CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper)
[[ "$foreign_resume_output" == *'claudex --resume 123e4567-e89b-12d3-a456-426614174000'* ]]
[[ "$foreign_resume_output" != *'claudex --resume 223e4567-e89b-12d3-a456-426614174000'* ]]
ambiguous_resume_output=$(FAKE_CLAUDE_RESUME=1 FAKE_SAME_CWD_RESUME=1 CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper)
[[ "$ambiguous_resume_output" != *'Resume this session with Claudex:'* ]]
[[ "$ambiguous_resume_output" != *'claudex --resume 323e4567-e89b-12d3-a456-426614174000'* ]]

direct_resume_output=$(FAKE_CLAUDE_RESUME=1 CLAUDEX_TEST_TTY_OUTPUT=1 run_wrapper --claude-chrome)
[[ "$direct_resume_output" == *'claudex --claude-chrome --resume 123e4567-e89b-12d3-a456-426614174000'* ]]

update_home="$tmp/update-home"
mkdir -p "$update_home/.config/claudex" "$update_home/.codex" "$update_home/.cli-proxy-api"
cp "$root/settings.json" "$update_home/.config/claudex/settings.json"
cp "$root/codex-session" "$update_home/.config/claudex/codex-session"
cp "$root/preload.cjs" "$update_home/.config/claudex/preload.cjs"
cp "$root/skill-bridge.cjs" "$update_home/.config/claudex/skill-bridge.cjs"
chmod +x "$update_home/.config/claudex/codex-session"
cp "$tmp/home/.codex/auth.json" "$update_home/.codex/auth.json"
printf '%s\n' 'CLAUDEX_PROXY_TOKEN=test-token' "CLAUDEX_CODEX_AUTH_DIR=$update_home/.cli-proxy-api" > "$update_home/.config/claudex/env"
update_dir="$update_home/.config/claudex/update"
direct_update_log="$tmp/direct-update.log"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_FORCE_HARDLINK_FAILURE=1 \
  FAKE_UPDATE_LOG="$direct_update_log" "$root/claudex" --claude-chrome --version >/dev/null
for _ in {1..1000}; do [[ -s "$update_dir/last-success" && ! -e "$update_dir/lock" ]] && break; sleep 0.02; done
[[ -s "$direct_update_log" && -s "$update_dir/last-success" ]]
[[ ! -e "$update_dir/lock" ]] && ! compgen -G "$update_dir/lock.quarantine.*" >/dev/null

# State writers retain an old live owner's lock and reclaim only dead owners.
state_lock="$update_home/.config/claudex/run/model-display.lock"
mkdir -p "$state_lock"
printf 'pid=%s\nidentity=%s\nnonce=live-state-owner\n' "$$" 'test-process-identity' > "$state_lock/owner"
touch -t 200001010000 "$state_lock"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity "$root/claudex" --claude-chrome --version >/dev/null
grep -F 'nonce=live-state-owner' "$state_lock/owner" >/dev/null
rm -rf "$state_lock"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_FORCE_PUBLICATION_FAILURE=1 \
  "$root/claudex" --claude-chrome --version >/dev/null
[[ ! -e "$state_lock" ]] && ! compgen -G "$state_lock.quarantine.*" >/dev/null
mkdir -p "$state_lock"
printf 'pid=99999999\nidentity=dead-state-owner\nnonce=dead-state-owner\n' > "$state_lock/owner"
touch -t 200001010000 "$state_lock"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity "$root/claudex" --claude-chrome --version >/dev/null
[[ ! -e "$state_lock" ]]
mkdir -p "$state_lock"
printf 'pid=%s\nidentity=\nnonce=unverifiable-reused-owner\n' "$$" > "$state_lock/owner"
touch -t 200001010000 "$state_lock"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
  CLAUDEX_TEST_PS_FAIL=1 "$root/claudex" --claude-chrome --version >/dev/null
grep -F 'nonce=unverifiable-reused-owner' "$state_lock/owner" >/dev/null
rm -rf "$state_lock"

# Orchestrate both historical ABA windows. A paused creator may not overwrite a
# later B generation, and a stale X remover that moves Y may not let Z enter.
aba_base=(HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_SKIP_AUTO_UPDATE=1 CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY=test-process-identity \
  CLAUDEX_TEST_LOCK_MATCH=model-display.lock)
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/aba-a-mkdir" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/aba-a-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
aba_a=$!
for _ in {1..200}; do [[ -e "$tmp/aba-a-mkdir" ]] && break; sleep 0.02; done
touch -t 200001010000 "$state_lock"
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/aba-b-publish" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/aba-b-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
aba_b=$!
for _ in {1..300}; do [[ -e "$tmp/aba-b-publish" ]] && break; sleep 0.02; done
aba_b_nonce=$(awk -F= '$1 == "nonce" { print $2; exit }' "$state_lock/owner")
: > "$tmp/aba-a-continue"
wait "$aba_a"
[[ "$(awk -F= '$1 == "nonce" { print $2; exit }' "$state_lock/owner")" == "$aba_b_nonce" ]]
: > "$tmp/aba-b-continue"
wait "$aba_b"

rm -rf "$state_lock"
mkdir -p "$state_lock"
printf '%s\n' x > "$state_lock/generation"
printf 'pid=99999999\nidentity=dead\nnonce=x\n' > "$state_lock/owner"
touch -t 200001010000 "$state_lock"
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_BEFORE_RENAME_READY="$tmp/aba-x-before" \
  CLAUDEX_TEST_LOCK_BEFORE_RENAME_CONTINUE="$tmp/aba-x-before-continue" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_READY="$tmp/aba-x-after" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_CONTINUE="$tmp/aba-x-after-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
aba_x=$!
for _ in {1..200}; do [[ -e "$tmp/aba-x-before" ]] && break; sleep 0.02; done
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/aba-y-publish" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/aba-y-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
aba_y=$!
for _ in {1..300}; do [[ -e "$tmp/aba-y-publish" ]] && break; sleep 0.02; done
aba_y_nonce=$(awk -F= '$1 == "nonce" { print $2; exit }' "$state_lock/owner")
: > "$tmp/aba-x-before-continue"
for _ in {1..200}; do [[ -e "$tmp/aba-x-after" ]] && break; sleep 0.02; done
env "${aba_base[@]}" "$root/claudex" --claude-chrome --version >/dev/null &
aba_z=$!
wait "$aba_z"
[[ "$(awk -F= '$1 == "nonce" { print $2; exit }' "$state_lock/owner")" == "$aba_y_nonce" ]]
: > "$tmp/aba-x-after-continue"
wait "$aba_x"
: > "$tmp/aba-y-continue"
wait "$aba_y"

# If X dies or pauses after moving Y, Y itself restores and retains its exact
# generation instead of timing out behind its own live quarantine barrier.
rm -rf "$state_lock" "$state_lock".quarantine.*
mkdir -p "$state_lock"
printf '%s\n' x-self > "$state_lock/generation"
printf 'pid=99999999\nidentity=dead\nnonce=x-self\n' > "$state_lock/owner"
touch -t 200001010000 "$state_lock"
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_BEFORE_RENAME_READY="$tmp/self-x-before" \
  CLAUDEX_TEST_LOCK_BEFORE_RENAME_CONTINUE="$tmp/self-x-before-continue" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_READY="$tmp/self-x-after" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_CONTINUE="$tmp/self-x-after-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
self_x=$!
for _ in {1..200}; do [[ -e "$tmp/self-x-before" ]] && break; sleep 0.02; done
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/self-y-publish" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/self-y-continue" \
  CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE="$tmp/self-y-recovered" \
  "$root/claudex" --claude-chrome --version >/dev/null &
self_y=$!
for _ in {1..300}; do [[ -e "$tmp/self-y-publish" ]] && break; sleep 0.02; done
: > "$tmp/self-x-before-continue"
for _ in {1..200}; do [[ -e "$tmp/self-x-after" ]] && break; sleep 0.02; done
: > "$tmp/self-y-continue"
for _ in {1..200}; do [[ -e "$tmp/self-y-recovered" ]] && break; sleep 0.02; done
[[ -e "$tmp/self-y-recovered" ]]
wait "$self_y"
: > "$tmp/self-x-after-continue"
wait "$self_x"
[[ ! -e "$state_lock" ]] && ! compgen -G "$state_lock.quarantine.*" >/dev/null

# A new creator that resumes inside a prior-format replacement must withdraw
# only its injected generation and restore the old owner's exact record.
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/legacy-a-mkdir" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/legacy-a-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
legacy_a=$!
for _ in {1..200}; do [[ -e "$tmp/legacy-a-mkdir" ]] && break; sleep 0.02; done
[[ -e "$tmp/legacy-a-mkdir" ]]
mv "$state_lock" "$tmp/legacy-a-empty"
mkdir -p "$state_lock"
printf '%s old-token\n' "$$" > "$state_lock/owner-pid"
: > "$tmp/legacy-a-continue"
wait "$legacy_a"
[[ "$(<"$state_lock/owner-pid")" == "$$ old-token" && ! -e "$state_lock/owner" && ! -e "$state_lock/generation" ]]
rm -rf "$state_lock" "$tmp/legacy-a-empty"

# A zero-length owner-pid is still an in-progress prior-format publication.
# A resumed structured creator must not delete it or enter the lock.
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/legacy-zero-mkdir" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/legacy-zero-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
legacy_zero=$!
for _ in {1..200}; do [[ -e "$tmp/legacy-zero-mkdir" ]] && break; sleep 0.02; done
[[ -e "$tmp/legacy-zero-mkdir" ]]
mv "$state_lock" "$tmp/legacy-zero-created"
mkdir -p "$state_lock"
: > "$state_lock/owner-pid"
: > "$tmp/legacy-zero-continue"
wait "$legacy_zero"
[[ -e "$state_lock/owner-pid" && ! -s "$state_lock/owner-pid" \
    && ! -e "$state_lock/owner" && ! -e "$state_lock/generation" ]]
rm -rf "$state_lock" "$tmp/legacy-zero-created"

# A prior-format creator can replace the directory and still be paused before
# its owner-pid file exists. Device and inode identity must reject that empty
# replacement rather than publishing into it.
: > "$tmp/legacy-absent-after-continue"
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/legacy-absent-mkdir" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/legacy-absent-continue" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/legacy-absent-entered" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/legacy-absent-after-continue" \
  CLAUDEX_TEST_LOCK_PRESERVE_FILE="$tmp/legacy-absent-path-moved" \
  "$root/claudex" --claude-chrome --version >/dev/null &
legacy_absent=$!
for _ in {1..200}; do [[ -e "$tmp/legacy-absent-mkdir" ]] && break; sleep 0.02; done
[[ -e "$tmp/legacy-absent-mkdir" ]]
mv "$state_lock" "$tmp/legacy-absent-created"
mkdir -p "$state_lock"
: > "$tmp/legacy-absent-continue"
wait "$legacy_absent"
[[ -d "$state_lock" && ! -e "$state_lock/owner-pid" \
    && ! -e "$state_lock/owner" && ! -e "$state_lock/generation" \
    && ! -e "$tmp/legacy-absent-entered" && ! -e "$tmp/legacy-absent-path-moved" ]]
printf '%s old-token\n' "$$" > "$state_lock/owner-pid"
[[ "$(<"$state_lock/owner-pid")" == "$$ old-token" ]]
rm -rf "$state_lock" "$tmp/legacy-absent-created"

# Future-format artifacts are conservative ownership signals too. Publication
# must withdraw only its injected files and leave the unknown entry untouched.
env "${aba_base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/unknown-owner-mkdir" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/unknown-owner-continue" \
  "$root/claudex" --claude-chrome --version >/dev/null &
unknown_owner=$!
for _ in {1..200}; do [[ -e "$tmp/unknown-owner-mkdir" ]] && break; sleep 0.02; done
[[ -e "$tmp/unknown-owner-mkdir" ]]
mv "$state_lock" "$tmp/unknown-owner-created"
mkdir -p "$state_lock"
printf '%s\n' future-owner > "$state_lock/owner.json"
: > "$tmp/unknown-owner-continue"
wait "$unknown_owner"
[[ "$(<"$state_lock/owner.json")" == future-owner \
    && ! -e "$state_lock/owner" && ! -e "$state_lock/generation" ]]
rm -rf "$state_lock" "$tmp/unknown-owner-created"

# Crash recovery prioritizes a prior-format live owner over a foreign injected
# generation in quarantine, removes the injection, and restores the owner.
mkdir -p "$state_lock.quarantine.mixed"
printf '%s\n' injected-generation > "$state_lock.quarantine.mixed/generation"
printf 'pid=99999999\nidentity=dead\nnonce=injected-generation\n' > "$state_lock.quarantine.mixed/owner"
printf '%s old-token\n' "$$" > "$state_lock.quarantine.mixed/owner-pid"
touch -t 200001010000 "$state_lock.quarantine.mixed"
env "${aba_base[@]}" "$root/claudex" --claude-chrome --version >/dev/null
[[ "$(<"$state_lock/owner-pid")" == "$$ old-token" && ! -e "$state_lock/owner" && ! -e "$state_lock/generation" ]]
rm -rf "$state_lock"

mkdir -p "$state_lock.quarantine.mixed-empty"
printf '%s\n' injected-generation > "$state_lock.quarantine.mixed-empty/generation"
printf 'pid=99999999\nidentity=dead\nnonce=injected-generation\n' > "$state_lock.quarantine.mixed-empty/owner"
: > "$state_lock.quarantine.mixed-empty/owner-pid"
touch -t 200001010000 "$state_lock.quarantine.mixed-empty"
env "${aba_base[@]}" "$root/claudex" --claude-chrome --version >/dev/null
[[ -e "$state_lock/owner-pid" && ! -s "$state_lock/owner-pid" \
    && ! -e "$state_lock/owner" && ! -e "$state_lock/generation" ]]
rm -rf "$state_lock"

# A dead prior-format owner also takes precedence over a live-looking injected
# structured owner. Once its grace has elapsed, both canonical and quarantined
# mixed states are reclaimed instead of being blocked by the injected PID.
mkdir -p "$state_lock.quarantine.mixed-dead"
printf '%s\n' injected-live > "$state_lock.quarantine.mixed-dead/generation"
printf 'pid=%s\nidentity=\nnonce=injected-live\n' "$$" > "$state_lock.quarantine.mixed-dead/owner"
printf '%s old-token\n' 99999999 > "$state_lock.quarantine.mixed-dead/owner-pid"
touch -t 200001010000 "$state_lock.quarantine.mixed-dead"
env "${aba_base[@]}" "$root/claudex" --claude-chrome --version >/dev/null
[[ ! -e "$state_lock" ]] && ! compgen -G "$state_lock.quarantine.*" >/dev/null

mkdir -p "$state_lock"
printf '%s\n' injected-live > "$state_lock/generation"
printf 'pid=%s\nidentity=\nnonce=injected-live\n' "$$" > "$state_lock/owner"
printf '%s old-token\n' 99999999 > "$state_lock/owner-pid"
touch -t 200001010000 "$state_lock"
env "${aba_base[@]}" "$root/claudex" --claude-chrome --version >/dev/null
[[ ! -e "$state_lock" ]] && ! compgen -G "$state_lock.quarantine.*" >/dev/null

# A detached update survives HUP, never inherits managed credentials, and an
# artificially old live owner is not replaced by a second update.
rm -rf "$update_dir"
live_update_log="$tmp/live-update.log"
live_update_env_log="$tmp/live-update-env.log"
live_update_ready="$tmp/live-update-ready"
live_update_release="$tmp/live-update-release"
live_update_done="$tmp/live-update-done"
live_update_attempt="$tmp/live-update-attempt"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_UPDATE_WORKER_ATTEMPT_FILE="$live_update_attempt" \
  CLAUDEX_PROXY_TOKEN=must-not-leak ANTHROPIC_AUTH_TOKEN=must-not-leak CLAUDEX_MANAGED_SESSION=1 \
  CLAUDE_CODE_SUBAGENT_MODEL=must-not-leak \
  FAKE_UPDATE_LOG="$live_update_log" FAKE_UPDATE_ENV_LOG="$live_update_env_log" \
  FAKE_UPDATE_READY_FILE="$live_update_ready" FAKE_UPDATE_WAIT_FILE="$live_update_release" \
  FAKE_UPDATE_DONE_FILE="$live_update_done" "$root/claudex" --claude-chrome --version >/dev/null
for _ in {1..1000}; do [[ -e "$live_update_ready" && -s "$update_dir/lock/owner" ]] && break; sleep 0.02; done
[[ -e "$live_update_ready" && -s "$update_dir/lock/owner" && -s "$live_update_attempt" ]]
live_update_pid=$(head -n 1 "$live_update_log")
touch -t 200001010000 "$update_dir/lock"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_UPDATE_WORKER_ATTEMPT_FILE="$live_update_attempt" \
  FAKE_UPDATE_LOG="$live_update_log" "$root/claudex" --claude-chrome --version >/dev/null
for _ in {1..1000}; do grep -q '^blocked ' "$live_update_attempt" 2>/dev/null && break; sleep 0.02; done
grep -q '^blocked ' "$live_update_attempt"
[[ "$(wc -l < "$live_update_log" | tr -d ' ')" == 1 ]]
kill -HUP "$live_update_pid"
: > "$live_update_release"
for _ in {1..1000}; do [[ -e "$live_update_done" && -s "$update_dir/last-success" ]] && break; sleep 0.02; done
[[ -e "$live_update_done" && -s "$update_dir/last-success" ]]
grep -Fx 'PROXY_TOKEN=' "$live_update_env_log" >/dev/null
grep -Fx 'AUTH_TOKEN=' "$live_update_env_log" >/dev/null
grep -Fx 'MANAGED=' "$live_update_env_log" >/dev/null
grep -Fx 'SUBAGENT=' "$live_update_env_log" >/dev/null

# An old owner cannot delete a replacement generation whose nonce differs.
rm -rf "$update_dir"
replacement_update_log="$tmp/replacement-update.log"
replacement_update_ready="$tmp/replacement-update-ready"
replacement_update_release="$tmp/replacement-update-release"
replacement_update_done="$tmp/replacement-update-done"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 \
  FAKE_UPDATE_LOG="$replacement_update_log" FAKE_UPDATE_READY_FILE="$replacement_update_ready" \
  FAKE_UPDATE_WAIT_FILE="$replacement_update_release" FAKE_UPDATE_DONE_FILE="$replacement_update_done" \
  "$root/claudex" --claude-chrome --version >/dev/null
for _ in {1..1000}; do [[ -e "$replacement_update_ready" && -s "$update_dir/lock/owner" ]] && break; sleep 0.02; done
mv "$update_dir/lock" "$update_dir/displaced-lock"
mkdir "$update_dir/lock"
printf 'pid=%s\nidentity=%s\nnonce=replacement-update-owner\n' "$$" 'test-process-identity' > "$update_dir/lock/owner"
: > "$replacement_update_release"
for _ in {1..1000}; do [[ -e "$replacement_update_done" ]] && break; sleep 0.02; done
[[ -e "$replacement_update_done" ]]
grep -F 'nonce=replacement-update-owner' "$update_dir/lock/owner" >/dev/null
rm -rf "$update_dir"

# A killed owner is reclaimed.
rm -rf "$update_dir"
dead_update_log="$tmp/dead-update.log"
dead_update_ready="$tmp/dead-update-ready"
dead_update_release="$tmp/dead-update-release"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 \
  FAKE_UPDATE_LOG="$dead_update_log" FAKE_UPDATE_READY_FILE="$dead_update_ready" \
  FAKE_UPDATE_WAIT_FILE="$dead_update_release" "$root/claudex" --claude-chrome --version >/dev/null
for _ in {1..1000}; do [[ -e "$dead_update_ready" && -s "$update_dir/lock/owner" ]] && break; sleep 0.02; done
dead_update_owner=$(awk -F= '$1 == "pid" { print $2; exit }' "$update_dir/lock/owner")
kill -KILL "$dead_update_owner" 2>/dev/null || true
touch -t 200001010000 "$update_dir/lock"
rm -f "$update_dir/last-success" "$dead_update_ready"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 \
  FAKE_UPDATE_LOG="$dead_update_log" "$root/claudex" --claude-chrome --version >/dev/null
for _ in {1..1000}; do [[ $(wc -l < "$dead_update_log" | tr -d ' ') -ge 2 ]] && break; sleep 0.02; done
[[ "$(wc -l < "$dead_update_log" | tr -d ' ')" == 2 ]]
for _ in {1..1000}; do [[ -s "$update_dir/last-success" && ! -e "$update_dir/lock" ]] && break; sleep 0.02; done
[[ -s "$update_dir/last-success" && ! -e "$update_dir/lock" ]]
: > "$dead_update_release"

rm -rf "$update_dir"
mkdir -p "$update_dir/lock"
touch -t 200001010000 "$update_dir/lock"
update_log="$tmp/update.log"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 FAKE_UPDATE_LOG="$update_log" \
  FAKE_CLAUDE_DELAY=0.2 "$root/claudex" test-prompt >/dev/null
for _ in {1..500}; do [[ -s "$update_log" ]] && break; sleep 0.02; done
[[ -s "$update_log" ]]

# A recent ownerless update lock can belong to v1.5.8 between mkdir and owner
# publication, so the transition path preserves it for the full legacy hour.
rm -rf "$update_dir"
mkdir -p "$update_dir/lock"
rm -f "$update_log"
legacy_update_attempt="$tmp/legacy-update-attempt"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_UPDATE_WORKER_ATTEMPT_FILE="$legacy_update_attempt" \
  FAKE_UPDATE_LOG="$update_log" "$root/claudex" --claude-chrome --version >/dev/null
for _ in {1..1000}; do grep -q '^blocked ' "$legacy_update_attempt" 2>/dev/null && break; sleep 0.02; done
grep -q '^blocked ' "$legacy_update_attempt"
[[ -d "$update_dir/lock" && ! -e "$update_log" ]]

rm -rf "$update_dir"
mkdir -p "$update_dir/lock"
touch -t 200001010000 "$update_dir/lock"
rm -f "$update_log" "$update_dir/last-success"
HOME="$update_home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=0 FAKE_UPDATE_LOG="$update_log" \
  "$root/claudex" update >/dev/null
[[ "$(wc -l < "$update_log" | tr -d ' ')" == 1 ]]

"$root/tests/auth-usage-regressions.sh"
"$root/tests/self-update-regressions.sh"
bash "$root/tests/installer-regressions.sh"
node "$root/scripts/check-docs.mjs"

printf '%s\n' 'all Claudex tests passed'
