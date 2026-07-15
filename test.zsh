#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home/.config/claudex" "$tmp/home/.cli-proxy-api" "$tmp/home/.codex" "$tmp/bin"
printf '%s\n' 'CLAUDEX_PROXY_TOKEN=test-token' "CLAUDEX_CODEX_AUTH_DIR=$tmp/home/.cli-proxy-api" > "$tmp/home/.config/claudex/env"
cp "$root/settings.json" "$tmp/home/.config/claudex/settings.json"
cp "$root/usage-limit" "$tmp/home/.config/claudex/usage-limit"
cp "$root/codex-session" "$tmp/home/.config/claudex/codex-session"
chmod +x "$tmp/home/.config/claudex/codex-session"
cat > "$tmp/home/.codex/auth.json" <<'EOF'
{"OPENAI_API_KEY":null,"auth_mode":"chatgpt","last_refresh":"2026-07-15T01:00:00Z","tokens":{"access_token":"codex-source-access","refresh_token":"codex-source-refresh","id_token":"codex-source-id","account_id":"account-test"}}
EOF
cat > "$tmp/home/.cli-proxy-api/codex-test.json" <<'EOF'
{"type":"codex","access_token":"secret-access-token","refresh_token":"secret-refresh-token","account_id":"account-test","email":"private@example.com"}
EOF

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  if [[ "$argument" == *'test-token'* || "$argument" == *'secret-access-token'* ]]; then
    printf '%s\n' 'credential leaked into curl arguments' >&2
    exit 90
  fi
  if [[ "$argument" == *'/wham/usage'* ]]; then
    [[ "${FAKE_USAGE_FAIL:-0}" != 1 ]] || exit 22
    if [[ "${FAKE_USAGE_CHANGED:-0}" == 1 ]]; then printf '%s\n' '{"new_usage_schema":true}'; exit; fi
    printf '%s\n' '{"user_id":"private-user","account_id":"private-account","email":"private@example.com","plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":82,"limit_window_seconds":604800,"reset_after_seconds":565127,"reset_at":1784666240},"secondary_window":null},"code_review_rate_limit":null,"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":1784705933},"secondary_window":null}}],"credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"},"spend_control":{"reached":false,"individual_limit":null},"rate_limit_reached_type":null,"rate_limit_reset_credits":{"available_count":1}}'
    exit
  fi
done
printf '%s\n' '{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}'
EOF
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '%s\n' '2.1.210 (test)'
  exit
fi
if [[ "${1:-}" == "--help" ]]; then
  printf '%s\n' '--model --agents --append-system-prompt --permission-mode --settings --effort'
  exit
fi
if [[ "${1:-}" == "update" ]]; then exit 0; fi
printf '%s\n' "AUTO=${CLAUDE_CODE_AUTO_MODE_MODEL}"
printf '%s\n' "BG=${CLAUDE_CODE_BG_CLASSIFIER_MODEL}"
printf '%s\n' "SUBAGENT=${CLAUDE_CODE_SUBAGENT_MODEL}"
printf '%s\n' "CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY}"
printf '%s\n' "RETRIES=${CLAUDE_CODE_MAX_RETRIES}"
printf '%s\n' "CONTEXT=${CLAUDE_CODE_MAX_CONTEXT_TOKENS}"
printf '%s\n' "COMPACT=${CLAUDE_CODE_AUTO_COMPACT_WINDOW}"
printf '%s\n' "NO_FLICKER=${CLAUDE_CODE_NO_FLICKER}"
printf '%s\n' "ACCESSIBILITY=${CLAUDE_CODE_ACCESSIBILITY}"
printf '%s\n' "OPUS=${ANTHROPIC_DEFAULT_OPUS_MODEL}"
printf '%s\n' "OPUS_NAME=${ANTHROPIC_DEFAULT_OPUS_MODEL_NAME}"
printf '%s\n' "MODE=${CLAUDEX_SESSION_MODE:-}"
printf '%s\n' "BASE=${ANTHROPIC_BASE_URL:-}"
printf '%s\n' "CONFIG=${CLAUDE_CONFIG_DIR:-}"
printf '%s\n' "ARGS=$*"
EOF
cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_CODEX_LOGGED_OUT:-0}" == 1 ]]; then exit 1; fi
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == logout ]]; then exit 0; fi
if [[ "${1:-}" == -c && "${3:-}" == login ]]; then exit 0; fi
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
printf '%s\n' 'CLIProxyAPI test'
printf '%s\n' 'extra version detail'
exit 1
EOF
chmod +x "$tmp/bin/"*

run_wrapper() {
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 \
    "$root/claudex" "$@"
}

bash -n "$root/claudex"
bash -n "$root/statusline"
bash -n "$root/usage-limit"
bash -n "$root/install.sh"
sh -n "$root/install.zsh"
node --check "$root/preload.cjs"
input_alias_output=$(CLAUDEX_TEST_TTY_INPUT=1 node -e '
  const preload = require(process.argv[1]);
  process.stdout.write(preload.rewriteSolplanInput("/model solplan\r"));
' "$root/preload.cjs")
[[ "$input_alias_output" == $'/model opusplan\r' ]]
input_listener_output=$(printf '/model solplan\r' | CLAUDEX_TEST_TTY_INPUT=1 node --require "$root/preload.cjs" -e '
  process.stdin.once("data", (chunk) => process.stdout.write(chunk));
')
[[ "$input_listener_output" == $'/model opusplan\r' ]]
jq -e '
  .model == "opus"
  and .permissions.defaultMode == "auto"
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

default_output=$(run_wrapper --terra test-prompt)
state_file="$tmp/home/.config/claudex/.claude.json"
jq -e '
  any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-sol" and .label == "GPT-5.6 Sol")
  and any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-terra" and .label == "GPT-5.6 Terra")
  and any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-luna" and .label == "GPT-5.6 Luna")
  and any(.additionalModelOptionsCache[]?; .value == "opusplan" and .label == "GPT-5.6 Solplan")
' "$state_file" >/dev/null
[[ "$default_output" == *'AUTO=gpt-5.6-luna'* ]]
[[ "$default_output" == *'BG=gpt-5.6-luna'* ]]
[[ "$default_output" == *'SUBAGENT=gpt-5.6-terra'* ]]
[[ "$default_output" == *'CONCURRENCY=3'* ]]
[[ "$default_output" == *'RETRIES=2'* ]]
[[ "$default_output" == *'CONTEXT=400000'* ]]
[[ "$default_output" == *'COMPACT=280000'* ]]
[[ "$default_output" == *'NO_FLICKER=1'* ]]
[[ "$default_output" == *'ACCESSIBILITY=1'* ]]
[[ "$default_output" == *'OPUS=gpt-5.6-sol'* ]]
[[ "$default_output" == *'OPUS_NAME=GPT-5.6 Sol'* ]]
[[ "$default_output" == *'--permission-mode auto'* ]]
[[ "$default_output" == *'--model gpt-5.6-terra'* ]]
[[ "$default_output" == *'Do not create a team, spawn or delegate to additional agents'* ]]
[[ "$default_output" == *'Do not create, claim, or update entries in the shared task list'* ]]
[[ "$default_output" == *'keep at most 3 Agent tasks active at once'* ]]
[[ "$default_output" == *'Before every final answer, call TaskList and reconcile every entry'* ]]
[[ "$default_output" == *'Never leave stale in_progress tasks after their work is done'* ]]
[[ "$default_output" == *'operate as a Codex coding agent inside Claude Code'* ]]
[[ "$default_output" == *'Do not call EnterPlanMode'* ]]
[[ "$default_output" == *'"gpt-5-6-terra"'* ]]
[[ "$default_output" == *'"gpt-5-6-luna"'* ]]
[[ "$default_output" != *'"claudex-deep"'* ]]
[[ "$default_output" != *'"claudex-builder"'* ]]
[[ "$default_output" != *'"claudex-fast"'* ]]
[[ "$default_output" == *'Sol capacity is reserved for the leader'* ]]
[[ "$default_output" != *'"model":"gpt-5.6-sol"'* ]]

auto_output=$(run_wrapper --auto --luna test-prompt)
[[ "$auto_output" == *'--permission-mode auto'* ]]
[[ "$auto_output" == *'--model gpt-5.6-luna'* ]]

ultracode_output=$(run_wrapper --ultracode --sol test-prompt)
[[ "$ultracode_output" == *'MODE=ultracode'* ]]
[[ "$ultracode_output" == *'--effort xhigh'* ]]
[[ "$ultracode_output" == *'"ultracode":true'* ]]
[[ "$ultracode_output" == *'"workflows":true'* ]]

max_output=$(run_wrapper --max-effort test-prompt)
[[ "$max_output" == *'MODE=max'* ]]
[[ "$max_output" == *'--effort max'* ]]

solplan_output=$(run_wrapper --solplan test-prompt)
[[ "$solplan_output" == *'--model opusplan'* ]]
[[ "$solplan_output" == *'OPUS=gpt-5.6-sol'* ]]
[[ "$solplan_output" == *'SUBAGENT=gpt-5.6-terra'* ]]

bare_output=$(run_wrapper --bare --print test-prompt)
[[ "$bare_output" != *'--agents'* ]]
[[ "$bare_output" != *'--append-system-prompt'* ]]
[[ "$bare_output" != *'--permission-mode'* ]]

maintenance_output=$(run_wrapper mcp list)
[[ "$maintenance_output" == *'BASE='* ]]
[[ "$maintenance_output" != *"BASE=http"* ]]
[[ "$maintenance_output" != *'--agents'* ]]

for maintenance_command in agents auth auto-mode doctor gateway install mcp plugin plugins project setup-token ultrareview update upgrade; do
  command_output=$(run_wrapper "$maintenance_command" --help)
  [[ "$command_output" != *'--agents'* ]]
  [[ "$command_output" != *'--append-system-prompt'* ]]
  [[ "$command_output" != *'--permission-mode'* ]]
  [[ "$command_output" != *'BASE=http'* ]]
done

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
[[ "$explicit_agents_output" != *'"gpt-5-6-terra"'* ]]

chrome_output=$(run_wrapper --claude-chrome --print chrome-test)
[[ "$chrome_output" == *'ARGS=--chrome --print chrome-test'* ]]
[[ "$chrome_output" == *$'CONFIG=\n'* ]]

doctor_output=$(run_wrapper --doctor)
[[ "$doctor_output" == *'CLIProxyAPI: CLIProxyAPI test'* ]]
[[ "$doctor_output" == *'Default permission mode: auto'* ]]
[[ "$doctor_output" == *'Auto-mode classifier: gpt-5.6-luna'* ]]
[[ "$doctor_output" == *'Subagent model: gpt-5.6-terra (Sol is reserved for the leader)'* ]]
[[ "$doctor_output" == *'Agent concurrency: 3'* ]]
[[ "$doctor_output" == *'Task lifecycle: Sol-owned with final-response reconciliation'* ]]
[[ "$doctor_output" == *'API retries: 2'* ]]
[[ "$doctor_output" == *'Context window: 400000 tokens'* ]]
[[ "$doctor_output" == *'Auto-compact window: 280000 tokens (precompute enabled)'* ]]
[[ "$doctor_output" == *'Context status: session-stabilized (transient zero suppressed)'* ]]
[[ "$doctor_output" == *'Codex usage: status-line refresh every 300s'* ]]
[[ "$doctor_output" == *'Rendering: no-flicker mode with native terminal cursor'* ]]
[[ "$doctor_output" == *'Codex authentication: ready (shared ChatGPT session)'* ]]
[[ "$doctor_output" == *'Claude Code updates: on'* ]]
[[ "$doctor_output" == *'Plan mode policy: conservative'* ]]
[[ "$doctor_output" == *'Terminal UI: fullscreen (launch command hidden while Claudex is open)'* ]]
[[ "$doctor_output" == *'Header model name: GPT-5.6 Sol'* ]]
[[ "$doctor_output" == *'Mouse pointer: pointer'* ]]
[[ "$doctor_output" == *'gpt-5.6-terra: advertised'* ]]
[[ "$doctor_output" != *'extra version detail'* ]]

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

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_PERMISSION_MODE=broken "$root/claudex" >/dev/null 2>&1; then
  printf '%s\n' 'expected invalid permission mode to fail' >&2
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
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$status_output" == *'GPT-5.6 Sol'* ]]
[[ "$status_output" == *'xhigh effort'* ]]
[[ "$status_output" == *'42% context'* ]]
[[ "$status_output" == *'Codex 7d 16% left'* ]]

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

fresh_status=$(printf '%s\n' '{"session_id":"fresh-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":0,"context_window_size":400000,"current_usage":null}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$fresh_status" != *'% context'* ]]

small_status=$(printf '%s\n' '{"session_id":"small-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":0,"total_input_tokens":100,"context_window_size":400000}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$small_status" == *'<1% context'* ]]

invalid_status=$(printf '%s\n' 'not-json' | CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$invalid_status" == *'Unknown model'* ]]

billing_frame=$'GPT-5.6 Sol with high effort\033[41G·\033[43GAPI\033[47GUsage\033[53GBilling\r'
filtered_frame=$(printf '%s' "$billing_frame" | \
  node --require "$root/preload.cjs" -e 'process.stdin.pipe(process.stdout)')
[[ "$filtered_frame" == *'GPT-5.6 Sol with high effort'* ]]
[[ "$filtered_frame" != *'API Usage Billing'* ]]
[[ "$filtered_frame" != *$'·\033[43GAPI'* ]]

resume_frame='Resume this session with: claude --resume 123e4567-e89b-12d3-a456-426614174000'
filtered_resume=$(printf '%s' "$resume_frame" | node --require "$root/preload.cjs" -e 'process.stdin.pipe(process.stdout)')
[[ "$filtered_resume" == *'claudex --resume 123e4567-e89b-12d3-a456-426614174000'* ]]
[[ "$filtered_resume" != *'claude --resume'* ]]
filtered_resume_stderr=$(node --require "$root/preload.cjs" -e 'process.stderr.write(process.argv[1])' "$resume_frame" 2>&1)
[[ "$filtered_resume_stderr" == *'claudex --resume 123e4567-e89b-12d3-a456-426614174000'* ]]

solplan_picker='Opus Plan Mode · Use Opus in plan mode, Sonnet otherwise'
filtered_solplan=$(printf '%s' "$solplan_picker" | node --require "$root/preload.cjs" -e 'process.stdin.pipe(process.stdout)')
[[ "$filtered_solplan" == *'GPT-5.6 Solplan'* ]]
[[ "$filtered_solplan" == *'GPT-5.6 Sol in plan mode, GPT-5.6 Terra otherwise'* ]]
ansi_solplan_picker=$'Opus\033[5G Plan · Opus\033[20G in plan mode, else Sonnet · API\033[70G Usage Billing'
filtered_ansi_solplan=$(printf '%s' "$ansi_solplan_picker" | node --require "$root/preload.cjs" -e 'process.stdin.pipe(process.stdout)')
plain_ansi_solplan=$(printf '%s' "$filtered_ansi_solplan" | sed $'s/\033\\[[0-9;?]*[ -\\/]*[@-~]//g')
[[ "$plain_ansi_solplan" == *'GPT-5.6 Solplan'* ]]
[[ "$plain_ansi_solplan" == *'GPT-5.6 Sol in plan mode, else GPT-5.6 Terra'* ]]
[[ "$plain_ansi_solplan" != *'API Usage Billing'* ]]

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
[[ -r "$install_home/.config/claudex/skills/usage-limit/SKILL.md" ]]
[[ -r "$install_home/.config/claudex/settings.json" ]]
[[ -r "$install_home/.config/claudex/env" ]]
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

auth_status=$(run_wrapper --auth-status)
[[ "$auth_status" == *'Codex authentication: ready (shared ChatGPT session)'* ]]
if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" CLAUDEX_SKIP_AUTO_UPDATE=1 FAKE_CODEX_LOGGED_OUT=1 \
  "$root/claudex" --sol test-prompt >"$tmp/logged-out.stdout" 2>"$tmp/logged-out.stderr"; then
  printf '%s\n' 'expected logged-out Codex session to fail' >&2
  exit 1
fi
grep -F 'Codex is logged out. Run `codex login` (or `claudex --login`) and retry.' "$tmp/logged-out.stderr" >/dev/null

printf '%s\n' 'all Claudex tests passed'
