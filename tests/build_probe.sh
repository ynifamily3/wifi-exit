#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
IDENTITY="${WIFI_EXIT_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "Developer ID Application 인증서가 필요해요" >&2; exit 1; }
APP='build/Split Probe.app'
mkdir -p "$APP/Contents/MacOS"
swiftc -target arm64-apple-macosx15.2 -swift-version 5 -O -parse-as-library tests/NetworkProbe.swift -o "$APP/Contents/MacOS/SplitProbe"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.miel.WifiExit.SplitProbe</string><key>CFBundleName</key><string>Split Probe</string><key>CFBundleExecutable</key><string>SplitProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string></dict></plist>
P
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
echo "Probe: $PWD/$APP"
