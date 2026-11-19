#!/bin/zsh
# dev.sh — build a debug Wi-Fi Exit and run it from this terminal as /Applications/Wi-Fi Exit Dev.app.
#   ./dev.sh            build + run on the installed engine's state; quit with 종료 in the popup or Ctrl-C here
#   ./dev.sh --sample   run on the sample rules and exits in dev/sample instead (no engine needed).
#                       Rule switches and pause change only the sample in memory; other edits are refused.
#   ./dev.sh --dark     force the dark appearance (--light: light) to check colors without changing
#                       the system setting. Combines with --sample.
#   ./dev.sh --remove   delete /Applications/Wi-Fi Exit Dev.app
#
# Why a bundle in /Applications: on macOS 27 a menu bar manager (Hidden Bar 1.11+) collapses by
# asking macOS to keep only an allow-list of bundle ids, and macOS knows an app by its bundle id
# only when it runs from /Applications. A bare binary from build/ vanished on every collapse. The
# first time, ⌘-drag the icon right of Hidden Bar's arrow.
#
# Built with swiftc only (no Xcode, no Developer ID). The dev app has its own bundle id, so its
# settings and login item stay apart from the installed Wi-Fi Exit, and it is never registered as a
# login item. Like the release app it carries the engine in Contents/Helpers, and it drives whatever
# engine is in /Library/PrivilegedHelperTools through the sudoers rule. This script never installs
# the engine (that needs root); to install or update it from the dev build, run in a terminal:
#   "/Applications/Wi-Fi Exit Dev.app/Contents/MacOS/WifiExit" install     (asks for your password)
# and to remove everything again: the same with `uninstall`. The dev app is ad-hoc signed without the
# Network Extension entitlement, so 앱별 스플리팅 opens but cannot turn the proxy on.
set -euo pipefail
cd ${0:A:h}
NAME="Wi-Fi Exit Dev"
APP="/Applications/$NAME.app"
DEV_ID=com.miel.WifiExit.dev
BUILD=build/dev
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SOURCES=(app.swift rules_window.swift routes_window.swift outside.swift exit_reasons.swift ui_kit.swift
         shared.swift conditions.swift app_policy.swift app_identity.swift app_rules.swift popup.swift routes_quick.swift dev_sample.swift)
ENGINE_SOURCES=(engine.swift events.swift shared.swift conditions.swift)

# Only ever replace our own dev bundle, never the installed Wi-Fi Exit or anything else.
remove_app() {
  [[ -e $APP ]] || return 0
  local id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
  [[ $id == $DEV_ID ]] || { print -u2 "$APP 은 dev 빌드가 아니에요 (${id:-번들 ID 없음}). 건드리지 않았어요."; exit 1; }
  $LSREGISTER -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
}

# One Wi-Fi Exit at a time: two would put two icons in the menu bar, drive the same engine and both
# claim wifi-exit:// links. A previous dev build is quit so re-running this script restarts it; the
# installed Wi-Fi Exit is left alone.
ensure_not_running() {
  local pid exe i
  local -a dev other
  for pid in $(pgrep -x WifiExit); do
    exe=$(/bin/ps -p $pid -o comm= 2>/dev/null) || continue
    if [[ $exe == "$APP/"* || $exe == $PWD/$BUILD/* ]]; then dev+=($pid); else other+=($pid); fi
  done
  if (( ${#other} )); then
    print -u2 "Wi-Fi Exit가 실행 중이에요 (pid $other). 메뉴바에서 종료한 뒤 다시 실행하세요."
    exit 1
  fi
  (( ${#dev} )) || return 0
  print "이전 dev 빌드를 종료해요 (pid $dev)"
  kill $dev 2>/dev/null || true
  for pid in $dev; do
    for i in {1..20}; do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
    kill -0 $pid 2>/dev/null && kill -9 $pid 2>/dev/null || true
  done
}

appearance="" sample=""
for a in "$@"; do
  case $a in
    --dark)   appearance=dark ;;
    --light)  appearance=light ;;
    --sample) sample=$PWD/dev/sample ;;
    --remove) ensure_not_running; remove_app; print "지웠어요: $APP"; exit 0 ;;
    *)        print -u2 "사용법: ./dev.sh [--sample] [--dark | --light] | --remove"; exit 2 ;;
  esac
done
ensure_not_running

mkdir -p $BUILD
print "빌드: swiftc (-O, DEBUG)"
# Optimized like the release build (about as fast to compile here), so drawing and window resizing
# feel the same as in the shipped app; DEBUG keeps the sample mode and --dark/--light.
swiftc -target arm64-apple-macosx15.2 -O -D DEBUG -swift-version 5 -parse-as-library \
  -module-name WifiExit $SOURCES -o $BUILD/WifiExit
# The engine is built optimized like the release one and only when its sources changed: the app asks
# for an engine update whenever the bundled engine's code (CDHash) differs from the installed one.
if [[ ! -e $BUILD/wifi-exitd ]] || [[ -n $(find $ENGINE_SOURCES -newer $BUILD/wifi-exitd) ]]; then
  print "빌드: 엔진 (swiftc -O)"
  swiftc -target arm64-apple-macosx15.2 -O -swift-version 5 -parse-as-library $ENGINE_SOURCES -o $BUILD/wifi-exitd
  codesign --force --options runtime --sign - --identifier com.miel.WifiExit.engine $BUILD/wifi-exitd
fi

remove_app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp $BUILD/WifiExit "$APP/Contents/MacOS/WifiExit"
cp -p $BUILD/wifi-exitd "$APP/Contents/Helpers/wifi-exitd"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp geo/ipv4-country.bin "$APP/Contents/Resources/ipv4-country.bin"     # 라우팅 보기의 나라 표시 (geo/make_geo.sh)
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$DEV_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>WifiExit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>dev</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
  <key>LSMinimumSystemVersion</key><string>15.2</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$DEV_ID</string>
    <key>CFBundleURLSchemes</key><array><string>wifi-exit</string></array>
  </dict></array>
</dict></plist>
EOF
codesign --force --sign - "$APP"
$LSREGISTER -f "$APP"
# The app registers itself as a login item on its first run; the dev build must not.
defaults write $DEV_ID loginItemAsked -bool true

[[ -e "/Applications/Wi-Fi Exit.app" ]] && print "참고: /Applications/Wi-Fi Exit.app 도 있어요. wifi-exit:// 링크가 그쪽으로 갈 수 있어요."
print "실행: $APP${sample:+ (표본 상태)}${appearance:+ ($appearance)}"
export WIFIEXIT_APPEARANCE=$appearance WIFIEXIT_SAMPLE=$sample
exec "$APP/Contents/MacOS/WifiExit"
