#!/usr/bin/env bash
# Start the dashboard server with .env loaded (macOS and Linux).
# Extra arguments go to server.py:  ./start.sh --provider claude
set -euo pipefail
cd "$(dirname "$0")"
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
exec uv run server.py "$@"
