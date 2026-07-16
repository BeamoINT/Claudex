#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
readonly temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'legacy Linux runtime test must run as root in a disposable container' >&2; exit 1; }
apt-get update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq >/dev/null

home="$temporary/home"
fake_bin="$temporary/bin"
config="$home/.config/claudex"
mkdir -p "$fake_bin" "$config/bin" "$home/.codex"
cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
exit 0
EOF
cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf '%s\n' '2.1.211 (test)'; fi
exit 0
EOF
cat > "$config/bin/cliproxyapi" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -version ]]; then printf '%s\n' 'Version: 7.2.80'; fi
exit 0
EOF
chmod +x "$fake_bin/codex" "$fake_bin/claude" "$config/bin/cliproxyapi"
printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"test","refresh_token":"test","account_id":"test"}}' > "$home/.codex/auth.json"

if [[ -d /host-node ]]; then
  export CLAUDEX_TEST_MODE=1
  export CLAUDEX_TEST_MANAGED_NODE_DIR=/host-node
fi
HOME="$home" PATH="$fake_bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  CLAUDEX_PROXY_TOKEN=legacy-linux-test CLAUDEX_SKIP_SERVICE_START=1 CLAUDEX_SKIP_CLAUDE_UPDATE=1 \
  "$root/install.sh" >/dev/null

"$config/node/bin/node" -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)'
"$config/node/bin/npm" --version >/dev/null
grep -F "CLAUDEX_NODE_BIN=$config/node/bin" "$config/env" >/dev/null
HOME="$home" PATH="$home/.local/bin:/usr/bin:/bin" "$home/.local/bin/claudex" skills >/dev/null
printf '%s\n' 'legacy Linux managed Node installation passed'
