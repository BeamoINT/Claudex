#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
readonly version="$(node -p "require('$root/package.json').version")"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/claudex-release-check.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

# Run the two builds under deliberately different caller time zones. The
# builder must set TZ on the archive commands themselves; normalizing the
# staged mtimes alone is not enough for ZIP's local-time metadata.
TZ=Pacific/Honolulu "$root/scripts/build-release.sh" "$version" >/dev/null
cp "$root/dist/claudex-$version.tar.gz" "$temporary/first.tar.gz"
cp "$root/dist/claudex-$version-windows.zip" "$temporary/first-windows.zip"
cp "$root/dist/SHA256SUMS" "$temporary/first-SHA256SUMS"

# A wall-clock boundary catches accidental archive timestamps as well as entry
# ordering and owner metadata drift.
sleep 2
TZ=Asia/Kathmandu "$root/scripts/build-release.sh" "$version" >/dev/null
cmp "$temporary/first.tar.gz" "$root/dist/claudex-$version.tar.gz"
cmp "$temporary/first-windows.zip" "$root/dist/claudex-$version-windows.zip"
cmp "$temporary/first-SHA256SUMS" "$root/dist/SHA256SUMS"

make_fixture() {
  fixture_root=$1
  mkdir -p "$fixture_root"
  while IFS= read -r -d '' tracked; do
    mkdir -p "$fixture_root/$(dirname "$tracked")"
    cp -p "$root/$tracked" "$fixture_root/$tracked"
  done < <(git -C "$root" ls-files --cached --others --exclude-standard -z)

  # Retain compatibility with older checkouts where this dependency predates
  # the untracked-file fixture support above.
  if [[ ! -e "$fixture_root/bin/package-setup-lock.mjs" ]]; then
    mkdir -p "$fixture_root/bin"
    cp -p "$root/bin/package-setup-lock.mjs" "$fixture_root/bin/package-setup-lock.mjs"
  fi
}

assert_symlink_rejected() {
  fixture_root=$1
  source_path=$2
  link_target=$3
  label=$4
  rm -f "$fixture_root/$source_path"
  ln -s "$link_target" "$fixture_root/$source_path"
  if "$fixture_root/scripts/build-release.sh" "$version" >"$temporary/$label.stdout" 2>"$temporary/$label.stderr"; then
    printf 'release builder accepted a symbolic link at %s\n' "$source_path" >&2
    exit 1
  fi
  grep -F "release source is not a regular file: $source_path" "$temporary/$label.stderr" >/dev/null
}

top_symlink_fixture="$temporary/top-symlink-fixture"
make_fixture "$top_symlink_fixture"
assert_symlink_rejected "$top_symlink_fixture" README.md CHANGELOG.md top-symlink

nested_symlink_fixture="$temporary/nested-symlink-fixture"
make_fixture "$nested_symlink_fixture"
assert_symlink_rejected "$nested_symlink_fixture" docs/README.md ../README.md nested-symlink

# Files that are present under release directories but absent from the explicit
# payload allowlist must not change archive bytes or appear in either format.
untracked_fixture="$temporary/untracked-fixture"
make_fixture "$untracked_fixture"
TZ=Europe/London "$untracked_fixture/scripts/build-release.sh" "$version" >/dev/null
cp "$untracked_fixture/dist/claudex-$version.tar.gz" "$temporary/allowlist.tar.gz"
cp "$untracked_fixture/dist/claudex-$version-windows.zip" "$temporary/allowlist-windows.zip"
cp "$untracked_fixture/dist/SHA256SUMS" "$temporary/allowlist-SHA256SUMS"
untracked_files=(
  bin/untracked-release-poison.txt
  docs/untracked-release-poison.txt
  skills/untracked-release-poison.txt
)
for untracked in "${untracked_files[@]}"; do
  printf 'must not ship: %s\n' "$untracked" > "$untracked_fixture/$untracked"
done
TZ=America/Adak "$untracked_fixture/scripts/build-release.sh" "$version" >/dev/null
cmp "$temporary/allowlist.tar.gz" "$untracked_fixture/dist/claudex-$version.tar.gz"
cmp "$temporary/allowlist-windows.zip" "$untracked_fixture/dist/claudex-$version-windows.zip"
cmp "$temporary/allowlist-SHA256SUMS" "$untracked_fixture/dist/SHA256SUMS"
tar_listing=$(tar -tzf "$untracked_fixture/dist/claudex-$version.tar.gz")
zip_listing=$(unzip -Z1 "$untracked_fixture/dist/claudex-$version-windows.zip")
for untracked in "${untracked_files[@]}"; do
  ! grep -F "/$untracked" <<<"$tar_listing" >/dev/null
  ! grep -F "/$untracked" <<<"$zip_listing" >/dev/null
done

printf '%s\n' 'release reproducibility and file-type checks passed'
