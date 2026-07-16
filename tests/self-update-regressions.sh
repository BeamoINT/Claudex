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
{"schema":1,"version":"1.3.1","method":"homebrew","binDir":"/tmp/unused","repository":"BeamoINT/Claudex"}
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
cat > "$fake_bin/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_BREW_LOG"
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
chmod +x "$fake_bin/curl" "$fake_bin/brew" "$fake_bin/claudex"

export HOME="$home" PATH="$fake_bin:$PATH" CLAUDEX_CONFIG_DIR="$config" CLAUDEX_CURL_BIN="$fake_bin/curl"
export FAKE_FIXTURES="$fixtures" FAKE_BREW_LOG="$temporary/brew.log"

check_output=$("$root/self-update" --check)
[[ "$check_output" == *'Claudex 1.3.2 is available'* ]]
jq -e '.currentVersion == "1.3.1" and .availableVersion == "1.3.2" and .failureCount == 0' \
  "$config/update/claudex/state.json" >/dev/null

status_output=$("$root/self-update" --status)
[[ "$status_output" == *'Claudex: 1.3.1'* && "$status_output" == *'Install method: homebrew'* && "$status_output" == *'Available: 1.3.2'* ]]

# A contending updater must not fall through and apply cached state without
# owning the update lock.
mkdir -p "$config/update/claudex/lock"
printf '%s\n' "$$" > "$config/update/claudex/lock/owner"
before_manager_calls=0
[[ ! -r "$temporary/brew.log" ]] || before_manager_calls=$(wc -l < "$temporary/brew.log" | tr -d ' ')
"$root/self-update" --apply >/dev/null
after_manager_calls=0
[[ ! -r "$temporary/brew.log" ]] || after_manager_calls=$(wc -l < "$temporary/brew.log" | tr -d ' ')
[[ "$after_manager_calls" == "$before_manager_calls" ]]
rm -rf "$config/update/claudex/lock"

"$root/self-update" --apply >/dev/null
grep -Fx 'upgrade beamoint/tap/claudex' "$temporary/brew.log" >/dev/null

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

# A checksum-valid archive without the now-required bridge is rejected before
# any installer or managed file can run.
rm -rf "$temporary/archive-source"
mkdir -p "$temporary/archive-source/claudex-1.3.2"
printf '%s\n' '{"version":"1.3.2"}' > "$temporary/archive-source/claudex-1.3.2/package.json"
for script in install.sh claudex self-update; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$temporary/archive-source/claudex-1.3.2/$script"
  chmod +x "$temporary/archive-source/claudex-1.3.2/$script"
done
tar -czf "$fixtures/release.tar.gz" -C "$temporary/archive-source" claudex-1.3.2
if command -v sha256sum >/dev/null 2>&1; then digest=$(sha256sum "$fixtures/release.tar.gz" | awk '{print $1}')
else digest=$(shasum -a 256 "$fixtures/release.tar.gz" | awk '{print $1}'); fi
printf '%s  %s\n' "$digest" 'claudex-1.3.2.tar.gz' > "$fixtures/SHA256SUMS"
if "$root/self-update" --apply >"$temporary/missing-bridge.stdout" 2>"$temporary/missing-bridge.stderr"; then
  printf '%s\n' 'expected release without a skill bridge to be rejected' >&2
  exit 1
fi
grep -F 'release archive is missing its skill bridge' "$temporary/missing-bridge.stderr" >/dev/null

# Every shipped shell entrypoint is syntax-checked as its own script. Passing
# additional paths to one `bash -n` invocation only treats them as arguments
# and previously allowed a broken launcher to be installed.
rm -rf "$temporary/archive-source"
mkdir -p "$temporary/archive-source/claudex-1.3.2"
printf '%s\n' '{"version":"1.3.2"}' > "$temporary/archive-source/claudex-1.3.2/package.json"
for script in bootstrap.sh install.sh codex-session self-update statusline usage-limit; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$temporary/archive-source/claudex-1.3.2/$script"
done
printf '%s\n' '#!/bin/sh' 'exit 0' > "$temporary/archive-source/claudex-1.3.2/install.zsh"
printf '%s\n' '#!/usr/bin/env bash' 'if then' > "$temporary/archive-source/claudex-1.3.2/claudex"
printf '%s\n' "'use strict';" > "$temporary/archive-source/claudex-1.3.2/skill-bridge.cjs"
chmod +x "$temporary/archive-source/claudex-1.3.2/"{bootstrap.sh,install.sh,install.zsh,claudex,codex-session,self-update,statusline,usage-limit}
tar -czf "$fixtures/release.tar.gz" -C "$temporary/archive-source" claudex-1.3.2
if command -v sha256sum >/dev/null 2>&1; then digest=$(sha256sum "$fixtures/release.tar.gz" | awk '{print $1}')
else digest=$(shasum -a 256 "$fixtures/release.tar.gz" | awk '{print $1}'); fi
printf '%s  %s\n' "$digest" 'claudex-1.3.2.tar.gz' > "$fixtures/SHA256SUMS"
if "$root/self-update" --apply >"$temporary/syntax.stdout" 2>"$temporary/syntax.stderr"; then
  printf '%s\n' 'expected a syntax-broken launcher to be rejected' >&2
  exit 1
fi
grep -F 'release shell entrypoint failed validation: claudex' "$temporary/syntax.stderr" >/dev/null

# A failed archive installer restores every prior managed file and removes any
# managed file that did not exist before the attempt.
rm -rf "$temporary/archive-source"
mkdir -p "$temporary/archive-source/claudex-1.3.2" "$temporary/install-bin"
printf '%s\n' old-statusline > "$config/statusline"
rm -f "$config/self-update" "$config/skill-bridge.cjs"
cat > "$temporary/archive-source/claudex-1.3.2/package.json" <<'EOF'
{"version":"1.3.2"}
EOF
cat > "$temporary/archive-source/claudex-1.3.2/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' partial-statusline > "$CLAUDEX_CONFIG_DIR/statusline"
printf '%s\n' partial-updater > "$CLAUDEX_CONFIG_DIR/self-update"
printf '%s\n' partial-skill-bridge > "$CLAUDEX_CONFIG_DIR/skill-bridge.cjs"
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
for script in bootstrap.sh codex-session statusline usage-limit; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$temporary/archive-source/claudex-1.3.2/$script"
done
printf '%s\n' '#!/bin/sh' 'exit 0' > "$temporary/archive-source/claudex-1.3.2/install.zsh"
cat > "$temporary/archive-source/claudex-1.3.2/skill-bridge.cjs" <<'EOF'
'use strict';
EOF
chmod +x "$temporary/archive-source/claudex-1.3.2/install.sh" \
  "$temporary/archive-source/claudex-1.3.2/claudex" \
  "$temporary/archive-source/claudex-1.3.2/self-update" \
  "$temporary/archive-source/claudex-1.3.2/bootstrap.sh" \
  "$temporary/archive-source/claudex-1.3.2/codex-session" \
  "$temporary/archive-source/claudex-1.3.2/statusline" \
  "$temporary/archive-source/claudex-1.3.2/usage-limit" \
  "$temporary/archive-source/claudex-1.3.2/install.zsh"
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
[[ ! -e "$config/skill-bridge.cjs" ]]

printf '%s\n' 'self-update regressions passed'
