#!/bin/bash
# See docs/shipdeck-wire.md for test gate requirements.
set -euo pipefail
cd "$(dirname "$0")/.."

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

step "App build"
bash scripts/build.sh
printf '\n== All checks passed\n'
