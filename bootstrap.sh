#!/usr/bin/env bash
set -euo pipefail

readonly repository_url="https://github.com/BeamoINT/Claudex"
readonly latest_url="$repository_url/releases/latest"
temporary=""

fail() {
  printf 'Claudex bootstrap: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  [[ -z "$temporary" ]] || rm -rf "$temporary"
}
trap cleanup EXIT

command -v curl >/dev/null 2>&1 || fail 'curl is required to download Claudex'
command -v tar >/dev/null 2>&1 || fail 'tar is required to extract Claudex'

effective_url=$(curl --fail --silent --show-error --location \
  --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
  --retry 3 --retry-delay 1 --retry-connrefused --output /dev/null \
  --write-out '%{url_effective}' "$latest_url")
tag=${effective_url##*/}
[[ "$effective_url" == "$repository_url/releases/tag/$tag" ]] || fail 'the latest-release redirect did not stay on the expected GitHub repository'
[[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || fail "the latest release tag is invalid: $tag"
version=${tag#v}
archive_name="claudex-$version.tar.gz"
download_base="$repository_url/releases/download/$tag"

temporary=$(mktemp -d "${TMPDIR:-/tmp}/claudex-bootstrap.XXXXXX")
archive="$temporary/$archive_name"
checksums="$temporary/SHA256SUMS"

for item in "$archive_name" SHA256SUMS; do
  destination="$temporary/$item"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 180 --retry 3 --retry-delay 1 \
    --retry-connrefused --output "$destination" "$download_base/$item"
done

expected=$(awk -v name="$archive_name" '$2 == name && $1 ~ /^[0-9A-Fa-f]+$/ { print tolower($1) }' "$checksums")
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "SHA256SUMS has no unique valid digest for $archive_name"
[[ "$(awk -v name="$archive_name" '$2 == name { count++ } END { print count + 0 }' "$checksums")" == 1 ]] || \
  fail "SHA256SUMS contains duplicate entries for $archive_name"
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$archive" | awk '{print tolower($1)}')
elif command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$archive" | awk '{print tolower($1)}')
else fail 'sha256sum or shasum is required to verify the Claudex release'
fi
[[ "$actual" == "$expected" ]] || fail "checksum mismatch for $archive_name"

archive_root="claudex-$version"
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  [[ "$entry" != /* && "$entry" != *'\'* ]] || fail "unsafe archive path: $entry"
  case "/$entry/" in *'/../'*|*'/./'*) fail "unsafe archive path: $entry" ;; esac
  case "$entry" in "$archive_root"|"$archive_root/"|"$archive_root/"*) ;; *) fail "archive entry is outside $archive_root: $entry" ;; esac
done < <(tar -tzf "$archive")

if tar -tvzf "$archive" | awk 'substr($0, 1, 1) !~ /^[-d]$/ { exit 1 }'; then :
else fail 'release archive contains a link or unsupported filesystem entry'
fi

tar -xzf "$archive" -C "$temporary" --no-same-owner
source_root="$temporary/$archive_root"
for required in package.json install.sh claudex codex-session settings.json; do
  [[ -f "$source_root/$required" ]] || fail "release archive is missing $required"
done
manifest_version=$(awk -F '"' '$2 == "version" { print $4; exit }' "$source_root/package.json")
[[ "$manifest_version" == "$version" ]] || fail "archive version $manifest_version does not match release $version"

printf 'Installing Claudex %s from its verified GitHub release...\n' "$version"
if env CLAUDEX_INSTALL_METHOD=archive bash "$source_root/install.sh" "$@"; then status=0
else status=$?
fi
exit "$status"
