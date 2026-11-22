#!/bin/bash
# The test gate. CI (.github/workflows/ci.yml) and the no-mistakes test step (.no-mistakes.yaml) run exactly this;
# run it before every push.
#   1. English translations are complete      scripts/check-localization.py
#   2. Feed producer, click pipe, freshness    wire/tests (Python, stdlib only)
#   3. Full Swift test suite                   swift test (XCTest and Swift Testing; needs Xcode)
#   4. The app builds                          scripts/build.sh (skip with --no-build)
set -euo pipefail
cd "$(dirname "$0")/.."

build=1
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    *) printf 'usage: scripts/test.sh [--no-build]\n' >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }

if ! xcrun --find xctest >/dev/null 2>&1; then
  printf 'XCTest not found: install Xcode and select it (sudo xcode-select -s /Applications/Xcode.app).\n' >&2
  exit 1
fi

step "English translations"
python3 scripts/check-localization.py

step "Feed producer, click pipe and freshness check (wire/tests)"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s wire/tests -t wire/tests

step "Swift test suite"
swift test

if [[ "$build" == 1 ]]; then
  step "App build"
  bash scripts/build.sh
fi
printf '\n== All checks passed\n'
