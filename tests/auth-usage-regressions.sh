#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/claudex-auth-usage.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'status=$?; printf "auth/usage regression failed at line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$status" >&2; exit "$status"' ERR

wait_for_file() {
  local path="$1" description="$2" require_content="${3:-0}" deadline=$(( SECONDS + 20 ))
  while :; do
    if [[ "$require_content" == 1 ]]; then [[ -s "$path" ]] && return 0
    else [[ -e "$path" ]] && return 0
    fi
    (( SECONDS < deadline )) || {
      printf 'timed out after 20s waiting for %s: %s\n' "$description" "$path" >&2
      return 1
    }
    sleep 0.05
  done
}

wait_for_session_temporary() {
  local description="$1" deadline=$(( SECONDS + 20 ))
  while :; do
    find "$CLAUDEX_CODEX_AUTH_DIR" -maxdepth 1 -name '.codex-session.tmp.*' -print -quit | grep . >/dev/null && return 0
    (( SECONDS < deadline )) || {
      printf 'timed out after 20s waiting for %s\n' "$description" >&2
      return 1
    }
    sleep 0.05
  done
}

wait_for_process_exit() {
  local pid="$1" description="$2" deadline=$(( SECONDS + 20 ))
  while kill -0 "$pid" 2>/dev/null; do
    (( SECONDS < deadline )) || {
      printf 'timed out after 20s waiting for %s process %s to exit\n' "$description" "$pid" >&2
      return 1
    }
    sleep 0.05
  done
}

export HOME="$tmp/home"
export CLAUDEX_CONFIG_DIR="$HOME/.config/claudex"
export CODEX_HOME="$HOME/.codex"
export CLAUDEX_CODEX_AUTH_DIR="$CLAUDEX_CONFIG_DIR/codex-accounts"
export PATH="$tmp/bin:$PATH"
mkdir -p "$tmp/bin" "$CODEX_HOME" "$CLAUDEX_CODEX_AUTH_DIR" "$CLAUDEX_CONFIG_DIR/usage-cache"

cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == 'cli_auth_credentials_store="file"' ]]; then
  shift 2
  [[ -z "${FAKE_CODEX_AUTH_ARGS_LOG:-}" ]] || printf 'file:%s\n' "$*" >> "$FAKE_CODEX_AUTH_ARGS_LOG"
  if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit "${FAKE_CODEX_FILE_STATUS:-${FAKE_CODEX_STATUS:-0}}"; fi
  if [[ "${1:-}" == login ]]; then exit "${FAKE_CODEX_LOGIN:-0}"; fi
  if [[ "${1:-}" == logout ]]; then exit "${FAKE_CODEX_FILE_LOGOUT:-${FAKE_CODEX_LOGOUT:-0}}"; fi
fi
if [[ "${1:-}" == login && "${2:-}" == status ]]; then
  [[ -z "${FAKE_CODEX_AUTH_ARGS_LOG:-}" ]] || printf '%s\n' 'default:login status' >> "$FAKE_CODEX_AUTH_ARGS_LOG"
  exit "${FAKE_CODEX_DEFAULT_STATUS:-${FAKE_CODEX_STATUS:-0}}"
fi
if [[ "${1:-}" == logout ]]; then
  [[ -z "${FAKE_CODEX_AUTH_ARGS_LOG:-}" ]] || printf '%s\n' 'default:logout' >> "$FAKE_CODEX_AUTH_ARGS_LOG"
  exit "${FAKE_CODEX_DEFAULT_LOGOUT:-${FAKE_CODEX_LOGOUT:-0}}"
fi
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

# Claudex deliberately owns a file-backed Codex session even when the user's
# normal Codex configuration points at the OS keyring. Every lifecycle command
# must therefore address the same file store.
auth_args_log="$tmp/codex-auth-args.log"
: > "$auth_args_log"
FAKE_CODEX_AUTH_ARGS_LOG="$auth_args_log" FAKE_CODEX_DEFAULT_STATUS=1 \
  FAKE_CODEX_FILE_STATUS=0 "$root/codex-session" status >/dev/null
[[ "$(<"$auth_args_log")" == 'file:login status' ]]
: > "$auth_args_log"
FAKE_CODEX_AUTH_ARGS_LOG="$auth_args_log" FAKE_CODEX_DEFAULT_LOGOUT=0 \
  FAKE_CODEX_FILE_LOGOUT=9 "$root/codex-session" logout >/dev/null 2>&1 || lifecycle_logout_status=$?
[[ "${lifecycle_logout_status:-0}" == 9 ]]
[[ "$(<"$auth_args_log")" == 'file:logout' ]]
unset lifecycle_logout_status
write_source_auth account-b access-b
"$root/codex-session" sync

# The managed projection should expose only a safe email claim from Codex's
# ID token. That makes the documented email selector work for the normal
# synchronized credential, and an old same-token projection must be upgraded.
managed_id_token='eyJhbGciOiJub25lIn0.eyJlbWFpbCI6Im1hbmFnZWRAZXhhbXBsZS5jb20ifQ.sig'
printf '{"auth_mode":"chatgpt","last_refresh":"2026-07-15T01:00:00.123456Z","tokens":{"access_token":"access-b","refresh_token":"refresh-account-b","id_token":"%s","account_id":"account-b"}}\n' \
  "$managed_id_token" > "$CODEX_HOME/auth.json"
jq 'del(.email)' "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" > "$tmp/old-projection.json"
mv "$tmp/old-projection.json" "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json"
"$root/codex-session" sync
jq -e '.email == "managed@example.com"' "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" >/dev/null
managed_accounts=$("$root/usage-limit" --accounts)
[[ "$managed_accounts" == *'managed@example.com'* ]]
"$root/usage-limit" --account managed@example.com >/dev/null
[[ "$(<"$CLAUDEX_CONFIG_DIR/codex-usage-account")" == codex-claudex-managed.json ]]
"$root/usage-limit" --account auto >/dev/null

# A worker that snapshotted an older credential must revalidate after it owns
# the publication lock. It may retry with the current source, but can never
# overwrite that source with its stale token set.
session_sync_lock="$CLAUDEX_CODEX_AUTH_DIR/.codex-session-sync.lock"
write_source_auth account-b access-stale
mkdir "$session_sync_lock"
printf '%s\n' "$$ held-by-test" > "$session_sync_lock/owner"
"$root/codex-session" sync & stale_sync_pid=$!
wait_for_session_temporary 'stale credential candidate publication'
write_source_auth account-b access-current
rm -rf "$session_sync_lock"
wait "$stale_sync_pid"
jq -e '.access_token == "access-current"' "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" >/dev/null

# A destructive sync decision is only valid once the worker owns publication.
# While a live publisher holds the lock, preserve its bridge and account state;
# if the source becomes valid before ownership transfers, publish that current
# source instead of applying the stale invalid decision.
mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache"
printf '%s\n' preserved > "$CLAUDEX_CONFIG_DIR/usage-cache/summary"
printf '%s\n' codex-claudex-managed.json > "$CLAUDEX_CONFIG_DIR/codex-usage-account"
printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":123,"refresh_token":"invalid","account_id":"account-b"}}' \
  > "$CODEX_HOME/auth.json"
mkdir "$session_sync_lock"
printf '%s\n' "$$ held-invalid-sync" > "$session_sync_lock/owner"
invalid_lock_ready="$tmp/serialized-invalid-lock-ready"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SESSION_SYNC_LOCK_WAIT_READY_FILE="$invalid_lock_ready" \
  "$root/codex-session" sync >"$tmp/serialized-invalid.out" 2>"$tmp/serialized-invalid.err" & serialized_invalid_pid=$!
wait_for_file "$invalid_lock_ready" 'invalid credential worker to reach the publication lock'
jq -e '.access_token == "access-current"' "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" >/dev/null
[[ -e "$CLAUDEX_CONFIG_DIR/usage-cache/summary" ]]
[[ -e "$CLAUDEX_CONFIG_DIR/codex-usage-account" ]]
write_source_auth account-b access-revalidated
rm -rf "$session_sync_lock"
wait "$serialized_invalid_pid"
jq -e '.access_token == "access-revalidated"' "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" >/dev/null

# Logout uses the same ownership boundary. It may perform Codex's logout first,
# but cannot delete the bridge or account-scoped state until the active
# publisher releases its generation.
mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache"
printf '%s\n' preserved > "$CLAUDEX_CONFIG_DIR/usage-cache/summary"
printf '%s\n' codex-claudex-managed.json > "$CLAUDEX_CONFIG_DIR/codex-usage-account"
mkdir "$session_sync_lock"
printf '%s\n' "$$ held-logout" > "$session_sync_lock/owner"
serialized_logout_args="$tmp/serialized-logout-args.log"
: > "$serialized_logout_args"
logout_lock_ready="$tmp/serialized-logout-lock-ready"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_SESSION_SYNC_LOCK_WAIT_READY_FILE="$logout_lock_ready" \
  FAKE_CODEX_AUTH_ARGS_LOG="$serialized_logout_args" \
  "$root/codex-session" logout >"$tmp/serialized-logout.out" 2>"$tmp/serialized-logout.err" & serialized_logout_pid=$!
wait_for_file "$logout_lock_ready" 'logout worker to reach the publication lock'
[[ ! -s "$serialized_logout_args" ]]
[[ -e "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" ]]
[[ -e "$CLAUDEX_CONFIG_DIR/usage-cache/summary" ]]
[[ -e "$CLAUDEX_CONFIG_DIR/codex-usage-account" ]]
rm -rf "$session_sync_lock"
wait "$serialized_logout_pid"
[[ "$(<"$serialized_logout_args")" == 'file:logout' ]]
[[ ! -e "$CLAUDEX_CODEX_AUTH_DIR/codex-claudex-managed.json" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/summary" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/codex-usage-account" ]]
write_source_auth account-b access-revalidated
"$root/codex-session" sync

# Catchable termination cannot strand the candidate credential beside the
# bridge file. The EXIT cleanup is shared by HUP, INT, and TERM handlers.
write_source_auth account-b access-interrupted
mkdir "$session_sync_lock"
printf '%s\n' "$$ held-by-test" > "$session_sync_lock/owner"
"$root/codex-session" sync & interrupted_sync_pid=$!
wait_for_session_temporary 'interruptible credential candidate publication'
kill -TERM "$interrupted_sync_pid"
if wait "$interrupted_sync_pid"; then
  printf '%s\n' 'terminated credential synchronization unexpectedly succeeded' >&2
  exit 1
fi
rm -rf "$session_sync_lock"
if find "$CLAUDEX_CODEX_AUTH_DIR" -maxdepth 1 -name '.codex-session.tmp.*' -print -quit | grep . >/dev/null; then
  printf '%s\n' 'terminated credential synchronization leaked a secret temporary' >&2
  exit 1
fi

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
sleep 30 & parent_pid=$!
CLAUDEX_AUTH_WATCH_SECONDS=1 CLAUDEX_AUTH_WATCH_READY_FILE="$tmp/watch-ready" \
  "$root/codex-session" watch "$parent_pid" & watcher_pid=$!
wait_for_file "$tmp/watch-ready" 'auth watcher initialization' 1
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
{"type":"codex","access_token":"token-a","account_id":"account-a","email":"a@example.com","last_refresh":"2026-07-15T02:00:00.900000Z"}
EOF
cat > "$CLAUDEX_CODEX_AUTH_DIR/codex-b.json" <<'EOF'
{"type":"codex","access_token":"token-b","account_id":"account-b","email":"b@example.com","last_refresh":"2026-07-15T03:00:00.100000Z"}
EOF
cat > "$CLAUDEX_CODEX_AUTH_DIR/codex-c.json" <<'EOF'
{"type":"codex","access_token":"token-c","account_id":"account-c","email":"c@example.com","last_refresh":"2026-07-15T03:00:00.100000Z"}
EOF
touch -t 202001010000 "$CLAUDEX_CODEX_AUTH_DIR/codex-a.json"
touch -t 203001010000 "$CLAUDEX_CODEX_AUTH_DIR/codex-c.json"

"$root/usage-limit" --account auto >/dev/null
ordered_accounts=$("$root/usage-limit" --accounts)
[[ "$(printf '%s\n' "$ordered_accounts" | sed -n '2p')" == '[*] 1. b@example.com' ]]
[[ "$(printf '%s\n' "$ordered_accounts" | sed -n '3p')" == '[ ] 2. c@example.com' ]]
[[ "$(printf '%s\n' "$ordered_accounts" | sed -n '4p')" == '[ ] 3. a@example.com' ]]
"$root/usage-limit" --account 2 >/dev/null
[[ "$(<"$CLAUDEX_CONFIG_DIR/codex-usage-account")" == codex-c.json ]]
"$root/usage-limit" --account auto >/dev/null

cat > "$tmp/bin/fake-curl" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_CURL_ARGUMENTS_FILE:-}" ]]; then
  printf '%s\n' "$@" > "$FAKE_CURL_ARGUMENTS_FILE"
fi
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

usage_url_error="$tmp/usage-url-error"
blocked_curl_arguments="$tmp/blocked-curl-arguments"
if CLAUDEX_USAGE_SOURCE=auto \
  CLAUDEX_USAGE_URL='http://127.0.0.1:8123/backend-api/wham/usage' \
  FAKE_CURL_ARGUMENTS_FILE="$blocked_curl_arguments" \
  "$root/usage-limit" --refresh-cache >/dev/null 2>"$usage_url_error"; then
  printf '%s\n' 'non-official production usage URL unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'CLAUDEX_USAGE_URL must remain https://chatgpt.com/backend-api/wham/usage' "$usage_url_error" >/dev/null
[[ ! -e "$blocked_curl_arguments" ]]

if CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL=1 \
  CLAUDEX_USAGE_URL='https://example.com/backend-api/wham/usage' \
  FAKE_CURL_ARGUMENTS_FILE="$blocked_curl_arguments" \
  "$root/usage-limit" --refresh-cache >/dev/null 2>"$usage_url_error"; then
  printf '%s\n' 'non-loopback test usage URL unexpectedly succeeded' >&2
  exit 1
fi
grep -F 'permits only loopback HTTP(S) usage endpoints' "$usage_url_error" >/dev/null
[[ ! -e "$blocked_curl_arguments" ]]

loopback_usage_url='http://127.0.0.1:8123/backend-api/wham/usage'
loopback_curl_arguments="$tmp/loopback-curl-arguments"
CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL=1 CLAUDEX_USAGE_URL="$loopback_usage_url" \
  FAKE_CURL_ARGUMENTS_FILE="$loopback_curl_arguments" \
  "$root/usage-limit" --refresh-cache >/dev/null
awk -v expected="$loopback_usage_url" '
  previous == "--" && $0 == expected { found = 1 }
  { previous = $0 }
  END { exit(found ? 0 : 1) }
' "$loopback_curl_arguments"

"$root/usage-limit" --account a@example.com >/dev/null
export FAKE_CURL_STARTED="$tmp/curl-started"
export FAKE_CURL_RELEASE="$tmp/curl-release"
"$root/usage-limit" --refresh-cache >"$tmp/old-refresh.out" 2>"$tmp/old-refresh.err" & old_refresh=$!
wait_for_file "$FAKE_CURL_STARTED" 'usage request credential capture' 1
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

# A crash after mkdir but before owner publication leaves an ownerless lock.
# Preserve the creation grace so a concurrent creator can finish publishing,
# then reclaim the same lock once that grace has actually elapsed.
mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
if "$root/usage-limit" --refresh-cache >"$tmp/fresh-ownerless.out" 2>"$tmp/fresh-ownerless.err"; then
  printf '%s\n' 'fresh ownerless usage lock was reclaimed before owner publication grace elapsed' >&2
  exit 1
fi
grep -F 'another usage refresh is already in progress' "$tmp/fresh-ownerless.err" >/dev/null
[[ -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
touch -t 202001010000 "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
"$root/usage-limit" --refresh-cache
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]

# The status line delegates lock mutation to the helper and records one launch
# attempt before detaching, so a live lock cannot cause a process storm.
mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' "$$ live-token-123" > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
printf '%s\n' "$(( $(date +%s) - 121 ))" > "$CLAUDEX_CONFIG_DIR/usage-cache/last-attempt"
statusline_refresh_exit="$tmp/statusline-refresh.exit"
printf '%s\n' '{"session_id":"lock-test","model":{"id":"gpt-5.6-sol"},"context_window":{"used_percentage":1}}' | \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_USAGE_REFRESH_EXIT_FILE="$statusline_refresh_exit" \
  CLAUDE_CONFIG_DIR="$CLAUDEX_CONFIG_DIR" CLAUDEX_USAGE_LIMIT_BIN="$root/usage-limit" "$root/statusline" >/dev/null
[[ -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
[[ "$(( $(date +%s) - $(<"$CLAUDEX_CONFIG_DIR/usage-cache/last-attempt") ))" -le 2 ]]
wait_for_file "$statusline_refresh_exit" 'detached statusline usage refresh completion' 1
printf '%s\n' '99999999 dead-token-123' > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
touch -t 202001010000 "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
"$root/usage-limit" --refresh-cache
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]

# A helper carrying an obsolete generation must never release a fresh lock.
mkdir -p "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' "$$ fresh-token-123" > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
if "$root/usage-limit" --refresh-cache --lock-held --lock-token stale-token-123 \
    >"$tmp/stale-helper.out" 2>"$tmp/stale-helper.err"; then
  printf '%s\n' 'obsolete lock generation unexpectedly refreshed usage' >&2
  exit 1
fi
grep -F 'no longer owned by this generation' "$tmp/stale-helper.err" >/dev/null
[[ "$(<"$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid")" == "$$ fresh-token-123" ]]
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"

# A live PID with a different process-start identity is a reused PID, not the
# lock owner. Reclaim only the exact recorded nonce and publish a new generation.
reuse_nonce='pid-reuse-generation-123'
test_identity='focused-test-owner-identity'
mkdir "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' "$reuse_nonce" > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation"
printf 'pid=%s\nidentity=%s\nnonce=%s\n' "$$" 'deliberately-wrong-identity' "$reuse_nonce" \
  > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
touch -t 202001010000 "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_REFRESH_PROCESS_IDENTITY="$test_identity" \
  "$root/usage-limit" --refresh-cache
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]

# Hard-link denial must use the CreateNew/O_EXCL publication fallback without
# weakening exact-generation ownership.
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_REFRESH_PROCESS_IDENTITY="$test_identity" \
  CLAUDEX_TEST_FORCE_REFRESH_HARDLINK_FAILURE=1 \
  "$root/usage-limit" --refresh-cache
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]

# A paused creator must not publish over B after B replaces A's directory.
ab_ready="$tmp/refresh-ab-ready"; ab_continue="$tmp/refresh-ab-continue"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_REFRESH_PROCESS_IDENTITY="$test_identity" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_MKDIR_READY_FILE="$ab_ready" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_MKDIR_CONTINUE_FILE="$ab_continue" \
  "$root/usage-limit" --refresh-cache >"$tmp/refresh-a.out" 2>"$tmp/refresh-a.err" & refresh_a_pid=$!
wait_for_file "$ab_ready" 'generation A mkdir pause'
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
mkdir "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' 'replacement-b-123' > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation"
printf 'pid=%s\nidentity=%s\nnonce=%s\n' "$$" "$test_identity" 'replacement-b-123' \
  > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
: > "$ab_continue"
if wait "$refresh_a_pid"; then
  printf '%s\n' 'paused refresh creator unexpectedly replaced generation B' >&2
  exit 1
fi
[[ "$(<"$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation")" == replacement-b-123 ]]
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"

# A mixed-version B can replace A's just-created directory and still be in the
# ownerless publication window. Stable directory identity must keep A from
# publishing into or removing that empty replacement.
empty_b_ready="$tmp/refresh-empty-b-ready"; empty_b_continue="$tmp/refresh-empty-b-continue"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_REFRESH_PROCESS_IDENTITY="$test_identity" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_MKDIR_READY_FILE="$empty_b_ready" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_MKDIR_CONTINUE_FILE="$empty_b_continue" \
  "$root/usage-limit" --refresh-cache >"$tmp/refresh-empty-b-a.out" 2>"$tmp/refresh-empty-b-a.err" & refresh_empty_b_a_pid=$!
wait_for_file "$empty_b_ready" 'empty replacement mkdir pause'
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
mkdir "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
: > "$empty_b_continue"
if wait "$refresh_empty_b_a_pid"; then
  printf '%s\n' 'paused refresh creator unexpectedly entered through an empty replacement directory' >&2
  exit 1
fi
[[ -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid" ]]
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"

# A mixed-version creator can replace A's empty directory with a prior
# "PID token" lock before A publishes. A may remove only its partial generation
# marker and must restore B's exact legacy record.
old_b_ready="$tmp/refresh-old-b-ready"; old_b_continue="$tmp/refresh-old-b-continue"
legacy_live_record="$$ legacy-live-owner-123"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_REFRESH_PROCESS_IDENTITY="$test_identity" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_MKDIR_READY_FILE="$old_b_ready" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_MKDIR_CONTINUE_FILE="$old_b_continue" \
  "$root/usage-limit" --refresh-cache >"$tmp/refresh-old-a.out" 2>"$tmp/refresh-old-a.err" & refresh_old_a_pid=$!
wait_for_file "$old_b_ready" 'legacy replacement mkdir pause'
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
mkdir "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' "$legacy_live_record" > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
: > "$old_b_continue"
if wait "$refresh_old_a_pid"; then
  printf '%s\n' 'paused refresh creator unexpectedly entered over a legacy replacement owner' >&2
  exit 1
fi
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation" ]]
[[ "$(<"$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid")" == "$legacy_live_record" ]]

# Age alone cannot steal an identity-less prior-format owner while its PID is
# live, whether the record is canonical or in a quarantine barrier. A dead
# prior-format owner is reclaimed after the short publication grace.
touch -t 202001010000 "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
if "$root/usage-limit" --refresh-cache >"$tmp/legacy-live.out" 2>"$tmp/legacy-live.err"; then
  printf '%s\n' 'aged live legacy usage owner was stolen' >&2
  exit 1
fi
[[ "$(<"$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid")" == "$legacy_live_record" ]]
mv "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" \
  "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock.quarantine.legacy-live"
printf '%s\n' 'injected-new-generation-123' \
  > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock.quarantine.legacy-live/generation"
touch -t 202001010000 "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock.quarantine.legacy-live"
if "$root/usage-limit" --refresh-cache >"$tmp/legacy-barrier.out" 2>"$tmp/legacy-barrier.err"; then
  printf '%s\n' 'aged live legacy usage barrier was stolen' >&2
  exit 1
fi
[[ -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock.quarantine.legacy-live" ]]
[[ ! -e "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation" ]]
printf '%s\n' '99999999 legacy-dead-owner-123' > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
touch -t 202001010000 "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
"$root/usage-limit" --refresh-cache
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]

# An owner moved to its own quarantine barrier after publication recovers that
# exact nonce before entering the refresh critical section.
self_ready="$tmp/refresh-self-ready"; self_continue="$tmp/refresh-self-continue"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_REFRESH_PROCESS_IDENTITY="$test_identity" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_PUBLISH_READY_FILE="$self_ready" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_PUBLISH_CONTINUE_FILE="$self_continue" \
  "$root/usage-limit" --refresh-cache >"$tmp/refresh-self.out" 2>"$tmp/refresh-self.err" & refresh_self_pid=$!
wait_for_file "$self_ready" 'owned generation publication pause'
mv "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" \
  "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock.quarantine.self-test"
: > "$self_continue"
wait "$refresh_self_pid"
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" ]]
[[ ! -d "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock.quarantine.self-test" ]]

# X may observe its nonce, then move replacement Y. The quarantine sibling
# blocks Z; exact moved-generation validation restores Y and X cannot delete it.
xy_before_ready="$tmp/refresh-xy-before-ready"; xy_before_continue="$tmp/refresh-xy-before-continue"
xy_after_ready="$tmp/refresh-xy-after-ready"; xy_after_continue="$tmp/refresh-xy-after-continue"
CLAUDEX_TEST_MODE=1 \
  CLAUDEX_TEST_REFRESH_PROCESS_IDENTITY="$test_identity" \
  CLAUDEX_TEST_REFRESH_LOCK_BEFORE_RENAME_READY_FILE="$xy_before_ready" \
  CLAUDEX_TEST_REFRESH_LOCK_BEFORE_RENAME_CONTINUE_FILE="$xy_before_continue" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_RENAME_READY_FILE="$xy_after_ready" \
  CLAUDEX_TEST_REFRESH_LOCK_AFTER_RENAME_CONTINUE_FILE="$xy_after_continue" \
  "$root/usage-limit" --refresh-cache >"$tmp/refresh-x.out" 2>"$tmp/refresh-x.err" & refresh_x_pid=$!
wait_for_file "$xy_before_ready" 'generation X pre-rename pause'
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
mkdir "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock"
printf '%s\n' 'replacement-y-123' > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation"
printf 'pid=%s\nidentity=%s\nnonce=%s\n' "$$" "$test_identity" 'replacement-y-123' \
  > "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/owner-pid"
: > "$xy_before_continue"
wait_for_file "$xy_after_ready" 'generation X post-rename pause'
z_contended_ready="$tmp/refresh-z-contended-ready"
CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_REFRESH_LOCK_CONTENDED_READY_FILE="$z_contended_ready" \
  "$root/usage-limit" --refresh-cache >"$tmp/refresh-z.out" 2>"$tmp/refresh-z.err" & refresh_z_pid=$!
wait_for_file "$z_contended_ready" 'generation Z to observe the quarantine barrier'
if [[ -r "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation" ]]; then
  [[ "$(<"$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation")" == replacement-y-123 ]]
else
  replacement_y_barrier=$(grep -l '^replacement-y-123$' \
    "$CLAUDEX_CONFIG_DIR"/usage-cache/refresh.lock.quarantine.*/generation 2>/dev/null | head -1 || true)
  [[ -n "$replacement_y_barrier" ]]
fi
: > "$xy_after_continue"
wait "$refresh_x_pid"
if wait "$refresh_z_pid"; then
  printf '%s\n' 'generation Z unexpectedly entered while replacement Y was live' >&2
  exit 1
fi
[[ "$(<"$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock/generation")" == replacement-y-123 ]]
rm -rf "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock" \
  "$CLAUDEX_CONFIG_DIR/usage-cache/refresh.lock.quarantine.$refresh_x_pid".*

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
if (( deadline_elapsed > 20 )); then
  printf 'shared app-server deadline exceeded the 20s test budget: %ss\n' "$deadline_elapsed" >&2
  exit 1
fi

child_file="$tmp/appserver-child"
if FAKE_APP_SERVER_MODE=noisy FAKE_APP_SERVER_CHILD_FILE="$child_file" \
    CLAUDEX_USAGE_SOURCE=app-server CLAUDEX_USAGE_TIMEOUT_SECONDS=1 \
    "$root/usage-limit" --refresh-cache >/dev/null 2>"$tmp/noisy.err"; then
  printf '%s\n' 'non-responsive app-server unexpectedly succeeded' >&2
  exit 1
fi
[[ -s "$child_file" ]]
child_pid=$(<"$child_file")
wait_for_process_exit "$child_pid" 'timed-out app-server descendant'
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
grep -F 'function Publish-RefreshLockFile' "$root/usage-limit.ps1" >/dev/null
grep -F '[IO.FileMode]::CreateNew' "$root/usage-limit.ps1" >/dev/null
grep -F 'function Remove-OwnedRefreshGeneration' "$root/usage-limit.ps1" >/dev/null
grep -F 'function Recover-OwnedRefreshGeneration' "$root/usage-limit.ps1" >/dev/null
grep -F 'Start-UsageRefreshWithoutPrivateEnvironment' "$root/statusline.ps1" >/dev/null
! grep -F -- '-LockHeld' "$root/statusline.ps1" >/dev/null
grep -F '[Claudex.CappedTextReader]::DrainAsync' "$root/usage-limit.ps1" >/dev/null
grep -F 'taskkill.exe /PID' "$root/usage-limit.ps1" >/dev/null
grep -F 'function Assert-SafeUsageUrl' "$root/usage-limit.ps1" >/dev/null
grep -F 'CLAUDEX_INSECURE_TEST_ALLOW_USAGE_URL permits only loopback HTTP(S) usage endpoints.' "$root/usage-limit.ps1" >/dev/null
grep -F -- '--config $curlConfig -- $usageUrl' "$root/usage-limit.ps1" >/dev/null
grep -F 'Protect-PrivatePath $bridgeAuthFile $false' "$root/codex-session.ps1" >/dev/null
grep -F 'function Acquire-SessionSyncLock' "$root/codex-session.ps1" >/dev/null
grep -F 'if ($currentFingerprint -ne $sourceFingerprint) { continue }' "$root/codex-session.ps1" >/dev/null
grep -F 'function Clear-SensitiveSessionState' "$root/codex-session.ps1" >/dev/null
grep -F 'CredentialSyncCleanup' "$root/codex-session.ps1" >/dev/null
grep -F 'AppDomain.CurrentDomain.ProcessExit' "$root/codex-session.ps1" >/dev/null
grep -F 'Console.CancelKeyPress' "$root/codex-session.ps1" >/dev/null
grep -F 'RefreshTicks = $refreshTicks' "$root/usage-limit.ps1" >/dev/null
grep -F 'Sort-Object -Property $sortProperties' "$root/usage-limit.ps1" >/dev/null

printf '%s\n' 'auth/usage regressions passed'
