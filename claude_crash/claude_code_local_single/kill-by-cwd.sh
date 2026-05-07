#!/usr/bin/env bash
# Hard-kill the Claude Code process whose current working directory matches $1.
# Leaves any other Claude processes (including the one you may be reading this
# demo in) untouched.
#
# Usage: ./kill-by-cwd.sh <absolute-cwd>
# Exit:  0 on kill, 1 if no matching process found, 2 on bad usage.

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <absolute-cwd>" >&2
  exit 2
fi

target_cwd="$1"

if ! command -v lsof >/dev/null 2>&1; then
  echo "lsof not found; this script needs lsof to resolve process cwd" >&2
  exit 2
fi

pid=""
for candidate in $(pgrep -f "claude" || true); do
  cwd="$(lsof -a -p "$candidate" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2)}')"
  if [ "$cwd" = "$target_cwd" ]; then
    pid="$candidate"
    break
  fi
done

if [ -z "$pid" ]; then
  echo "no claude process with cwd=$target_cwd found" >&2
  exit 1
fi

echo "killing claude pid=$pid (cwd=$target_cwd)"
kill -9 "$pid"
