#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: send.sh <device-name> <file|dir>..." >&2
  exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
ROOT=${AIRDROP_TOOL_ROOT:-$SKILL_DIR}
BIN="$ROOT/bin"

if [ ! -f "$ROOT/Makefile" ] || [ ! -d "$ROOT/src" ]; then
  echo "cannot locate the airdrop-tool skill directory (looked in $ROOT)" >&2
  echo "set AIRDROP_TOOL_ROOT to the skill directory" >&2
  exit 2
fi

DEVICE=$1
shift

if [ -z "$DEVICE" ]; then
  echo "device name must not be empty" >&2
  exit 2
fi

for path in "$@"; do
  if [ ! -e "$path" ]; then
    echo "missing: $path" >&2
    exit 2
  fi
done

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found; install Xcode Command Line Tools: xcode-select --install" >&2
  exit 2
fi

# Incremental: make rebuilds only when the sources changed.
make -C "$ROOT" >/dev/null

set +e
"$BIN/click" --check >/dev/null 2>&1
CHECK=$?
set -e
if [ "$CHECK" -eq 1 ]; then
  echo "Accessibility permission required: System Settings > Privacy & Security > Accessibility" >&2
  exit 1
elif [ "$CHECK" -ne 0 ]; then
  echo "click --check failed with exit $CHECK" >&2
  exit "$CHECK"
fi

"$BIN/airdrop" "$@" &
APP=$!
cleanup() {
  if kill -0 "$APP" 2>/dev/null; then
    kill "$APP" 2>/dev/null || true
    wait "$APP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$BIN/click" --device "$DEVICE" --pid "$APP" \
  --wait "${AIRDROP_WAIT:-15}" \
  --timeout "${AIRDROP_TIMEOUT:-600}" &
CLICK=$!

while kill -0 "$CLICK" 2>/dev/null; do
  if ! kill -0 "$APP" 2>/dev/null; then
    set +e
    wait "$APP"
    APP_RC=$?
    set -e
    # Right after a successful send, click presses Done and airdrop exits;
    # give click a moment to finish before treating this as an early failure.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$CLICK" 2>/dev/null || break
      sleep 0.2
    done
    if ! kill -0 "$CLICK" 2>/dev/null; then
      set +e
      wait "$CLICK"
      CLICK_RC=$?
      set -e
      exit "$CLICK_RC"
    fi
    kill "$CLICK" 2>/dev/null || true
    wait "$CLICK" 2>/dev/null || true
    echo "airdrop exited before the transfer finished (exit $APP_RC)" >&2
    exit "$APP_RC"
  fi
  sleep 0.2
done

set +e
wait "$CLICK"
CLICK_RC=$?
set -e
exit "$CLICK_RC"
