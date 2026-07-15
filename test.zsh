#!/bin/zsh
set -euo pipefail

readonly root="${0:A:h}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home/.config/claudex" "$tmp/bin"
print 'CLAUDEX_PROXY_TOKEN=test-token' > "$tmp/home/.config/claudex/env"
cp "$root/settings.json" "$tmp/home/.config/claudex/settings.json"

cat > "$tmp/bin/curl" <<'EOF'
#!/bin/zsh
print '{"data":[{"id":"gpt-5.6-sol"},{"id":"gpt-5.6-terra"},{"id":"gpt-5.6-luna"}]}'
EOF
cat > "$tmp/bin/claude" <<'EOF'
#!/bin/zsh
if [[ "${1:-}" == "--version" ]]; then
  print '2.1.210 (test)'
  exit
fi
print -r -- "AUTO=${CLAUDE_CODE_AUTO_MODE_MODEL}"
print -r -- "BG=${CLAUDE_CODE_BG_CLASSIFIER_MODEL}"
print -r -- "SUBAGENT=${CLAUDE_CODE_SUBAGENT_MODEL}"
print -r -- "CONCURRENCY=${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY}"
print -r -- "RETRIES=${CLAUDE_CODE_MAX_RETRIES}"
print -r -- "CONTEXT=${CLAUDE_CODE_MAX_CONTEXT_TOKENS}"
print -r -- "COMPACT=${CLAUDE_CODE_AUTO_COMPACT_WINDOW}"
print -r -- "FABLE=${ANTHROPIC_DEFAULT_FABLE_MODEL}"
print -r -- "FABLE_NAME=${ANTHROPIC_DEFAULT_FABLE_MODEL_NAME}"
print -r -- "OPUS=${ANTHROPIC_DEFAULT_OPUS_MODEL}"
print -r -- "OPUS_NAME=${ANTHROPIC_DEFAULT_OPUS_MODEL_NAME}"
print -r -- "ARGS=$*"
EOF
cat > "$tmp/bin/cliproxyapi" <<'EOF'
#!/bin/zsh
print 'CLIProxyAPI test'
print 'extra version detail'
exit 1
EOF
chmod +x "$tmp/bin/"*

run_wrapper() {
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
    "$root/claudex" "$@"
}

zsh -n "$root/claudex"
zsh -n "$root/statusline"
jq -e '
  .permissions.defaultMode == "auto"
  and .autoCompactEnabled == true
  and .autoCompactWindow == 280000
  and .precomputeCompactionEnabled == true
  and .verbose == false
  and .tui == "fullscreen"
  and .modelOverrides["gpt-5.6-sol"] == "gpt-5.6-sol"
  and .modelOverrides["gpt-5.6-terra"] == "gpt-5.6-terra"
  and .modelOverrides["gpt-5.6-luna"] == "gpt-5.6-luna"
  and (.availableModels | index("gpt-5.6-sol") != null)
  and (.availableModels | index("gpt-5.6-terra") != null)
  and (.availableModels | index("gpt-5.6-luna") != null)
  and .statusLine.command == "__CLAUDEX_STATUSLINE_COMMAND__"
  and (.env | not)
' "$root/settings.json" >/dev/null

default_output=$(run_wrapper --terra test-prompt)
state_file="$tmp/home/.config/claudex/.claude.json"
jq -e '
  any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-sol" and .label == "GPT-5.6 Sol")
  and any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-terra" and .label == "GPT-5.6 Terra")
  and any(.additionalModelOptionsCache[]?; .value == "gpt-5.6-luna" and .label == "GPT-5.6 Luna")
' "$state_file" >/dev/null
[[ "$default_output" == *'AUTO=gpt-5.6-luna'* ]]
[[ "$default_output" == *'BG=gpt-5.6-luna'* ]]
[[ "$default_output" == *'SUBAGENT=gpt-5.6-terra'* ]]
[[ "$default_output" == *'CONCURRENCY=3'* ]]
[[ "$default_output" == *'RETRIES=2'* ]]
[[ "$default_output" == *'CONTEXT=400000'* ]]
[[ "$default_output" == *'COMPACT=280000'* ]]
[[ "$default_output" == *'FABLE=gpt-5.6-sol'* ]]
[[ "$default_output" == *'FABLE_NAME=GPT-5.6 Sol'* ]]
[[ "$default_output" == *'OPUS=gpt-5.6-sol'* ]]
[[ "$default_output" == *'OPUS_NAME=GPT-5.6 Sol'* ]]
[[ "$default_output" == *'--permission-mode auto'* ]]
[[ "$default_output" == *'--model gpt-5.6-terra'* ]]
[[ "$default_output" == *'Do not create a team, spawn or delegate to additional agents'* ]]
[[ "$default_output" == *'keep at most 3 Agent tasks active at once'* ]]
[[ "$default_output" == *'"claudex-deep"'* ]]
[[ "$default_output" == *"without consuming the leader's Sol capacity"* ]]
[[ "$default_output" != *'"model":"gpt-5.6-sol"'* ]]

auto_output=$(run_wrapper --auto --luna test-prompt)
[[ "$auto_output" == *'--permission-mode auto'* ]]
[[ "$auto_output" == *'--model gpt-5.6-luna'* ]]

doctor_output=$(run_wrapper --doctor)
[[ "$doctor_output" == *'CLIProxyAPI: CLIProxyAPI test'* ]]
[[ "$doctor_output" == *'Default permission mode: auto'* ]]
[[ "$doctor_output" == *'Auto-mode classifier: gpt-5.6-luna'* ]]
[[ "$doctor_output" == *'Subagent model: gpt-5.6-terra (Sol is reserved for the leader)'* ]]
[[ "$doctor_output" == *'Agent concurrency: 3'* ]]
[[ "$doctor_output" == *'API retries: 2'* ]]
[[ "$doctor_output" == *'Context window: 400000 tokens'* ]]
[[ "$doctor_output" == *'Auto-compact window: 280000 tokens (precompute enabled)'* ]]
[[ "$doctor_output" == *'Terminal UI: fullscreen (launch command hidden while Claudex is open)'* ]]
[[ "$doctor_output" == *'Header model name: GPT-5.6 Sol'* ]]
[[ "$doctor_output" == *'Mouse pointer: pointer'* ]]
[[ "$doctor_output" == *'gpt-5.6-terra: advertised'* ]]
[[ "$doctor_output" != *'extra version detail'* ]]

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_PERMISSION_MODE=broken "$root/claudex" >/dev/null 2>&1; then
  print -u2 'expected invalid permission mode to fail'
  exit 1
fi

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_AUTO_COMPACT_WINDOW=99999 "$root/claudex" >/dev/null 2>&1; then
  print -u2 'expected invalid auto-compact window to fail'
  exit 1
fi

if HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  CLAUDEX_MOUSE_POINTER_SHAPE=beam "$root/claudex" >/dev/null 2>&1; then
  print -u2 'expected invalid mouse pointer shape to fail'
  exit 1
fi

cursor_output=$(script -q /dev/null env \
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" CLAUDEX_CURL_BIN="$tmp/bin/curl" \
  "$root/claudex" --luna cursor-test)
[[ "$cursor_output" == *$'\033]22;pointer\033\\'* ]]
[[ "$cursor_output" == *$'\033]22;default\033\\'* ]]

status_output=$(print '{"model":{"id":"gpt-5.6-sol"},"effort":{"level":"xhigh"},"context_window":{"used_percentage":42.9}}' | \
  CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$status_output" == *'GPT-5.6 Sol'* ]]
[[ "$status_output" == *'xhigh effort'* ]]
[[ "$status_output" == *'42% context'* ]]

invalid_status=$(print 'not-json' | CLAUDE_CONFIG_DIR="$tmp/home/.config/claudex" "$root/statusline")
[[ "$invalid_status" == *'Unknown model'* ]]

install_home="$tmp/install-home"
mkdir -p "$install_home"
install_output=$(HOME="$install_home" PATH="$tmp/bin:$PATH" \
  CLAUDEX_PROXY_TOKEN='installer-test-token' \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
  "$root/install.zsh")
[[ -x "$install_home/.local/bin/claudex" ]]
[[ -x "$install_home/.config/claudex/statusline" ]]
[[ -r "$install_home/.config/claudex/settings.json" ]]
[[ -r "$install_home/.config/claudex/env" ]]
[[ "$install_output" != *'installer-test-token'* ]]
jq -e --arg expected "/bin/zsh $install_home/.config/claudex/statusline" \
  '.statusLine.command == $expected and .tui == "fullscreen"' \
  "$install_home/.config/claudex/settings.json" >/dev/null
[[ "$(<"$install_home/.config/claudex/env")" == 'CLAUDEX_PROXY_TOKEN=installer-test-token' ]]

print 'all Claudex tests passed'
