#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

bash "$root/tests/background-watcher-regressions.sh"
bash "$root/tests/codex-session-lock-regressions.sh"
node "$root/tests/codex-session-lock-powershell.test.cjs"
node "$root/tests/usage-lock-parity.test.cjs"
node "$root/tests/background-watcher-powershell.test.cjs"
node "$root/tests/windows-installer-private-state.test.cjs"
node "$root/tests/windows-private-environment.test.cjs"
bash "$root/tests/test-driver-regressions.sh"

exec "$root/test.zsh" "$@"
