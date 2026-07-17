#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/claudex-session-lock.XXXXXX")
trap 'jobs -pr | xargs kill 2>/dev/null || true; rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export CODEX_HOME="$HOME/.codex"
export CLAUDEX_CONFIG_DIR="$HOME/.config/claudex"
export CLAUDEX_CODEX_AUTH_DIR="$CLAUDEX_CONFIG_DIR/codex-accounts"
export PATH="$tmp/bin:$PATH"
lock="$CLAUDEX_CODEX_AUTH_DIR/.codex-session-sync.lock"
mkdir -p "$tmp/bin" "$CODEX_HOME" "$CLAUDEX_CODEX_AUTH_DIR"

cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -c && "${2:-}" == 'cli_auth_credentials_store="file"' && "${3:-}" == login && "${4:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == -c && "${2:-}" == 'cli_auth_credentials_store="file"' && "${3:-}" == logout ]]; then exit 0; fi
exit 2
EOF
chmod +x "$tmp/bin/codex"

write_auth() {
  printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"access","refresh_token":"refresh","account_id":"account"}}' > "$CODEX_HOME/auth.json"
}

wait_file() {
  local path="$1" attempts="${2:-400}"
  for (( i=0; i<attempts; i++ )); do [[ -e "$path" ]] && return 0; sleep 0.02; done
  printf 'timed out waiting for %s\n' "$path" >&2
  return 1
}

nonce_at() { awk -F= '$1 == "nonce" { print $2; exit }' "$1/owner"; }
directory_identity() {
  if stat -f '%d:%i' "$1" >/dev/null 2>&1; then stat -f '%d:%i' "$1"
  else stat -c '%d:%i' "$1"; fi
}
legacy_owner_without_generation_exists() {
  local expected="$1" directory owner
  for directory in "$lock" "$lock".quarantine.*; do
    [[ -r "$directory/owner" ]] || continue
    IFS= read -r owner < "$directory/owner" || owner=""
    [[ "$owner" == "$expected" && ! -e "$directory/generation" ]] && return 0
  done
  return 1
}
wait_legacy_owner_without_generation() {
  local expected="$1"
  for (( i=0; i<400; i++ )); do
    legacy_owner_without_generation_exists "$expected" && return 0
    sleep 0.02
  done
  printf 'timed out waiting for sanitized legacy owner %s\n' "$expected" >&2
  return 1
}
base=(CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_PROCESS_IDENTITY=session-lock-test CLAUDEX_TEST_LOCK_MATCH=.codex-session-sync.lock)
write_auth

# Filesystems without hardlink support still publish generation and owner with
# O_EXCL/CreateNew semantics, then release the exact generation cleanly.
env "${base[@]}" CLAUDEX_TEST_FORCE_HARDLINK_FAILURE=1 "$root/codex-session" sync
[[ ! -e "$lock" ]] && ! compgen -G "$lock.quarantine.*" >/dev/null

# A live recycled PID with a different start identity is stale and reclaimable.
mkdir "$lock"
printf '%s\n' pid-reuse > "$lock/generation"
printf 'pid=%s\nidentity=old-process-start\nnonce=pid-reuse\n' "$$" > "$lock/owner"
touch -t 200001010000 "$lock"
env "${base[@]}" "$root/codex-session" sync
[[ ! -e "$lock" ]]

# Ownerless and generation-only partial publications are reclaimed only after
# their grace period and leave neither canonical nor quarantine debris.
mkdir "$lock"
touch -t 200001010000 "$lock"
env "${base[@]}" "$root/codex-session" sync
[[ ! -e "$lock" ]]
mkdir "$lock"
printf '%s\n' partial-generation > "$lock/generation"
touch -t 200001010000 "$lock"
env "${base[@]}" "$root/codex-session" sync
[[ ! -e "$lock" ]] && ! compgen -G "$lock.quarantine.*" >/dev/null

# Mixed-version compatibility: v1.5.8 published a single `PID token` owner
# record. A live legacy owner remains authoritative even when its directory is
# old; a dead legacy owner is reclaimed only after the conservative grace.
mkdir "$lock"
printf '%s %s\n' "$$" live-legacy-canonical > "$lock/owner"
touch -t 200001010000 "$lock"
env "${base[@]}" "$root/codex-session" sync >"$tmp/legacy-live.out" 2>"$tmp/legacy-live.err" & legacy_live=$!
sleep 0.25
kill -0 "$legacy_live"
[[ "$(<"$lock/owner")" == "$$ live-legacy-canonical" ]]
kill -TERM "$legacy_live"
wait "$legacy_live" || true
rm -rf "$lock"

mkdir "$lock"
printf '%s\n' '99999999 dead-legacy-canonical' > "$lock/owner"
touch -t 200001010000 "$lock"
env "${base[@]}" "$root/codex-session" sync
[[ ! -e "$lock" ]]

# Quarantined legacy owners are also barriers: live owners are restored to the
# canonical path, foreign new generations are withdrawn, and the same owner is
# reclaimable after it dies and the conservative grace has elapsed.
legacy_barrier="$lock.quarantine.mixed-version-live"
sleep 300 & legacy_owner_process=$!
mkdir "$legacy_barrier"
printf '%s %s\n' "$legacy_owner_process" live-legacy-barrier > "$legacy_barrier/owner"
printf '%s\n' injected-new-generation > "$legacy_barrier/generation"
touch -t 200001010000 "$legacy_barrier"
env "${base[@]}" "$root/codex-session" sync >"$tmp/legacy-barrier.out" 2>"$tmp/legacy-barrier.err" & legacy_barrier_waiter=$!
sleep 0.25
kill -0 "$legacy_barrier_waiter"
wait_legacy_owner_without_generation "$legacy_owner_process live-legacy-barrier"
kill -TERM "$legacy_barrier_waiter"
wait "$legacy_barrier_waiter" || true
kill -TERM "$legacy_owner_process"
wait "$legacy_owner_process" || true
if [[ -d "$lock" ]]; then touch -t 200001010000 "$lock"
else touch -t 200001010000 "$legacy_barrier"; fi
env "${base[@]}" "$root/codex-session" sync
[[ ! -e "$lock" ]] && ! compgen -G "$lock.quarantine.*" >/dev/null

# New A pauses after mkdir; prior-version B replaces the directory and writes
# `PID token`; A resumes and must neither delete B nor leave its partial
# generation attached to B when owner publication loses the race.
env "${base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/mixed-a-ready" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/mixed-a-continue" \
  "$root/codex-session" sync >"$tmp/mixed-a.out" 2>"$tmp/mixed-a.err" & mixed_a=$!
wait_file "$tmp/mixed-a-ready"
rm -rf "$lock"
mkdir "$lock"
printf '%s %s\n' "$$" mixed-version-b > "$lock/owner"
: > "$tmp/mixed-a-continue"
sleep 0.25
kill -0 "$mixed_a"
wait_legacy_owner_without_generation "$$ mixed-version-b"
kill -TERM "$mixed_a"
wait "$mixed_a" || true
rm -rf "$lock" "$lock".quarantine.*

# Stronger absent-owner ABA: old B replaces paused new A's mkdir result, then
# itself pauses before writing its historical owner. A must notice the stable
# directory identity changed before publishing and must not clean up B's empty
# replacement on its failure path.
env "${base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/empty-a-ready" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/empty-a-continue" \
  "$root/codex-session" sync >"$tmp/empty-a.out" 2>"$tmp/empty-a.err" & empty_a=$!
wait_file "$tmp/empty-a-ready"
mv "$lock" "$tmp/empty-a-original-directory"
mkdir "$lock"
empty_b_identity=$(directory_identity "$lock")
: > "$tmp/empty-a-continue"
sleep 0.25
kill -0 "$empty_a"
[[ -d "$lock" && ! -e "$lock/generation" && ! -e "$lock/owner" ]]
[[ "$(directory_identity "$lock")" == "$empty_b_identity" ]]
printf '%s %s\n' "$$" empty-window-b > "$lock/owner"
wait_legacy_owner_without_generation "$$ empty-window-b"
[[ "$(directory_identity "$lock")" == "$empty_b_identity" ]]
kill -TERM "$empty_a"
wait "$empty_a" || true
rm -rf "$lock" "$lock".quarantine.* "$tmp/empty-a-original-directory"

# A/B publication ABA: A pauses after mkdir, B reclaims that incomplete stale
# directory and publishes B, and A may never overwrite or release B.
env "${base[@]}" CLAUDEX_TEST_LOCK_AFTER_MKDIR_READY="$tmp/a-ready" \
  CLAUDEX_TEST_LOCK_AFTER_MKDIR_CONTINUE="$tmp/a-continue" \
  "$root/codex-session" sync >"$tmp/a.out" 2>"$tmp/a.err" & a=$!
wait_file "$tmp/a-ready"
touch -t 200001010000 "$lock"
env "${base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/b-ready" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/b-continue" \
  "$root/codex-session" sync >"$tmp/b.out" 2>"$tmp/b.err" & b=$!
wait_file "$tmp/b-ready"
b_nonce=$(nonce_at "$lock")
: > "$tmp/a-continue"
wait "$a" || true
[[ "$(nonce_at "$lock")" == "$b_nonce" ]]
: > "$tmp/b-continue"
wait "$b"

# X/Y/Z rename ABA: stale remover X pauses around quarantine rename, Y owns the
# moved generation, and Z must remain behind the barrier until Y is restored.
rm -rf "$lock" "$lock".quarantine.*
mkdir "$lock"
printf '%s\n' x > "$lock/generation"
printf 'pid=99999999\nidentity=dead\nnonce=x\n' > "$lock/owner"
touch -t 200001010000 "$lock"
env "${base[@]}" CLAUDEX_TEST_LOCK_BEFORE_RENAME_READY="$tmp/x-before" \
  CLAUDEX_TEST_LOCK_BEFORE_RENAME_CONTINUE="$tmp/x-before-continue" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_READY="$tmp/x-after" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_CONTINUE="$tmp/x-after-continue" \
  "$root/codex-session" sync >"$tmp/x.out" 2>"$tmp/x.err" & x=$!
wait_file "$tmp/x-before"
env "${base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/y-ready" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/y-continue" \
  "$root/codex-session" sync >"$tmp/y.out" 2>"$tmp/y.err" & y=$!
wait_file "$tmp/y-ready"
y_nonce=$(nonce_at "$lock")
: > "$tmp/x-before-continue"
wait_file "$tmp/x-after"
env "${base[@]}" "$root/codex-session" sync >"$tmp/z.out" 2>"$tmp/z.err" & z=$!
wait "$z" || true
[[ "$(nonce_at "$lock")" == "$y_nonce" ]]
: > "$tmp/x-after-continue"
wait "$x" || true
: > "$tmp/y-continue"
wait "$y"

# If X pauses after moving Y, Y recognizes and restores only its own nonce.
rm -rf "$lock" "$lock".quarantine.*
mkdir "$lock"
printf '%s\n' x-self > "$lock/generation"
printf 'pid=99999999\nidentity=dead\nnonce=x-self\n' > "$lock/owner"
touch -t 200001010000 "$lock"
env "${base[@]}" CLAUDEX_TEST_LOCK_BEFORE_RENAME_READY="$tmp/sx-before" \
  CLAUDEX_TEST_LOCK_BEFORE_RENAME_CONTINUE="$tmp/sx-before-continue" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_READY="$tmp/sx-after" \
  CLAUDEX_TEST_LOCK_AFTER_RENAME_CONTINUE="$tmp/sx-after-continue" \
  "$root/codex-session" sync >"$tmp/sx.out" 2>"$tmp/sx.err" & sx=$!
wait_file "$tmp/sx-before"
env "${base[@]}" CLAUDEX_TEST_LOCK_AFTER_PUBLISH_READY="$tmp/sy-ready" \
  CLAUDEX_TEST_LOCK_AFTER_PUBLISH_CONTINUE="$tmp/sy-continue" \
  CLAUDEX_TEST_LOCK_SELF_RECOVERED_FILE="$tmp/sy-recovered" \
  "$root/codex-session" sync >"$tmp/sy.out" 2>"$tmp/sy.err" & sy=$!
wait_file "$tmp/sy-ready"
: > "$tmp/sx-before-continue"
wait_file "$tmp/sx-after"
: > "$tmp/sy-continue"
wait_file "$tmp/sy-recovered"
wait "$sy"
: > "$tmp/sx-after-continue"
wait "$sx" || true
[[ ! -e "$lock" ]] && ! compgen -G "$lock.quarantine.*" >/dev/null

printf '%s\n' 'codex session generation-lock regressions passed'
