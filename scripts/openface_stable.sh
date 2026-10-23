#!/usr/bin/env bash
# Start the OpenFace bridge plus a *named* Cloudflare tunnel with a fixed hostname.
#
# One-time setup (needs a domain on Cloudflare):
#   cloudflared tunnel login                 # pick your ROOT domain, e.g. example.com
#   cloudflared tunnel create paintest
#   cloudflared tunnel route dns paintest openface.example.com
#
# Then every time:
#   scripts/openface_stable.sh
#
# Put https://openface.example.com in painTest → Settings once; it never changes.
# Override the tunnel name with PAINTEST_TUNNEL=othername.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TUNNEL="${PAINTEST_TUNNEL:-paintest}"
CF="$(command -v cloudflared || echo /opt/homebrew/bin/cloudflared)"
PY="${PAINTEST_PYTHON:-python3}"

if [[ ! -x "$CF" ]]; then
  echo "cloudflared missing. Run: brew install cloudflared" >&2
  exit 1
fi

if ! "$CF" tunnel list 2>/dev/null | grep -qw "$TUNNEL"; then
  echo "No named tunnel '$TUNNEL'. Do the one-time setup at the top of this script first." >&2
  exit 1
fi

"$PY" "$ROOT/scripts/openface_server.py" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT INT TERM

sleep 1.5
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "OpenFace server failed to start on port 8765" >&2
  exit 1
fi

echo "Bridge running. Starting named tunnel '$TUNNEL'…"
"$CF" tunnel --no-autoupdate run --url http://127.0.0.1:8765 "$TUNNEL"
