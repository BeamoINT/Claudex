#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
readonly temporary="$(mktemp -d "${TMPDIR:-/tmp}/claudex-installer-test.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
readonly home="$temporary/home"
readonly config="$home/.config/claudex"
readonly fake_bin="$temporary/bin"
mkdir -p "$config/bin" "$home/.codex" "$fake_bin"

cat > "$home/.codex/auth.json" <<'EOF'
{"auth_mode":"chatgpt","tokens":{"access_token":"test-access","refresh_token":"test-refresh","account_id":"test-account"}}
EOF
cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == -c && "${3:-}" == login ]]; then
  [[ -z "${FAKE_CODEX_LOGIN_LOG:-}" ]] || printf '%s\n' login >> "$FAKE_CODEX_LOGIN_LOG"
  exit 0
fi
exit 2
EOF
cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != update ]] || exit 0
exit 0
EOF
cat > "$config/bin/cliproxyapi" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -version ]] && { printf '%s\n' 'Version: 7.2.80'; exit 0; }
exit 0
EOF
chmod +x "$fake_bin/codex" "$fake_bin/claude" "$config/bin/cliproxyapi"

installer_env=(
  HOME="$home"
  PATH="$fake_bin:$PATH"
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1
  CLAUDEX_SKIP_SERVICE_START=1
)
env "${installer_env[@]}" CLAUDEX_PROXY_TOKEN=stable-installer-token "$root/install.sh" >/dev/null

# Reinstalling must replace every shell-valid spelling of a managed assignment,
# not leave an exported/indented duplicate that wins when the env file is
# sourced later. The explicit repair token must remain identical in both the
# shell env and the generated proxy YAML.
cat >> "$config/env" <<EOF
  export CLAUDEX_PROXY_TOKEN=stale-export-token
	export CLAUDEX_PROXY_URL=http://127.0.0.1:8318
 export CLAUDEX_PROXY_CONFIG=$config/cliproxyapi.yaml
    CLAUDEX_PROXY_BIN=$config/bin/cliproxyapi
	CLAUDEX_CODEX_AUTH_DIR=$config/codex-accounts
 export CLAUDEX_NODE_BIN=$temporary/stale-node
PRESERVE_UNMANAGED_SETTING=yes
EOF
env "${installer_env[@]}" CLAUDEX_PROXY_TOKEN=stable-installer-token "$root/install.sh" >/dev/null
for managed_name in CLAUDEX_PROXY_TOKEN CLAUDEX_PROXY_URL CLAUDEX_PROXY_CONFIG CLAUDEX_PROXY_BIN CLAUDEX_CODEX_AUTH_DIR; do
  assignment_count=$(awk -v name="$managed_name" '
    $0 ~ "^[[:space:]]*(export[[:space:]]+)?" name "[[:space:]]*=" { count++ }
    END { print count + 0 }
  ' "$config/env")
  [[ "$assignment_count" == 1 ]]
done
! grep -Eq '^[[:space:]]*(export[[:space:]]+)?CLAUDEX_NODE_BIN[[:space:]]*=' "$config/env"
grep -Fx 'PRESERVE_UNMANAGED_SETTING=yes' "$config/env" >/dev/null
env_token=$(HOME="$home" bash -c 'source "$1"; printf %s "$CLAUDEX_PROXY_TOKEN"' bash "$config/env")
yaml_token=$(awk '/^api-keys:$/ { getline; sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$config/cliproxyapi.yaml")
[[ "$env_token" == stable-installer-token && "$yaml_token" == "$env_token" ]]
! grep -F 'stale-export-token' "$config/env" "$config/cliproxyapi.yaml" >/dev/null

# A second reinstall without caller overrides must remain idempotent and retain
# the same single effective assignment and proxy credential.
env "${installer_env[@]}" "$root/install.sh" >/dev/null
[[ "$(awk '/^[[:space:]]*(export[[:space:]]+)?CLAUDEX_PROXY_TOKEN[[:space:]]*=/ { count++ } END { print count + 0 }' "$config/env")" == 1 ]]
env_token=$(HOME="$home" bash -c 'source "$1"; printf %s "$CLAUDEX_PROXY_TOKEN"' bash "$config/env")
yaml_token=$(awk '/^api-keys:$/ { getline; sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }' "$config/cliproxyapi.yaml")
[[ "$env_token" == stable-installer-token && "$yaml_token" == "$env_token" ]]

login_log="$temporary/login.log"
env "${installer_env[@]}" FAKE_CODEX_LOGIN_LOG="$login_log" "$root/install.sh" --login >/dev/null
[[ "$(wc -l < "$login_log" | tr -d ' ')" == 1 ]]

env_before=$(<"$config/env")
proxy_before=$(<"$config/cliproxyapi.yaml")
printf '%s\n' prior-statusline > "$config/statusline"
if env "${installer_env[@]}" CLAUDEX_PROXY_TOKEN=must-not-survive CLAUDEX_INSTALL_METHOD=invalid \
    "$root/install.sh" >"$temporary/rollback.out" 2>"$temporary/rollback.err"; then
  printf '%s\n' 'expected late direct-installer failure' >&2
  exit 1
fi
grep -F 'restored the previous managed installation' "$temporary/rollback.err" >/dev/null
[[ "$(<"$config/env")" == "$env_before" ]]
[[ "$(<"$config/cliproxyapi.yaml")" == "$proxy_before" ]]
[[ "$(<"$config/statusline")" == prior-statusline ]]

transaction="$config/.install-transaction.crash-test"
mkdir -p "$transaction/backup"
targets=(
  "$home/.local/bin/claudex" "$config/env" "$config/cliproxyapi.yaml" "$config/bin/cliproxyapi"
  "$config/settings.json" "$config/statusline" "$config/usage-limit" "$config/codex-session"
  "$config/preload.cjs" "$config/skill-bridge.cjs" "$config/self-update"
  "$config/skills/usage-limit/SKILL.md" "$config/install.json"
)
: > "$transaction/manifest"
for index in "${!targets[@]}"; do
  target=${targets[$index]}
  if [[ -f "$target" ]]; then
    cp -p "$target" "$transaction/backup/$index"
    printf '1\t%s\n' "$target" >> "$transaction/manifest"
  else
    printf '0\t%s\n' "$target" >> "$transaction/manifest"
  fi
done
printf '%s\n' committing > "$transaction/state"
printf '%s\n' 'CLAUDEX_PROXY_TOKEN=crash-corruption' > "$config/env"
recovery_output=$(env "${installer_env[@]}" "$root/install.sh")
[[ "$recovery_output" == *'Recovered the previous interrupted Claudex installation'* ]]
grep -F 'CLAUDEX_PROXY_TOKEN=stable-installer-token' "$config/env" >/dev/null
[[ ! -e "$transaction" ]]

managed_home="$temporary/managed-home"
managed_config="$managed_home/.config/claudex"
managed_bin="$temporary/managed-bin"
node_fixture="$temporary/node-fixture"
mkdir -p "$managed_config/bin" "$managed_home/.codex" "$managed_bin" "$node_fixture/bin"
cp "$home/.codex/auth.json" "$managed_home/.codex/auth.json"
ln -s "$fake_bin/codex" "$managed_bin/codex"
ln -s "$fake_bin/claude" "$managed_bin/claude"
ln -s "$(command -v jq)" "$managed_bin/jq"
cat > "$managed_bin/node" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { printf '%s\n' v16.20.2; exit 0; }
exit 1
EOF
cat > "$node_fixture/bin/node" <<EOF
#!/usr/bin/env bash
exec "$(command -v node)" "\$@"
EOF
cat > "$node_fixture/bin/npm" <<EOF
#!/usr/bin/env bash
exec "$(command -v npm)" "\$@"
EOF
cat > "$managed_config/bin/cliproxyapi" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -version ]] && { printf '%s\n' 'Version: 7.2.80'; exit 0; }
exit 0
EOF
cat > "$managed_config/install.json" <<EOF
{"schema":1,"version":"1.4.4","method":"archive","binDir":"$managed_home/.local/bin","repository":"BeamoINT/Claudex"}
EOF
chmod +x "$managed_bin/node" "$node_fixture/bin/node" "$node_fixture/bin/npm" "$managed_config/bin/cliproxyapi"
HOME="$managed_home" PATH="$managed_bin:/usr/bin:/bin" CLAUDEX_CONFIG_DIR="$managed_config" \
  CLAUDEX_INSTALL_METHOD=archive CLAUDEX_PROXY_TOKEN=managed-node-token \
  CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
  CLAUDEX_TEST_MODE=1 CLAUDEX_TEST_MANAGED_NODE_DIR="$node_fixture" "$root/install.sh" >/dev/null
[[ -x "$managed_config/node/bin/node" ]]
grep -F "CLAUDEX_NODE_BIN=$managed_config/node/bin" "$managed_config/env" >/dev/null

grep -F -- '--retry-connrefused' "$root/install.sh" >/dev/null
grep -F 'download_with_retry "$claude_installer"' "$root/install.sh" >/dev/null
grep -F 'download_with_retry "$archive" "$url"' "$root/install.sh" >/dev/null

# Cross-platform source checks enforce the Windows installer ACL policy even on
# Unix CI: direct/archive bin directories are private, while package-manager
# shim directories retain their package-owned ACLs.
node "$root/tests/windows-installer-private-state.test.cjs"

printf '%s\n' 'installer regressions passed'
