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
printf '%s\n' "$$" > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
printf '%s\n' "$(( $(date +%s) - 121 ))" > "$CLAUDEX_CONFIG_DIR/usage-cache/last-attempt"
printf '%s\n' '{"session_id":"lock-test","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":1}}' | \
  CLAUDE_CONFIG_DIR="$CLAUDEX_CONFIG_DIR" CLAUDEX_USAGE_LIMIT_BIN="$root/usage-limit" "$root/statusline" >/dev/null
[[ -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
printf '%s\n' 99999999 > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
"$root/usage-limit" --refresh-cache
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]

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
grep -F '$currentOwner -le 0 -or $currentOwner -eq $PID' "$root/usage-limit.ps1" >/dev/null
grep -F '$ownerlessIsStale = $lockAge -ge 2' "$root/usage-limit.ps1" >/dev/null
grep -F '$ownerlessIsStale = $lockAge -ge 2' "$root/statusline.ps1" >/dev/null

printf '%s\n' 'auth/usage regressions passed'
