#!/bin/bash
# Regression check: a normal build must not touch tracked files. Prints the touched paths and fails if any.
set -euo pipefail
cd "$(dirname "$0")/.."
tracked_stamp() { git ls-files -z | xargs -0 stat -f '%N %m %z' | shasum; }
before="$(tracked_stamp)"
status_before="$(git status --porcelain)"
bash scripts/build.sh "${1:-release}" >/dev/null
if [[ "$(tracked_stamp)" != "$before" ]]; then
  echo "FAIL: build.sh rewrote tracked files" >&2
  git ls-files -z | xargs -0 stat -f '%N %m' | sort -k2 -n | tail -5 >&2
  exit 1
fi
if [[ "$(git status --porcelain)" != "$status_before" ]]; then
  echo "FAIL: build.sh changed git status" >&2
  git status --porcelain >&2
  exit 1
fi
echo "PASS: build.sh left every tracked file untouched"
