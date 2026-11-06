#!/usr/bin/env bash
# macOS: double-click in Finder to start the server in a Terminal window.
# Grant Terminal Accessibility and Screen Recording (see README) first.
exec "$(dirname "$0")/start.sh" "$@"
