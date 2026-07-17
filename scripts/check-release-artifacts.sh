#!/usr/bin/env bash
set -euo pipefail

readonly root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
readonly version="$(node -p 'require(process.argv[1]).version' "$root/package.json")"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/claudex-release-check.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

# The parent artifact check re-enters a copied checkout whose path contains a
# quote. Keep that nested probe focused so it verifies this script's version
# lookup and the builder without recursively running the complete suite.
if [[ "${CLAUDEX_NESTED_QUOTE_PATH_CHECK:-0}" == 1 ]]; then
  "$root/scripts/build-release.sh" "$version" >/dev/null
  test -f "$root/dist/claudex-$version.tar.gz"
  test -f "$root/dist/claudex-$version-windows.zip"
  exit 0
fi

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

# Exercise the bytes users actually download. This installation is isolated,
# account-free, and network-free: dependencies and service startup are skipped,
# while fake upstream CLIs prove that both native harness routes survive archive
# construction and installation.
archive_smoke="$temporary/archive-smoke"
archive_home="$temporary/archive-home"
archive_bin="$temporary/archive-bin"
archive_install_bin="$temporary/archive-install-bin"
archive_config="$temporary/archive-config"
mkdir -p "$archive_smoke" "$archive_home" "$archive_bin"
tar -xzf "$root/dist/claudex-$version.tar.gz" -C "$archive_smoke"
cat > "$archive_bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'artifact-codex'
for argument in "$@"; do printf '|%s' "$argument"; done
printf '\n'
EOF
cat > "$archive_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'artifact-claude'
for argument in "$@"; do printf '|%s' "$argument"; done
printf '\n'
EOF
chmod +x "$archive_bin/codex" "$archive_bin/claude"

extracted="$archive_smoke/claudex-$version"
if ! HOME="$archive_home" PATH="$archive_bin:$PATH" \
    CLAUDEX_BIN_DIR="$archive_install_bin" CLAUDEX_CONFIG_DIR="$archive_config" \
    CLAUDEX_PROXY_TOKEN=artifact-test-token CLAUDEX_INSTALL_METHOD=archive \
    CLAUDEX_SKIP_DEPENDENCY_INSTALL=1 CLAUDEX_SKIP_SERVICE_START=1 \
    "$extracted/install.sh" >"$temporary/archive-install.stdout" 2>"$temporary/archive-install.stderr"; then
  printf '%s\n' 'extracted release installer failed; captured output follows' >&2
  cat "$temporary/archive-install.stdout" >&2
  cat "$temporary/archive-install.stderr" >&2
  exit 1
fi
test "$(jq -r '.version // empty' "$archive_config/install.json")" = "$version"
test "$(jq -r '.method // empty' "$archive_config/install.json")" = archive
test -f "$archive_config/skill-bridge.cjs"
node --check "$archive_config/skill-bridge.cjs"
test "$(HOME="$archive_home" PATH="$archive_bin:$PATH" CLAUDEX_CONFIG_DIR="$archive_config" \
  "$archive_install_bin/claudex" codex --version 'argument with spaces')" = \
  'artifact-codex|--version|argument with spaces'
test "$(HOME="$archive_home" PATH="$archive_bin:$PATH" CLAUDEX_CONFIG_DIR="$archive_config" \
  "$archive_install_bin/claudex" claude --version 'argument with spaces')" = \
  'artifact-claude|--version|argument with spaces'

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

quoted_checkout_fixture="$temporary/checkout-with-'quote"
make_fixture "$quoted_checkout_fixture"
CLAUDEX_NESTED_QUOTE_PATH_CHECK=1 \
  "$quoted_checkout_fixture/scripts/check-release-artifacts.sh"
for asset in "claudex-$version.tar.gz" "claudex-$version-windows.zip" SHA256SUMS; do
  cmp "$root/dist/$asset" "$quoted_checkout_fixture/dist/$asset"
done

# Git's clean/dirty comparison normalizes text according to .gitattributes, so
# a clean checkout can expose host-specific or mixed newlines. Every release
# text file must become canonical LF, with CRLF reserved for Windows .cmd files.
eol_fixture="$temporary/eol-fixture"
make_fixture "$eol_fixture"
node - "$eol_fixture/claudex.cmd" "$eol_fixture/claudex-package.cmd" \
  "$eol_fixture/README.md" "$eol_fixture/package.json" <<'NODE'
const fs = require('fs');
const [lfPath, mixedPath, crlfTextPath, mixedTextPath] = process.argv.slice(2);
const lf = fs.readFileSync(lfPath, 'utf8').replace(/\r\n|\r|\n/g, '\n');
fs.writeFileSync(lfPath, lf);
let line = 0;
fs.writeFileSync(mixedPath, fs.readFileSync(mixedPath, 'utf8').replace(/\r\n|\r|\n/g, () => (++line % 2 ? '\r' : '\r\n')));
fs.writeFileSync(crlfTextPath, fs.readFileSync(crlfTextPath, 'utf8').replace(/\r\n|\r|\n/g, '\r\n'));
line = 0;
fs.writeFileSync(mixedTextPath, fs.readFileSync(mixedTextPath, 'utf8').replace(/\r\n|\r|\n/g, () => (++line % 2 ? '\r' : '\r\n')));
NODE
TZ=Australia/Eucla "$eol_fixture/scripts/build-release.sh" "$version" >/dev/null
for asset in "claudex-$version.tar.gz" "claudex-$version-windows.zip" SHA256SUMS; do
  cmp "$root/dist/$asset" "$eol_fixture/dist/$asset"
done
for text_file in README.md package.json; do
  node - "$eol_fixture/dist/claudex-$version/$text_file" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');
if (/\r/.test(text)) throw new Error(`${file} contains a non-LF newline`);
NODE
done
for command_file in claudex.cmd claudex-package.cmd; do
  node - "$eol_fixture/dist/claudex-$version/$command_file" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
const text = fs.readFileSync(file, 'utf8');
if (/(^|[^\r])\n|\r(?!\n)/.test(text)) throw new Error(`${file} contains a non-CRLF newline`);
NODE
done

# Archive construction must not fall back to platform zip/gzip or tar-create
# implementations. Verification still uses the host tar reader so the emitted
# USTAR remains independently consumable.
canonical_fixture="$temporary/canonical-writer-fixture"
canonical_bin="$temporary/canonical-writer-bin"
make_fixture "$canonical_fixture"
mkdir -p "$canonical_bin"
cat > "$canonical_bin/zip" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
cat > "$canonical_bin/gzip" <<'EOF'
#!/usr/bin/env bash
exit 98
EOF
cat > "$canonical_bin/tar" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *' -c'*|*' --create '*) exit 99 ;;
esac
# GNU tar resolves its gzip reader through PATH, while bsdtar decompresses in
# process. Restore the caller's tool path only for this read-only delegation so
# the poison gzip continues to catch archive construction without breaking
# independent consumption on Linux.
PATH="$CLAUDEX_TEST_REAL_TOOL_PATH" exec "$CLAUDEX_TEST_REAL_TAR" "$@"
EOF
chmod +x "$canonical_bin/zip" "$canonical_bin/gzip" "$canonical_bin/tar"
CLAUDEX_TEST_REAL_TAR="$(command -v tar)" CLAUDEX_TEST_REAL_TOOL_PATH="$PATH" \
  PATH="$canonical_bin:$PATH" \
  TZ=Etc/GMT+12 "$canonical_fixture/scripts/build-release.sh" "$version" >/dev/null
for asset in "claudex-$version.tar.gz" "claudex-$version-windows.zip" SHA256SUMS; do
  cmp "$root/dist/$asset" "$canonical_fixture/dist/$asset"
done
node - "$root/dist/claudex-$version.tar.gz" "$root/dist/claudex-$version-windows.zip" <<'NODE'
const fs = require('fs');
const [gzipPath, zipPath] = process.argv.slice(2);
const gzip = fs.readFileSync(gzipPath);
const zip = fs.readFileSync(zipPath);
if (gzip.subarray(0, 10).toString('hex') !== '1f8b08000000000000ff') {
  throw new Error('release gzip header is not canonical');
}
if (zip.readUInt32LE(0) !== 0x04034b50 || zip.readUInt16LE(8) !== 0) {
  throw new Error('release ZIP does not use canonical stored entries');
}
NODE

# Native Windows filesystems do not expose meaningful POSIX executable bits.
# Re-archive a fully non-executable stage and require the release-path contract
# to reproduce both assets and their executable metadata exactly.
mode_stage="$canonical_fixture/dist/claudex-$version"
find "$mode_stage" -type f -exec chmod 644 {} +
node "$canonical_fixture/scripts/create-release-archives.mjs" "$mode_stage" \
  "$temporary/mode-normalized.tar.gz" "$temporary/mode-normalized-windows.zip"
cmp "$root/dist/claudex-$version.tar.gz" "$temporary/mode-normalized.tar.gz"
cmp "$root/dist/claudex-$version-windows.zip" "$temporary/mode-normalized-windows.zip"
executable_release_files=(
  bootstrap.sh claudex codex-session install.sh install.zsh self-update statusline usage-limit bin/claudex-package.mjs
)
for executable in "${executable_release_files[@]}"; do
  tar_mode=$(tar -tvzf "$temporary/mode-normalized.tar.gz" "claudex-$version/$executable" | awk '{print $1}')
  [[ "$tar_mode" == -rwxr-xr-x ]]
  zip_mode=$(unzip -Z -l "$temporary/mode-normalized-windows.zip" "claudex-$version/$executable" | awk 'NR == 1 {print $1}')
  [[ "$zip_mode" == -rwxr-xr-x ]]
done

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

printf '%s\n' 'release reproducibility, file-type, and extracted-install checks passed'
