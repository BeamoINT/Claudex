#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
readonly bin_dir="${CLAUDEX_BIN_DIR:-$HOME/.local/bin}"
readonly config_dir="${CLAUDEX_CONFIG_DIR:-$HOME/.config/claudex}"
readonly managed_bin_dir="$config_dir/bin"
readonly managed_proxy="$managed_bin_dir/cliproxyapi"
readonly auth_dir="$config_dir/codex-accounts"
readonly env_file="$config_dir/env"
readonly settings_target="$config_dir/settings.json"
readonly statusline_target="$config_dir/statusline"
readonly usage_limit_target="$config_dir/usage-limit"
readonly codex_session_target="$config_dir/codex-session"
readonly usage_skill_target="$config_dir/skills/usage-limit/SKILL.md"
readonly preload_target="$config_dir/preload.cjs"
readonly proxy_config_target="$config_dir/cliproxyapi.yaml"
readonly launcher_target="$bin_dir/claudex"
readonly proxy_version="7.2.80"
readonly proxy_port="${CLAUDEX_PROXY_PORT:-8318}"
readonly skip_deps="${CLAUDEX_SKIP_DEPENDENCY_INSTALL:-0}"
readonly skip_service="${CLAUDEX_SKIP_SERVICE_START:-0}"

# Preserve values supplied for this installer invocation. Sourcing the existing
# managed env below must not silently override an explicit repair/migration
# target selected by the caller.
caller_proxy_token_set=${CLAUDEX_PROXY_TOKEN+x}; caller_proxy_token=${CLAUDEX_PROXY_TOKEN-}
caller_proxy_url_set=${CLAUDEX_PROXY_URL+x}; caller_proxy_url=${CLAUDEX_PROXY_URL-}
caller_proxy_config_set=${CLAUDEX_PROXY_CONFIG+x}; caller_proxy_config=${CLAUDEX_PROXY_CONFIG-}
caller_proxy_bin_set=${CLAUDEX_PROXY_BIN+x}; caller_proxy_bin=${CLAUDEX_PROXY_BIN-}
caller_auth_dir_set=${CLAUDEX_CODEX_AUTH_DIR+x}; caller_auth_dir=${CLAUDEX_CODEX_AUTH_DIR-}
login=0

usage() {
  printf '%s\n' 'Usage: ./install.sh [--login]'
  printf '%s\n' '  --login  Open the official Codex login before finishing installation.'
}

fail() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --login) login=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$proxy_port" =~ ^[0-9]+$ ]] && (( proxy_port >= 1 && proxy_port <= 65535 )) || \
  fail 'CLAUDEX_PROXY_PORT must be an integer from 1 to 65535'

for source_file in claudex codex-session statusline usage-limit preload.cjs settings.json skills/usage-limit/SKILL.md; do
  [[ -r "$root/$source_file" ]] || fail "missing repository file: $source_file"
done

run_as_root() {
  if [[ "$(id -u)" == 0 ]]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else fail 'installing jq requires root privileges, but sudo is unavailable'
  fi
}

install_jq() {
  if command -v brew >/dev/null 2>&1; then brew install jq
  elif command -v apt-get >/dev/null 2>&1; then run_as_root apt-get update; run_as_root apt-get install -y jq
  elif command -v dnf >/dev/null 2>&1; then run_as_root dnf install -y jq
  elif command -v yum >/dev/null 2>&1; then run_as_root yum install -y jq
  elif command -v zypper >/dev/null 2>&1; then run_as_root zypper --non-interactive install jq
  elif command -v pacman >/dev/null 2>&1; then run_as_root pacman -S --needed --noconfirm jq
  elif command -v apk >/dev/null 2>&1; then run_as_root apk add jq
  else fail 'jq is required and no supported package manager was found'
  fi
}

proxy_asset_details() {
  local os arch checksum
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;;
    *) fail "unsupported Unix platform: $(uname -s); use install.ps1 on Windows" ;;
  esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=aarch64 ;;
    *) fail "unsupported CPU architecture: $(uname -m)" ;;
  esac
  case "${os}_${arch}" in
    darwin_aarch64) checksum=7b13a17670a7d24318e3d6a3f24ff38696cf23ab44894fc93fbd53fbb68dfda6 ;;
    darwin_amd64) checksum=e442331bf90e908adac1da0b5536c360318dd95708f21423705ed0ae6d311fcc ;;
    linux_aarch64) checksum=c86b709019e6a86ca068772a1ec6f528f314030076163655789f8243be928549 ;;
    linux_amd64) checksum=6c973562831c4ace016b057708ccb6529ba88af93fe67841ed109b81fe030b9a ;;
  esac
  printf '%s %s %s\n' "$os" "$arch" "$checksum"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'
  fi
}

managed_proxy_is_current() {
  [[ -x "$managed_proxy" ]] || return 1
  local version_output
  version_output=$("$managed_proxy" -version 2>&1 || true)
  [[ "${version_output%%$'\n'*}" == *"Version: $proxy_version"* ]]
}

install_proxy() {
  local os arch expected asset url archive actual temp_dir details
  details=$(proxy_asset_details) || return
  read -r os arch expected <<< "$details"
  asset="CLIProxyAPI_${proxy_version}_${os}_${arch}.tar.gz"
  url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${proxy_version}/${asset}"
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/claudex-proxy.XXXXXX")
  trap 'rm -rf "$temp_dir"' RETURN
  archive="$temp_dir/$asset"
  printf 'Downloading verified internal compatibility service v%s for %s/%s...\n' "$proxy_version" "$os" "$arch"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$url"
  actual=$(sha256_file "$archive")
  [[ "$actual" == "$expected" ]] || fail "compatibility service checksum mismatch for $asset"
  tar -xzf "$archive" -C "$temp_dir" cli-proxy-api
  install -m 755 "$temp_dir/cli-proxy-api" "$managed_proxy"
  rm -rf "$temp_dir"
  trap - RETURN
}

mkdir -p "$bin_dir" "$config_dir" "$managed_bin_dir" "$auth_dir"
chmod 700 "$config_dir" "$managed_bin_dir" "$auth_dir"

if [[ "$skip_deps" != 1 ]]; then
  command -v curl >/dev/null 2>&1 || fail 'curl is required to install Claudex'
  command -v jq >/dev/null 2>&1 || install_jq
  command -v codex >/dev/null 2>&1 || fail "Codex CLI is required. Install Codex, run 'codex login', then rerun this installer."
  if ! command -v claude >/dev/null 2>&1; then
    printf '%s\n' "Installing Claude Code with Anthropic's native installer..."
    claude_installer=$(mktemp "${TMPDIR:-/tmp}/claude-install.XXXXXX")
    trap 'rm -f "$claude_installer"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --output "$claude_installer" https://claude.ai/install.sh
    bash "$claude_installer"
    rm -f "$claude_installer"
    trap - EXIT
    export PATH="$HOME/.local/bin:$PATH"
  fi
  if ! managed_proxy_is_current; then install_proxy; fi
fi

for required_command in jq codex claude; do
  command -v "$required_command" >/dev/null 2>&1 || fail "'$required_command' is required but was not found in PATH"
done

if [[ "$skip_deps" != 1 && "${CLAUDEX_SKIP_CLAUDE_UPDATE:-0}" != 1 ]]; then
  printf '%s\n' 'Checking Claude Code for the latest compatible release...'
  if claude update >"$config_dir/claude-update-install.log" 2>&1; then
    mkdir -p "$config_dir/update"
    date +%s > "$config_dir/update/last-success"
  else
    printf '%s\n' 'install.sh: Claude Code update check failed; continuing with the installed version.' >&2
  fi
fi

if (( login )); then
  codex -c 'cli_auth_credentials_store="file"' login
fi

proxy_token="${CLAUDEX_PROXY_TOKEN:-}"
if [[ -r "$env_file" ]]; then
  # shellcheck disable=SC1090
  source "$env_file"
  proxy_token="${CLAUDEX_PROXY_TOKEN:-$proxy_token}"
fi
if [[ -n "$caller_proxy_token_set" ]]; then proxy_token="$caller_proxy_token"; fi
if [[ -n "$caller_proxy_url_set" ]]; then runtime_proxy_url="$caller_proxy_url"; else runtime_proxy_url="${CLAUDEX_PROXY_URL:-http://127.0.0.1:$proxy_port}"; fi
if [[ -n "$caller_proxy_config_set" ]]; then runtime_proxy_config="$caller_proxy_config"; else runtime_proxy_config="${CLAUDEX_PROXY_CONFIG:-$proxy_config_target}"; fi
if [[ -n "$caller_proxy_bin_set" ]]; then runtime_proxy_bin="$caller_proxy_bin"; else runtime_proxy_bin="${CLAUDEX_PROXY_BIN:-$managed_proxy}"; fi
if [[ -n "$caller_auth_dir_set" ]]; then runtime_auth_dir="$caller_auth_dir"; else runtime_auth_dir="${CLAUDEX_CODEX_AUTH_DIR:-$auth_dir}"; fi
if [[ -z "$proxy_token" ]]; then
  if command -v openssl >/dev/null 2>&1; then proxy_token=$(openssl rand -hex 32)
  else proxy_token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  fi
fi
[[ "$proxy_token" != *$'\n'* && "$proxy_token" != *$'\r'* ]] || fail 'local compatibility key contains a newline'

json_token=$(printf '%s' "$proxy_token" | jq -Rs '.')
json_auth_dir=$(printf '%s' "$auth_dir" | jq -Rs '.')
umask 077
{
  printf 'host: "127.0.0.1"\n'
  printf 'port: %s\n' "$proxy_port"
  printf 'auth-dir: %s\n' "$json_auth_dir"
  printf 'api-keys:\n  - %s\n' "$json_token"
  printf 'debug: false\nlogging-to-file: false\nlogs-max-total-size-mb: 100\n'
  printf 'usage-statistics-enabled: false\nrequest-retry: 3\nmax-retry-credentials: 1\n'
  printf 'max-retry-interval: 5\ntransient-error-cooldown-seconds: 1\n'
  printf 'streaming:\n  keepalive-seconds: 15\n  bootstrap-retries: 2\n'
} > "$proxy_config_target"
chmod 600 "$proxy_config_target"

env_tmp=$(mktemp "$config_dir/.env.tmp.XXXXXX")
{
  printf 'CLAUDEX_PROXY_TOKEN=%q\n' "$proxy_token"
  printf 'CLAUDEX_PROXY_URL=%q\n' "$runtime_proxy_url"
  printf 'CLAUDEX_PROXY_CONFIG=%q\n' "$runtime_proxy_config"
  printf 'CLAUDEX_PROXY_BIN=%q\n' "$runtime_proxy_bin"
  printf 'CLAUDEX_CODEX_AUTH_DIR=%q\n' "$runtime_auth_dir"
  if [[ -r "$env_file" ]]; then
    awk '!/^(CLAUDEX_PROXY_TOKEN|CLAUDEX_PROXY_URL|CLAUDEX_PROXY_CONFIG|CLAUDEX_PROXY_BIN|CLAUDEX_CODEX_AUTH_DIR)=/' "$env_file"
  fi
} > "$env_tmp"
mv -f "$env_tmp" "$env_file"
chmod 600 "$env_file"

timestamp=$(date +%Y%m%d-%H%M%S)
backup_dir="$config_dir/backups/install-$timestamp"
backed_up=0
for managed_file in "$launcher_target" "$settings_target" "$statusline_target" "$usage_limit_target" "$codex_session_target" "$preload_target" "$usage_skill_target"; do
  if [[ -e "$managed_file" ]]; then
    mkdir -p "$backup_dir"
    cp -p "$managed_file" "$backup_dir/$(basename "$managed_file")"
    backed_up=1
  fi
done
(( backed_up == 0 )) || printf 'Backed up the previous managed files to %s\n' "$backup_dir"

install -m 755 "$root/claudex" "$launcher_target"
install -m 755 "$root/statusline" "$statusline_target"
install -m 755 "$root/usage-limit" "$usage_limit_target"
install -m 755 "$root/codex-session" "$codex_session_target"
install -m 644 "$root/preload.cjs" "$preload_target"
mkdir -p "$(dirname "$usage_skill_target")"
install -m 644 "$root/skills/usage-limit/SKILL.md" "$usage_skill_target"

printf -v quoted_statusline '%q' "$statusline_target"
settings_tmp=$(mktemp "$config_dir/settings.json.tmp.XXXXXX")
trap 'rm -f "$settings_tmp"' EXIT
jq --arg command "/usr/bin/env bash $quoted_statusline" '.statusLine.command = $command' "$root/settings.json" > "$settings_tmp"
install -m 600 "$settings_tmp" "$settings_target"
rm -f "$settings_tmp"
trap - EXIT

printf 'Installed Claudex launcher: %s\n' "$launcher_target"
printf 'Installed isolated config: %s\n' "$config_dir"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then printf 'Add this directory to PATH: %s\n' "$bin_dir"; fi

auth_ready=0
if "$codex_session_target" sync; then auth_ready=1
else
  printf '%s\n' "Claudex is installed. Sign in with 'claudex --login', then run 'claudex'." >&2
fi

if [[ "$skip_service" != 1 && "$auth_ready" == 1 ]]; then
  if "$launcher_target" --doctor; then printf '%s\n' 'Claudex is ready. Run: claudex'
  else fail 'the live compatibility check did not pass; run `claudex --doctor` for details'
  fi
fi
