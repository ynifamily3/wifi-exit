#!/bin/zsh
# "Wi-Fi Exit 앱 규칙.app" (투명 프록시 시스템 확장을 담은 작은 앱)을 빌드한다. 지금 앱(../build.sh)과는 따로 간다.
#   ./build.sh                       빌드 + Developer ID 서명 (프로필은 Xcode 가 계정에서 자동으로 받음)
#   ./build.sh --notarize            + 공증·스테이플, build/Wi-Fi-Exit-AppRules-<버전>.zip
#   ./build.sh --notarize --install  + /Applications 에 복사
# 필요한 것: Xcode, XcodeGen(brew install xcodegen), Xcode 에 개발자 계정, 키체인의 Developer ID Application 인증서.
#
# 시스템 확장은 권한(Network Extension)이 든 Developer ID 프로필이 있어야 켜진다. 기기 등록 없이 받으려고
# 서명 없이 아카이브 → 권한을 넣어 임시 서명 → Xcode 내보내기(developer-id, 자동 서명)가 프로필을 받아 다시 서명한다.
set -euo pipefail
cd "${0:A:h}"

IDENTITY="${WIFI_EXIT_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "서명 인증서(Developer ID Application)가 없어요. WIFI_EXIT_IDENTITY 로 정해 주세요." >&2; exit 1; }
export TEAM_ID="${TEAM_ID:-$(print -r -- "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')}"
[[ -n "$TEAM_ID" ]] || { echo "팀 ID 를 못 찾았어요. TEAM_ID 로 정해 주세요." >&2; exit 1; }
NOTARY_PROFILE="${WIFI_EXIT_NOTARY_PROFILE:-MenuShelf-notary}"
# 버전은 본 앱과 같게
export APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ../Info.plist)"
export APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' ../Info.plist)"
NAME="Wi-Fi Exit 앱 규칙"
EXT="com.miel.WifiExit.AppRules.proxy.systemextension"

notarize=0; install=0
for a in "$@"; do
  case "$a" in --notarize) notarize=1 ;; --install) install=1 ;; *) echo "unknown option: $a" >&2; exit 2 ;; esac
done

command -v xcodegen >/dev/null || { echo "XcodeGen 이 필요해요: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
rm -rf build
xcodebuild -project WifiExitAppRules.xcodeproj -scheme WifiExitAppRules -configuration Release \
  -archivePath build/AppRules.xcarchive CODE_SIGNING_ALLOWED=NO archive | grep -E "error:|ARCHIVE" || true
ARC="build/AppRules.xcarchive/Products/Applications/WifiExitAppRules.app"
[[ -d "$ARC/Contents/Library/SystemExtensions/$EXT" ]] || { echo "아카이브에 확장이 없어요" >&2; exit 1; }
codesign -s - --force --options runtime --entitlements Proxy/Proxy.entitlements "$ARC/Contents/Library/SystemExtensions/$EXT"
codesign -s - --force --options runtime --entitlements App/App.entitlements "$ARC"

cat > build/export.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>developer-id</string><key>signingStyle</key><string>automatic</string><key>teamID</key><string>$TEAM_ID</string></dict></plist>
P
xcodebuild -exportArchive -archivePath build/AppRules.xcarchive -exportPath build/export \
  -exportOptionsPlist build/export.plist -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
# 보기 좋은 이름으로
mv "build/export/WifiExitAppRules.app" "build/$NAME.app"
APP="build/$NAME.app"
codesign --verify --strict --deep "$APP"

if (( notarize )); then
  ZIP="build/Wi-Fi-Exit-AppRules-$APP_VERSION.zip"
  ditto -c -k --keepParent "$APP" build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait | grep -E "status:" | tail -1
  xcrun stapler staple "$APP" | tail -1
  spctl --assess --type execute -vv "$APP" 2>&1 | tail -1
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  echo "zip: $PWD/$ZIP"
fi

if (( install )); then
  rm -rf "/Applications/$NAME.app"
  ditto "$APP" "/Applications/$NAME.app"
  echo "installed: /Applications/$NAME.app"
fi
echo "built: $PWD/$APP"
