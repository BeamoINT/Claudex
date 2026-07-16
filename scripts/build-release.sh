#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
version="${1:-$(node -p "require('$root/package.json').version")}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'invalid version: %s\n' "$version" >&2; exit 2; }
manifest_version=$(node -p "require('$root/package.json').version")
[[ "$version" == "$manifest_version" ]] || { printf 'release version %s does not match package.json %s\n' "$version" "$manifest_version" >&2; exit 2; }

command -v zip >/dev/null 2>&1 || { printf '%s\n' 'zip is required to build release assets' >&2; exit 1; }
command -v unzip >/dev/null 2>&1 || { printf '%s\n' 'unzip is required to verify release assets' >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { printf '%s\n' 'gzip is required to build reproducible release assets' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { printf '%s\n' 'tar is required to build release assets' >&2; exit 1; }

# This is the complete release payload. Keep it explicit: recursively copying
# these directories would silently publish any untracked editor, credential, or
# build artifact that happened to be present in a release checkout.
files=(
  CHANGELOG.md CODE_OF_CONDUCT.md CONTRIBUTING.md GOVERNANCE.md LICENSE MAINTAINERS.md NOTICE.md README.md ROADMAP.md
  SECURITY.md SUPPORT.md bootstrap.ps1 bootstrap.sh package.json
  claudex claudex.cmd claudex.ps1 claudex-package.cmd
  codex-session codex-session.ps1 env.example install.ps1 install.sh install.zsh
  preload.cjs skill-bridge.cjs self-update self-update.ps1 settings.json statusline statusline.ps1 usage-limit usage-limit.ps1
  bin/claudex-package.mjs bin/package-setup-lock.mjs
  docs/README.md docs/architecture.md docs/claude-code-compatibility.md docs/configuration.md
  docs/development.md docs/installation.md docs/package-managers.md docs/skills.md
  docs/troubleshooting.md docs/usage.md
  skills/usage-limit/SKILL.md skills/usage-limit/SKILL.windows.md
)

# Validate the source, not only the staged copy. A normal cp dereferences a
# source symlink, which previously made the post-copy file-type check too late.
for file in "${files[@]}"; do
  source_file="$root/$file"
  [[ -f "$source_file" && ! -L "$source_file" ]] || {
    printf 'release source is not a regular file: %s\n' "$file" >&2
    exit 1
  }
done

readonly dist="$root/dist"
readonly stage="$dist/claudex-$version"
rm -rf "$dist"
mkdir -p "$stage"
for file in "${files[@]}"; do
  mkdir -p "$stage/$(dirname "$file")"
  # -P keeps a symlink as a symlink if the source changes after validation;
  # the staging-tree check below then fails closed instead of dereferencing it.
  cp -P "$root/$file" "$stage/$file"
done

unsupported=$(find "$stage" ! -type f ! -type d -print -quit)
[[ -z "$unsupported" ]] || {
  printf 'release staging tree contains an unsupported file type: %s\n' "$unsupported" >&2
  exit 1
}

# Archive metadata is part of every published checksum. Normalize permissions,
# timestamps, ownership, and entry order so rebuilding the same source produces
# the same bytes instead of invalidating package-manager hashes.
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
chmod +x "$stage/bootstrap.sh" "$stage/claudex" "$stage/codex-session" "$stage/install.sh" "$stage/install.zsh" "$stage/self-update" \
  "$stage/statusline" "$stage/usage-limit" "$stage/bin/claudex-package.mjs"
TZ=UTC find "$stage" -exec touch -t 200001010000 {} +

readonly archive_list="$dist/.release-files"
(
  cd "$dist"
  find "claudex-$version" -print | LC_ALL=C sort > "$archive_list"
)

tar_options=(--format=ustar --no-recursion)
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar_options+=(--owner=0 --group=0 --numeric-owner)
else
  # macOS ships bsdtar. These flags match the GNU archive ownership above.
  tar_options+=(--uid 0 --gid 0 --uname root --gname root)
fi

(
  cd "$dist"
  export TZ=UTC
  COPYFILE_DISABLE=1 tar "${tar_options[@]}" -cf - -T "$archive_list" | gzip -n > "claudex-$version.tar.gz"
  zip -X -q "claudex-$version-windows.zip" -@ < "$archive_list"
)
rm -f "$archive_list"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$dist" && sha256sum "claudex-$version.tar.gz" "claudex-$version-windows.zip" > SHA256SUMS)
else
  (cd "$dist" && shasum -a 256 "claudex-$version.tar.gz" "claudex-$version-windows.zip" > SHA256SUMS)
fi

tar -tzf "$dist/claudex-$version.tar.gz" | awk -v root="claudex-$version/" '
  index($0, root) != 1 || $0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /^\// { exit 1 }
' || { printf '%s\n' 'release archive contains an unsafe path' >&2; exit 1; }
required_release_files=(
  MAINTAINERS.md
  ROADMAP.md
  bin/claudex-package.mjs
  bin/package-setup-lock.mjs
  skill-bridge.cjs
  skills/usage-limit/SKILL.md
  skills/usage-limit/SKILL.windows.md
)
tar_listing=$(tar -tzf "$dist/claudex-$version.tar.gz")
zip_listing=$(unzip -Z1 "$dist/claudex-$version-windows.zip")
for required in "${required_release_files[@]}"; do
  grep -Fx "claudex-$version/$required" <<<"$tar_listing" >/dev/null || {
    printf 'release tarball is missing %s\n' "$required" >&2
    exit 1
  }
  grep -Fx "claudex-$version/$required" <<<"$zip_listing" >/dev/null || {
    printf 'release Windows archive is missing %s\n' "$required" >&2
    exit 1
  }
done
node --check "$stage/skill-bridge.cjs"
node --check "$stage/bin/claudex-package.mjs"
node --check "$stage/bin/package-setup-lock.mjs"
(cd "$dist" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || \
  (cd "$dist" && sha256sum -c SHA256SUMS >/dev/null)

printf 'Built release assets in %s\n' "$dist"
