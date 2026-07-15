#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
version="${1:-$(node -p "require('$root/package.json').version")}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'invalid version: %s\n' "$version" >&2; exit 2; }

command -v zip >/dev/null 2>&1 || { printf '%s\n' 'zip is required to build release assets' >&2; exit 1; }

readonly dist="$root/dist"
readonly stage="$dist/claudex-$version"
rm -rf "$dist"
mkdir -p "$stage"

files=(
  CHANGELOG.md CODE_OF_CONDUCT.md CONTRIBUTING.md GOVERNANCE.md LICENSE NOTICE.md README.md
  SECURITY.md SUPPORT.md package.json
  claudex claudex.cmd claudex.ps1 claudex-package.cmd
  codex-session codex-session.ps1 env.example install.ps1 install.sh install.zsh
  preload.cjs settings.json statusline statusline.ps1 usage-limit usage-limit.ps1
)
directories=(bin docs skills)

for file in "${files[@]}"; do cp "$root/$file" "$stage/$file"; done
for directory in "${directories[@]}"; do cp -R "$root/$directory" "$stage/$directory"; done
chmod +x "$stage/claudex" "$stage/codex-session" "$stage/install.sh" "$stage/install.zsh" \
  "$stage/statusline" "$stage/usage-limit" "$stage/bin/claudex-package.mjs"

(
  cd "$dist"
  COPYFILE_DISABLE=1 tar -czf "claudex-$version.tar.gz" "claudex-$version"
  zip -X -q -r "claudex-$version-windows.zip" "claudex-$version"
)

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$dist" && sha256sum "claudex-$version.tar.gz" "claudex-$version-windows.zip" > SHA256SUMS)
else
  (cd "$dist" && shasum -a 256 "claudex-$version.tar.gz" "claudex-$version-windows.zip" > SHA256SUMS)
fi

printf 'Built release assets in %s\n' "$dist"
