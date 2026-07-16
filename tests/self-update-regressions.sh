#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
readonly temporary="$(mktemp -d "${TMPDIR:-/tmp}/claudex-self-update-test.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
readonly home="$temporary/home"
readonly config="$home/.config/claudex"
readonly fixtures="$temporary/fixtures"
readonly fake_bin="$temporary/bin"
mkdir -p "$config" "$fixtures" "$fake_bin"

cat > "$config/install.json" <<'EOF'
{"schema":1,"version":"1.3.1","method":"npm","binDir":"/tmp/unused","repository":"BeamoINT/Claudex"}
EOF
cat > "$fixtures/release.json" <<'EOF'
{"tag_name":"v1.3.2","draft":false,"prerelease":false}
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output="" url=""
while (( $# > 0 )); do
  case "$1" in --output) output="$2"; shift ;; http*) url="$1" ;; esac
  shift
done
[[ -n "$output" && -n "$url" ]]
if [[ "${FAKE_CURL_FAIL:-0}" == 1 ]]; then exit 7; fi
case "$url" in
  */releases/latest) cp "$FAKE_FIXTURES/release.json" "$output" ;;
  */SHA256SUMS) cp "$FAKE_FIXTURES/SHA256SUMS" "$output" ;;
  *.tar.gz) cp "$FAKE_FIXTURES/release.tar.gz" "$output" ;;
  *) exit 22 ;;
esac
printf '%s' "$url"
EOF
cat > "$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_NPM_LOG"
EOF
cat > "$fake_bin/claudex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --package-version) printf '%s\n' 1.3.2 ;;
  --package-setup)
    temporary="$CLAUDEX_CONFIG_DIR/.install.json.$$"
    jq '.version = "1.3.2"' "$CLAUDEX_CONFIG_DIR/install.json" > "$temporary"
    mv -f "$temporary" "$CLAUDEX_CONFIG_DIR/install.json"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fake_bin/curl" "$fake_bin/npm" "$fake_bin/claudex"

export HOME="$home" PATH="$fake_bin:$PATH" CLAUDEX_CONFIG_DIR="$config" CLAUDEX_CURL_BIN="$fake_bin/curl"
export FAKE_FIXTURES="$fixtures" FAKE_NPM_LOG="$temporary/npm.log"

check_output=$("$root/self-update" --check)
[[ "$check_output" == *'Claudex 1.3.2 is available'* ]]
jq -e '.currentVersion == "1.3.1" and .availableVersion == "1.3.2" and .failureCount == 0' \
  "$config/update/claudex/state.json" >/dev/null

status_output=$("$root/self-update" --status)
[[ "$status_output" == *'Claudex: 1.3.1'* && "$status_output" == *'Install method: npm'* && "$status_output" == *'Available: 1.3.2'* ]]

# A contending updater must not fall through and apply cached state without
# owning the update lock.
mkdir -p "$config/update/claudex/lock"
printf '%s\n' "$$" > "$config/update/claudex/lock/owner"
before_manager_calls=0
[[ ! -r "$temporary/npm.log" ]] || before_manager_calls=$(wc -l < "$temporary/npm.log" | tr -d ' ')
"$root/self-update" --apply >/dev/null
after_manager_calls=0
[[ ! -r "$temporary/npm.log" ]] || after_manager_calls=$(wc -l < "$temporary/npm.log" | tr -d ' ')
[[ "$after_manager_calls" == "$before_manager_calls" ]]
rm -rf "$config/update/claudex/lock"

"$root/self-update" --apply >/dev/null
grep -Fx 'install --global claudex-codex@1.3.2' "$temporary/npm.log" >/dev/null

# A prerelease is never accepted on the stable channel.
cat > "$fixtures/release.json" <<'EOF'
{"tag_name":"v2.0.0-beta.1","draft":false,"prerelease":true}
EOF
if "$root/self-update" --check >"$temporary/prerelease.stdout" 2>"$temporary/prerelease.stderr"; then
  printf '%s\n' 'expected prerelease metadata to be rejected' >&2
  exit 1
fi

# Offline background checks are silent and write a bounded retry time instead
# of retrying on every launch.
export FAKE_CURL_FAIL=1 CLAUDEX_UPDATE_BACKGROUND=1
"$root/self-update" --check --background >"$temporary/offline.stdout" 2>"$temporary/offline.stderr" || true
[[ ! -s "$temporary/offline.stdout" && ! -s "$temporary/offline.stderr" ]]
jq -e '.failureCount >= 1 and .nextAttemptAt > .lastCheckedAt' "$config/update/claudex/state.json" >/dev/null

# Unsafe archive paths are rejected before the installer can run.
unset FAKE_CURL_FAIL CLAUDEX_UPDATE_BACKGROUND
cat > "$config/install.json" <<EOF
{"schema":1,"version":"1.3.1","method":"archive","binDir":"$temporary/install-bin","repository":"BeamoINT/Claudex"}
EOF
cat > "$fixtures/release.json" <<'EOF'
{"tag_name":"v1.3.2","draft":false,"prerelease":false}
EOF
mkdir -p "$temporary/archive-source/claudex-1.3.2"
ln -s ../../outside "$temporary/archive-source/claudex-1.3.2/unsafe-link"
tar -czf "$fixtures/release.tar.gz" -C "$temporary/archive-source" claudex-1.3.2
if command -v sha256sum >/dev/null 2>&1; then digest=$(sha256sum "$fixtures/release.tar.gz" | awk '{print $1}')
else digest=$(shasum -a 256 "$fixtures/release.tar.gz" | awk '{print $1}'); fi
printf '%s  %s\n' "$digest" 'claudex-1.3.2.tar.gz' > "$fixtures/SHA256SUMS"
if "$root/self-update" --apply >"$temporary/unsafe.stdout" 2>"$temporary/unsafe.stderr"; then
  printf '%s\n' 'expected unsafe release archive to be rejected' >&2
  exit 1
fi
grep -F 'unsafe paths or file types' "$temporary/unsafe.stderr" >/dev/null
[[ ! -e "$temporary/payload" ]]

# A failed archive installer restores every prior managed file and removes any
# managed file that did not exist before the attempt.
rm -rf "$temporary/archive-source"
mkdir -p "$temporary/archive-source/claudex-1.3.2" "$temporary/install-bin"
printf '%s\n' old-statusline > "$config/statusline"
rm -f "$config/self-update"
cat > "$temporary/archive-source/claudex-1.3.2/package.json" <<'EOF'
{"version":"1.3.2"}
EOF
cat > "$temporary/archive-source/claudex-1.3.2/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' partial-statusline > "$CLAUDEX_CONFIG_DIR/statusline"
printf '%s\n' partial-updater > "$CLAUDEX_CONFIG_DIR/self-update"
exit 23
EOF
cat > "$temporary/archive-source/claudex-1.3.2/claudex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$temporary/archive-source/claudex-1.3.2/self-update" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$temporary/archive-source/claudex-1.3.2/install.sh" \
  "$temporary/archive-source/claudex-1.3.2/claudex" \
  "$temporary/archive-source/claudex-1.3.2/self-update"
tar -czf "$fixtures/release.tar.gz" -C "$temporary/archive-source" claudex-1.3.2
if command -v sha256sum >/dev/null 2>&1; then digest=$(sha256sum "$fixtures/release.tar.gz" | awk '{print $1}')
else digest=$(shasum -a 256 "$fixtures/release.tar.gz" | awk '{print $1}'); fi
printf '%s  %s\n' "$digest" 'claudex-1.3.2.tar.gz' > "$fixtures/SHA256SUMS"
if "$root/self-update" --apply >"$temporary/rollback.stdout" 2>"$temporary/rollback.stderr"; then
  printf '%s\n' 'expected failed archive installer to roll back' >&2
  exit 1
fi
grep -F 'restored the previous managed files' "$temporary/rollback.stderr" >/dev/null
[[ "$(<"$config/statusline")" == old-statusline ]]
[[ ! -e "$config/self-update" ]]

printf '%s\n' 'self-update regressions passed'
