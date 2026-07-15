#!/bin/sh
# Compatibility entry point for existing macOS checkouts.
exec "$(dirname "$0")/install.sh" "$@"
