#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/claudex-auth-usage.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export CLAUDEX_CONFIG_DIR="$HOME/.config/claudex"
export CODEX_HOME="$HOME/.codex"
export CLAUDEX_CODEX_AUTH_DIR="$CLAUDEX_CONFIG_DIR/codex-accounts"
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin" "$CODEX_HOME" "$CLAUDEX_CODEX_AUTH_DIR" "$CLAUDEX_CONFIG_DIR/usage-cache"

cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit "${FAKE_CODEX_STATUS:-0}"; fi
if [[ "${1:-}" == logout ]]; then exit "${FAKE_CODEX_LOGOUT:-0}"; fi
if [[ "${1:-}" == app-server ]]; then
  if [[ "${FAKE_APP_SERVER_MODE:-}" == deadline ]]; then
    IFS= read -r _
    sleep 0.7
    printf '%s\n' '{"id":1,"result":{"ready":true}}'
    IFS= read -r _
    IFS= read -r _
    sleep 0.7
    printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":10,"windowDurationMins":10080}},"rateLimitsByLimitId":{}}}'
    exit
  fi
  sleep 30 & child=$!
  [[ -z "${FAKE_APP_SERVER_CHILD_FILE:-}" ]] || printf '%s\n' "$child" > "$FAKE_APP_SERVER_CHILD_FILE"
  if [[ "${FAKE_APP_SERVER_MODE:-}" == noisy ]]; then
    while :; do printf '%065536d' 0 >&2; done &
  fi
  while IFS= read -r _; do :; done
  wait
  exit
fi
exit 2
EOF
chmod +x "$tmp/bin/codex"

write_source_auth() {
  local account=$1 access=$2
  printf '{"auth_mode":"chatgpt","tokens":{"access_token":"%s","refresh_token":"refresh-%s","account_id":"%s"}}\n' \
    "$access" "$account" "$account" > "$CODEX_HOME/auth.json"
}

write_source_auth account-b access-b
printf '%s\n' '{"type":"codex","access_token":"access-a","refresh_token":"refresh-a","account_id":"account-a"}' \
  > "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json"
printf '%s\n' old > "$CLAUDEX_CONFIG_DIR/usage-cache/summary"
printf '%s\n' 1 > "$CLAUDEX_CONFIG_DIR/usage-cache/last-success"
printf '%s\n' codex-a.json > "$CLAUDEX_CONFIG_DIR/codex-usage-account"
"$root/codex-session" sync
jq -e '.account_id == "account-b" and .id_token == "" and .last_refresh == ""' \
  "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" >/dev/null
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/summary" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/codex-usage-account" ]]

mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache"
printf '%s\n' old > "$CLAUDEX_CONFIG_DIR/usage-cache/summary"
printf '%s\n' codex-a.json > "$CLAUDEX_CONFIG_DIR/codex-usage-account"
"$root/codex-session" logout >/dev/null
[[ ! -e "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/summary" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/codex-usage-account" ]]

# The watcher must reconcile a divergence that predates its initial fingerprint.
write_source_auth account-b access-b
printf '%s\n' '{"type":"codex","access_token":"access-a","refresh_token":"refresh-a","account_id":"account-a"}' \
  > "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json"
sleep 5 & parent_pid=$!
CLAUDEX_AUTH_WATCH_SECONDS=1 CLAUDEX_AUTH_WATCH_READY_FILE="$tmp/watch-ready" \
  "$root/codex-session" watch "$parent_pid" & watcher_pid=$!
for _ in {1..100}; do [[ -s "$tmp/watch-ready" ]] && break; sleep 0.02; done
jq -e '.account_id == "account-b"' "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" >/dev/null
kill "$parent_pid" 2>/dev/null || true
wait "$parent_pid" 2>/dev/null || true
wait "$watcher_pid"

# Failed publication must not strand a secret-bearing credential temporary.
cat > "$tmp/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAKE_CREDENTIAL_MOVE_FAIL:-0}" == 1 && "$*" == *'.codex-session.tmp.'* ]]; then exit 1; fi
exec /bin/mv "$@"
EOF
chmod +x "$tmp/bin/mv"
write_source_auth account-b access-new
if FAKE_CREDENTIAL_MOVE_FAIL=1 "$root/codex-session" sync >/dev/null 2>&1; then
  printf '%s\n' 'failed credential publication unexpectedly succeeded' >&2
  exit 1
fi
if find "$CLAUDEX_CODEX_AUTH_DIR" -maxdepth 1 -name '.codex-session.tmp.*' -print -quit | grep . >/dev/null; then
  printf '%s\n' 'failed credential publication leaked a secret temporary' >&2
  exit 1
fi
"$root/codex-session" sync

cat > "$CLAUDEX_CODEX_AUTH_DIR/codex-a.json" <<'EOF'
{"type":"codex","access_token":"token-a","account_id":"account-a","email":"a@example.com"}
EOF
cat > "$CLAUDEX_CODEX_AUTH_DIR/codex-b.json" <<'EOF'
{"type":"codex","access_token":"token-b","account_id":"account-b","email":"b@example.com"}
EOF

cat > "$tmp/bin/fake-curl" <<'EOF'
#!/usr/bin/env bash
config=""
while (( $# )); do
  if [[ "$1" == --config ]]; then shift; config=$1; fi
  shift
done
if [[ "${FAKE_PARTIAL_SCHEMA:-0}" == 1 ]]; then
  printf '%s\n' '{"plan_type":"pro","rate_limit":{"primary_window":{"limit_window_seconds":604800}}}'
  exit
fi
if [[ "${FAKE_CURL_FAIL:-0}" == 1 ]]; then exit 22; fi
token=$(sed -n 's/.*Bearer \([^"[:space:]]*\).*/\1/p' "$config")
if [[ -n "${FAKE_CURL_STARTED:-}" ]]; then
  printf '%s\n' "$token" > "$FAKE_CURL_STARTED"
  while [[ ! -e "$FAKE_CURL_RELEASE" ]]; do sleep 0.02; done
fi
if [[ "$token" == token-a ]]; then
  used=10
else
  used=20
fi
printf '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":%s,"limit_window_seconds":604800}},"code_review_rate_limit":{"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"Spark","rate_limit":{"primary_window":{"used_percent":95,"limit_window_seconds":604800}}}]}\n' "$used"
EOF
chmod +x "$tmp/bin/fake-curl"
export CLAUDEX_CURL_BIN="$tmp/bin/fake-curl"
export CLAUDEX_USAGE_SOURCE=web
export CLAUDEX_USAGE_REFRESH_SECONDS=60
export CLAUDEX_USAGE_MAX_STALE_SECONDS=60

"$root/usage-limit" --account a@example.com >/dev/null
export FAKE_CURL_STARTED="$tmp/curl-started"
export FAKE_CURL_RELEASE="$tmp/curl-release"
"$root/usage-limit" --refresh-cache >"$tmp/old-refresh.out" 2>"$tmp/old-refresh.err" & old_refresh=$!
for _ in {1..100}; do [[ -s "$FAKE_CURL_STARTED" ]] && break; sleep 0.02; done
[[ "$(<"$FAKE_CURL_STARTED")" == token-a ]]
"$root/usage-limit" --account b@example.com >/dev/null
[[ -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
touch "$FAKE_CURL_RELEASE"
if wait "$old_refresh"; then
  printf '%s\n' 'obsolete account refresh unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/limits.json" ]]
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
unset FAKE_CURL_STARTED FAKE_CURL_RELEASE

if FAKE_PARTIAL_SCHEMA=1 "$root/usage-limit" --refresh-cache >/dev/null 2>"$tmp/partial.err"; then
  printf '%s\n' 'partial usage schema unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'no Codex rate-limit window' "$tmp/partial.err" >/dev/null

"$root/usage-limit" --refresh-cache
summary=$(<"$CLAUDEX_CONFIG_DIR/usage-cache/summary")
[[ "$summary" == *'Review 7d 0% left'* ]]
[[ "$summary" == *'Spark 7d 5% left'* ]]
[[ "$summary" == '⚠ Codex '* ]]

# A stale-looking lock with a live owner must not be deleted by the footer.
mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' "$$ live-token-123" > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
printf '%s\n' "$(( $(date +%s) - 121 ))" > "$CLAUDEX_CONFIG_DIR/usage-cache/last-attempt"
printf '%s\n' '{"session_id":"lock-test","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":1}}' | \
  CLAUDE_CONFIG_DIR="$CLAUDEX_CONFIG_DIR" CLAUDEX_USAGE_LIMIT_BIN="$root/usage-limit" "$root/statusline" >/dev/null
[[ -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
printf '%s\n' '99999999 dead-token-123' > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
"$root/usage-limit" --refresh-cache
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]

# A helper carrying an obsolete generation must never release a fresh lock.
mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' "$$ fresh-token-123" > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
"$root/usage-limit" --refresh-cache --lock-held --lock-token stale-token-123
[[ "$(<"$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid")" == "$$ fresh-token-123" ]]
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"

# Initialization and rate-limit retrieval share one wall-clock budget, and a
# timed-out app-server cannot leave its descendants alive.
"$root/usage-limit" --account auto >/dev/null
deadline_start=$(date +%s)
if FAKE_APP_SERVER_MODE=deadline CLAUDEX_USAGE_SOURCE=app-server CLAUDEX_USAGE_TIMEOUT_SECONDS=1 \
    "$root/usage-limit" --refresh-cache >/dev/null 2>"$tmp/deadline.err"; then
  printf '%s\n' 'split app-server deadlines unexpectedly succeeded' >&2
  exit 1
fi
deadline_elapsed=$(( $(date +%s) - deadline_start ))
(( deadline_elapsed <= 2 ))

child_file="$tmp/appserver-child"
if FAKE_APP_SERVER_MODE=noisy FAKE_APP_SERVER_CHILD_FILE="$child_file" \
    CLAUDEX_USAGE_SOURCE=app-server CLAUDEX_USAGE_TIMEOUT_SECONDS=1 \
    "$root/usage-limit" --refresh-cache >/dev/null 2>"$tmp/noisy.err"; then
  printf '%s\n' 'non-responsive app-server unexpectedly succeeded' >&2
  exit 1
fi
[[ -s "$child_file" ]]
child_pid=$(<"$child_file")
for _ in {1..40}; do kill -0 "$child_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$child_pid" 2>/dev/null; then
  printf '%s\n' 'timed-out app-server leaked a descendant process' >&2
  exit 1
fi

# Context caches are bounded by both age and count.
status_cache="$CLAUDEX_CONFIG_DIR/statusline-cache"
mkdir -p "$status_cache"
for index in {1..140}; do printf '%s\n' 1 > "$status_cache/session-$index"; done
printf '%s\n' 1 > "$status_cache/expired-session"
touch -t 202001010000 "$status_cache/expired-session"
printf '%s\n' '{"session_id":"current-session","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":2}}' | \
  CLAUDEX_USAGE_DISPLAY=off CLAUDE_CONFIG_DIR="$CLAUDEX_CONFIG_DIR" "$root/statusline" >/dev/null
status_count=$(find "$status_cache" -maxdepth 1 -type f ! -name '.context.tmp.*' | wc -l | tr -d ' ')
(( status_count <= 128 ))
[[ -f "$status_cache/current-session" ]]
[[ ! -e "$status_cache/expired-session" ]]

"$root/usage-limit" --refresh-cache
old=$(( $(date +%s) - 120 ))
printf '%s\n' "$old" > "$CLAUDEX_CONFIG_DIR/usage-cache/last-success"
if FAKE_CURL_FAIL=1 "$root/usage-limit" >/dev/null 2>"$tmp/stale.err"; then
  printf '%s\n' 'expired outage cache unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'older than the configured maximum age' "$tmp/stale.err" >/dev/null

# PowerShell is not available on every POSIX CI host; retain source-level
# assertions for its lock ownership and just-created ownerless-lock grace.
grep -F '$ownsRefreshLock = $false' "$root/usage-limit.ps1" >/dev/null
grep -F '$script:ownsRefreshLock = $true' "$root/usage-limit.ps1" >/dev/null
grep -F 'Move-RefreshLockToQuarantine' "$root/usage-limit.ps1" >/dev/null
grep -F '$ownerlessIsStale = $lockAge -ge 2' "$root/usage-limit.ps1" >/dev/null
grep -F '$ownerlessIsStale = $lockAge -ge 2' "$root/statusline.ps1" >/dev/null
grep -F '[Claudex.CappedTextReader]::DrainAsync' "$root/usage-limit.ps1" >/dev/null
grep -F 'taskkill.exe /PID' "$root/usage-limit.ps1" >/dev/null
grep -F 'Protect-PrivatePath $bridgeAuthFile $false' "$root/codex-session.ps1" >/dev/null

printf '%s\n' 'auth/usage regressions passed'
