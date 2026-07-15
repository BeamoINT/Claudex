#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
readonly bin_dir="${CLAUDEX_BIN_DIR:-$HOME/.local/bin}"
readonly config_dir="${CLAUDEX_CONFIG_DIR:-$HOME/.config/claudex}"
readonly env_file="$config_dir/env"
readonly settings_target="$config_dir/settings.json"
readonly statusline_target="$config_dir/statusline"
readonly preload_target="$config_dir/preload.cjs"
readonly proxy_config_target="$config_dir/cliproxyapi.yaml"
readonly launcher_target="$bin_dir/claudex"
readonly proxy_version="7.2.77"
readonly skip_deps="${CLAUDEX_SKIP_DEPENDENCY_INSTALL:-0}"
readonly skip_service="${CLAUDEX_SKIP_SERVICE_START:-0}"
login=0

usage() {
  printf '%s\n' "Usage: ./install.sh [--login]"
  printf '%s\n' "  --login  Run CLIProxyAPI's Codex OAuth login for a new machine."
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

for source_file in claudex statusline preload.cjs settings.json; do
  [[ -r "$root/$source_file" ]] || fail "missing repository file: $source_file"
done

install_jq() {
  if command -v brew >/dev/null 2>&1; then
    brew install jq
  elif command -v apt-get >/dev/null 2>&1; then
    run_as_root apt-get update
    run_as_root apt-get install -y jq
  elif command -v dnf >/dev/null 2>&1; then
    run_as_root dnf install -y jq
  elif command -v yum >/dev/null 2>&1; then
    run_as_root yum install -y jq
  elif command -v zypper >/dev/null 2>&1; then
    run_as_root zypper --non-interactive install jq
  elif command -v pacman >/dev/null 2>&1; then
    run_as_root pacman -S --needed --noconfirm jq
  elif command -v apk >/dev/null 2>&1; then
    run_as_root apk add jq
  else
    fail "jq is required and no supported package manager was found"
  fi
}

run_as_root() {
  if [[ "$(id -u)" == 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "installing jq requires root privileges, but sudo is unavailable"
  fi
}

proxy_executable() {
  if command -v cliproxyapi >/dev/null 2>&1; then
    command -v cliproxyapi
  elif command -v cli-proxy-api >/dev/null 2>&1; then
    command -v cli-proxy-api
  elif [[ -x "$bin_dir/cliproxyapi" ]]; then
    printf '%s\n' "$bin_dir/cliproxyapi"
  else
    return 1
  fi
}

proxy_asset_details() {
  local os arch checksum
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) fail "unsupported Unix platform: $(uname -s); use install.ps1 on Windows" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    arm64|aarch64) arch=aarch64 ;;
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
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

install_proxy() {
  local os arch expected asset url archive actual temp_dir
  read -r os arch expected <<< "$(proxy_asset_details)"
  asset="CLIProxyAPI_${proxy_version}_${os}_${arch}.tar.gz"
  url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${proxy_version}/${asset}"
  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/claudex-proxy.XXXXXX")
  archive="$temp_dir/$asset"
  printf 'Downloading verified CLIProxyAPI v%s for %s/%s...\n' "$proxy_version" "$os" "$arch"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$url"
  actual=$(sha256_file "$archive")
  [[ "$actual" == "$expected" ]] || fail "CLIProxyAPI checksum mismatch for $asset"
  tar -xzf "$archive" -C "$temp_dir" cli-proxy-api
  install -m 755 "$temp_dir/cli-proxy-api" "$bin_dir/cliproxyapi"
  rm -rf "$temp_dir"
}

if [[ "$skip_deps" != 1 ]]; then
  command -v curl >/dev/null 2>&1 || fail "curl is required to install dependencies"
  command -v jq >/dev/null 2>&1 || install_jq
  if ! proxy_executable >/dev/null 2>&1; then
    mkdir -p "$bin_dir"
    install_proxy
    export PATH="$bin_dir:$PATH"
  fi
  if ! command -v claude >/dev/null 2>&1; then
    printf '%s\n' "Installing Claude Code with Anthropic's native installer..."
    claude_installer=$(mktemp "${TMPDIR:-/tmp}/claude-install.XXXXXX")
    trap 'rm -f "$claude_installer"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --output "$claude_installer" https://claude.ai/install.sh
    bash "$claude_installer"
    rm -f "$claude_installer"
    trap - EXIT
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi

for required_command in jq claude; do
  command -v "$required_command" >/dev/null 2>&1 || fail "'$required_command' is required but was not found in PATH"
done
proxy_bin=$(proxy_executable) || fail "CLIProxyAPI is required but was not found in PATH"

mkdir -p "$bin_dir" "$config_dir"
chmod 700 "$config_dir"

proxy_key_from_file() {
  local path="$1"
  awk '
    /^api-keys:/ { in_keys=1; next }
    in_keys && /^[[:space:]]*-/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^"|"$/, "", line)
      print line
      exit
    }
    in_keys && /^[^[:space:]]/ { exit }
  ' "$path"
}

first_proxy_config() {
  local candidate key
  for candidate in \
    "${CLAUDEX_PROXY_CONFIG:-}" \
    "$proxy_config_target" \
    "/opt/homebrew/etc/cliproxyapi.conf" \
    "/usr/local/etc/cliproxyapi.conf" \
    "/etc/cliproxyapi.conf"; do
    [[ -n "$candidate" && -r "$candidate" ]] || continue
    key=$(proxy_key_from_file "$candidate")
    if [[ -n "$key" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if command -v brew >/dev/null 2>&1; then
    candidate="$(brew --prefix)/etc/cliproxyapi.conf"
    [[ -r "$candidate" ]] || return 1
    key=$(proxy_key_from_file "$candidate")
    [[ -n "$key" ]] || return 1
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

first_proxy_key() {
  local proxy_config
  proxy_config=$(first_proxy_config) || return 1
  proxy_key_from_file "$proxy_config"
}

if [[ ! -s "$env_file" ]]; then
  proxy_token="${CLAUDEX_PROXY_TOKEN:-}"
  [[ -n "$proxy_token" ]] || proxy_token=$(first_proxy_key 2>/dev/null || true)
  if [[ -z "$proxy_token" && -t 0 ]]; then
    read -r -s -p "CLIProxyAPI API key (leave empty to generate one): " proxy_token
    printf '\n'
  fi
  if [[ -z "$proxy_token" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      proxy_token=$(openssl rand -hex 32)
    else
      proxy_token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
    fi
  fi
  [[ "$proxy_token" != *$'\n'* ]] || fail "proxy API key contains a newline"

  if [[ ! -r "$proxy_config_target" ]] \
      && { [[ "${CLAUDEX_PROXY_CONFIG:-}" == "$proxy_config_target" ]] \
        || ! first_proxy_key >/dev/null 2>&1; }; then
    json_token=$(printf '%s' "$proxy_token" | jq -Rs '.')
    umask 077
    {
      printf 'host: "127.0.0.1"\n'
      printf 'port: 8317\n'
      printf 'auth-dir: "%s"\n' "$HOME/.cli-proxy-api"
      printf 'api-keys:\n  - %s\n' "$json_token"
      printf 'debug: false\nlogging-to-file: false\nlogs-max-total-size-mb: 100\n'
      printf 'usage-statistics-enabled: false\nrequest-retry: 1\nmax-retry-credentials: 1\n'
    } > "$proxy_config_target"
    chmod 600 "$proxy_config_target"
  fi

  umask 077
  printf 'CLAUDEX_PROXY_TOKEN=%q\n' "$proxy_token" > "$env_file"
  selected_proxy_config=$(first_proxy_config 2>/dev/null || true)
  if [[ -n "$selected_proxy_config" ]]; then
    printf 'CLAUDEX_PROXY_CONFIG=%q\n' "$selected_proxy_config" >> "$env_file"
  fi
  chmod 600 "$env_file"
else
  printf 'Preserving existing private config: %s\n' "$env_file"
fi

# shellcheck disable=SC1090
source "$env_file"

if (( login )); then
  printf '%s\n' "Starting CLIProxyAPI Codex login..."
  if [[ -r "${CLAUDEX_PROXY_CONFIG:-$proxy_config_target}" ]]; then
    "$proxy_bin" -config "${CLAUDEX_PROXY_CONFIG:-$proxy_config_target}" -codex-login
  else
    "$proxy_bin" -codex-login
  fi
fi

timestamp=$(date +%Y%m%d-%H%M%S)
backup_dir="$config_dir/backups/install-$timestamp"
backed_up=0
for managed_file in "$launcher_target" "$settings_target" "$statusline_target" "$preload_target"; do
  if [[ -e "$managed_file" ]]; then
    mkdir -p "$backup_dir"
    cp -p "$managed_file" "$backup_dir/$(basename "$managed_file")"
    backed_up=1
  fi
done
(( backed_up == 0 )) || printf 'Backed up the previous managed files to %s\n' "$backup_dir"

install -m 755 "$root/claudex" "$launcher_target"
install -m 755 "$root/statusline" "$statusline_target"
install -m 644 "$root/preload.cjs" "$preload_target"

printf -v quoted_statusline '%q' "$statusline_target"
statusline_command="/usr/bin/env bash $quoted_statusline"
settings_tmp=$(mktemp "$config_dir/settings.json.tmp.XXXXXX")
trap 'rm -f "$settings_tmp"' EXIT
jq --arg command "$statusline_command" '.statusLine.command = $command' \
  "$root/settings.json" > "$settings_tmp"
install -m 600 "$settings_tmp" "$settings_target"
rm -f "$settings_tmp"
trap - EXIT

printf 'Installed Claudex launcher: %s\n' "$launcher_target"
printf 'Installed isolated config: %s\n' "$config_dir"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
  printf 'Add this directory to PATH: %s\n' "$bin_dir"
fi

if [[ "$skip_service" != 1 ]]; then
  if "$launcher_target" --doctor; then
    printf '%s\n' "Claudex is ready. Run: claudex"
  else
    printf '%s\n' "Claudex was installed, but the live model check did not pass." >&2
    printf '%s\n' "On a new machine, run './install.sh --login' and then 'claudex --doctor'." >&2
  fi
fi
