#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
swift_tool="${MODELDECK_SWIFT:-swift}"
swift_build_args=(--package-path "$PWD")
swift_script_args=(-target "$(uname -m)-apple-macosx14.0")
if [[ -n "${MODELDECK_SDK:-}" ]]; then
  swift_build_args+=(--sdk "$MODELDECK_SDK")
  swift_script_args+=(-sdk "$MODELDECK_SDK")
fi
if [[ -n "${MODELDECK_BUILD_SYSTEM:-}" ]]; then
  swift_build_args+=(--build-system "$MODELDECK_BUILD_SYSTEM")
fi
app_version="$(cat VERSION)"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Invalid application version: %s\n' "$app_version" >&2
  exit 1
fi
"$swift_tool" build -c "$configuration" "${swift_build_args[@]}" --product ModelDeck
binary_dir="$("$swift_tool" build -c "$configuration" "${swift_build_args[@]}" --show-bin-path)"
app="build/ModelDeck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/ModelDeck" "$app/Contents/MacOS/ModelDeck"
ditto "$binary_dir/ModelDeck_ModelDeckCore.bundle" "$app/Contents/Resources/ModelDeck_ModelDeckCore.bundle"
"$swift_tool" "${swift_script_args[@]}" scripts/generate-icon.swift build/ModelDeck.iconset
iconutil -c icns build/ModelDeck.iconset -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ModelDeck</string>
<key>CFBundleIdentifier</key><string>io.github.tommasinigiovanni.ModelDeck</string>
<key>CFBundleName</key><string>ModelDeck</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDisplayName</key><string>ModelDeck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$app_version</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf 'App pronta: %s/%s\n' "$PWD" "$app"
