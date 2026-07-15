#!/bin/zsh
set -euo pipefail

readonly root="${0:A:h}"
readonly bin_dir="${CLAUDEX_BIN_DIR:-$HOME/.local/bin}"
readonly config_dir="$HOME/.config/claudex"
readonly env_file="$config_dir/env"
readonly settings_target="$config_dir/settings.json"
readonly statusline_target="$config_dir/statusline"
readonly launcher_target="$bin_dir/claudex"
readonly skip_deps="${CLAUDEX_SKIP_DEPENDENCY_INSTALL:-0}"
readonly skip_service="${CLAUDEX_SKIP_SERVICE_START:-0}"
login=0

usage() {
  print "Usage: ./install.zsh [--login]"
  print "  --login  Run CLIProxyAPI's Codex OAuth login for a new machine."
}

while (( $# > 0 )); do
  case "$1" in
    --login) login=1 ;;
    --help|-h) usage; exit 0 ;;
    *) print -u2 "install.zsh: unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done

for source_file in claudex statusline settings.json; do
  if [[ ! -r "$root/$source_file" ]]; then
    print -u2 "install.zsh: missing repository file: $source_file"
    exit 1
  fi
done

if [[ "$skip_deps" != 1 ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    print -u2 "install.zsh: Homebrew is required on macOS. Install it, then rerun this installer."
    exit 1
  fi

  formulae=()
  command -v jq >/dev/null 2>&1 || formulae+=(jq)
  command -v cliproxyapi >/dev/null 2>&1 || formulae+=(cliproxyapi)
  if (( ${#formulae} > 0 )); then
    print "Installing required Homebrew packages: ${formulae[*]}"
    brew install "${formulae[@]}"
  fi
fi

for required_command in jq cliproxyapi claude; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    print -u2 "install.zsh: '$required_command' is required but was not found in PATH."
    exit 1
  fi
done

if (( login )); then
  print "Starting CLIProxyAPI Codex login..."
  cliproxyapi -codex-login
fi

first_proxy_key() {
  local proxy_config="${CLAUDEX_PROXY_CONFIG:-$(brew --prefix)/etc/cliproxyapi.conf}"
  [[ -r "$proxy_config" ]] || return 1
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
  ' "$proxy_config"
}

mkdir -p "$bin_dir" "$config_dir"
chmod 700 "$config_dir"

if [[ ! -s "$env_file" ]]; then
  proxy_token="${CLAUDEX_PROXY_TOKEN:-}"
  if [[ -z "$proxy_token" ]]; then
    proxy_token=$(first_proxy_key 2>/dev/null || true)
  fi
  if [[ -z "$proxy_token" && -t 0 ]]; then
    read -r -s "proxy_token?CLIProxyAPI API key: "
    print
  fi
  if [[ -z "$proxy_token" || "$proxy_token" == *$'\n'* ]]; then
    print -u2 "install.zsh: no valid proxy API key was found."
    print -u2 "Set CLAUDEX_PROXY_TOKEN for this command or configure api-keys in CLIProxyAPI."
    exit 1
  fi

  umask 077
  print -r -- "CLAUDEX_PROXY_TOKEN=${(q)proxy_token}" > "$env_file"
  chmod 600 "$env_file"
else
  print "Preserving existing private config: $env_file"
fi

timestamp=$(date +%Y%m%d-%H%M%S)
backup_dir="$config_dir/backups/install-$timestamp"
backed_up=0
for managed_file in "$launcher_target" "$settings_target" "$statusline_target"; do
  if [[ -e "$managed_file" ]]; then
    mkdir -p "$backup_dir"
    cp -p "$managed_file" "$backup_dir/${managed_file:t}"
    backed_up=1
  fi
done
if (( backed_up )); then
  print "Backed up the previous managed files to $backup_dir"
fi

/usr/bin/install -m 755 "$root/claudex" "$launcher_target"
/usr/bin/install -m 755 "$root/statusline" "$statusline_target"

statusline_command="/bin/zsh ${(q)statusline_target}"
settings_tmp=$(mktemp "$config_dir/settings.json.tmp.XXXXXX")
trap 'rm -f "$settings_tmp"' EXIT
jq --arg command "$statusline_command" \
  '.statusLine.command = $command' "$root/settings.json" > "$settings_tmp"
/usr/bin/install -m 600 "$settings_tmp" "$settings_target"
rm -f "$settings_tmp"
trap - EXIT

if [[ "$skip_service" != 1 ]]; then
  brew services start cliproxyapi >/dev/null
fi

print "Installed Claudex launcher: $launcher_target"
print "Installed isolated config: $config_dir"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
  print "Add this directory to PATH: $bin_dir"
fi

if [[ "$skip_service" != 1 ]]; then
  if "$launcher_target" --doctor; then
    print "Claudex is ready. Run: claudex"
  else
    print -u2 "Claudex was installed, but the live model check did not pass."
    print -u2 "On a new machine, run './install.zsh --login' and then 'claudex --doctor'."
  fi
fi
