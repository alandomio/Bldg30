#!/bin/bash
# Explicit step: re-render the tracked icon and logo files in assets/ from the SVGs. A normal build does not do this.
set -euo pipefail
cd "$(dirname "$0")/.."
swift_tool="${MODELDECK_SWIFT:-swift}"
"$swift_tool" -target "$(uname -m)-apple-macosx14.0" scripts/generate-icon.swift assets build/ShipDeck.iconset assets
iconutil -c icns build/ShipDeck.iconset -o assets/AppIcon.icns
git status --short assets
