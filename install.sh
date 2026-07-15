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
readonly proxy_version="7.2.77"
readonly proxy_port="${CLAUDEX_PROXY_PORT:-8318}"
readonly skip_deps="${CLAUDEX_SKIP_DEPENDENCY_INSTALL:-0}"
readonly skip_service="${CLAUDEX_SKIP_SERVICE_START:-0}"
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
    darwin_aarch64) checksum=a7c265f86895bb9d946ad28e3a126a502096dc91afb7e9838477aa4d39e84554 ;;
    darwin_amd64) checksum=6ff8fad7afaaf0f952d24ac9fb1df790eab62a64ea90981386cbbbdfbc3e9c37 ;;
    linux_aarch64) checksum=42fffb0ce6b8ebb897520d4fe80541371ef861658f2ff5acfe1c815aace5c4f3 ;;
    linux_amd64) checksum=dc0814cd0fc33f472ea4f3d5587447e14ffcb34853edac9a523edc1c5d7ba860 ;;
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
  local os arch expected asset url archive actual temp_dir
  read -r os arch expected <<< "$(proxy_asset_details)"
  asset="CLIProxyAPI_${proxy_version}_${os}_${arch}.tar.gz"
  url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${proxy_version}/${asset}"
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/claudex-proxy.XXXXXX")
  archive="$temp_dir/$asset"
  printf 'Downloading verified internal compatibility service v%s for %s/%s...\n' "$proxy_version" "$os" "$arch"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$url"
  actual=$(sha256_file "$archive")
  [[ "$actual" == "$expected" ]] || fail "compatibility service checksum mismatch for $asset"
  tar -xzf "$archive" -C "$temp_dir" cli-proxy-api
  install -m 755 "$temp_dir/cli-proxy-api" "$managed_proxy"
  rm -rf "$temp_dir"
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
  printf 'CLAUDEX_PROXY_URL=%q\n' "http://127.0.0.1:$proxy_port"
  printf 'CLAUDEX_PROXY_CONFIG=%q\n' "$proxy_config_target"
  printf 'CLAUDEX_PROXY_BIN=%q\n' "$managed_proxy"
  printf 'CLAUDEX_CODEX_AUTH_DIR=%q\n' "$auth_dir"
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
