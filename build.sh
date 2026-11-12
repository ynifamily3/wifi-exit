#!/bin/zsh
# "Wi-Fi Exit.app" 을 빌드하고 Developer ID 로 서명한다.
#   ./build.sh             빌드 + 서명
#   ./build.sh --install   빌드 + 서명 + /Applications 로 복사 + 다시 실행 + ~/.local/bin/wifi-exit CLI 링크
#   ./build.sh --notarize  빌드 + 서명 + 공증 + 스테이플
#   ./build.sh --notarize --install   공증한 앱을 /Applications 에 설치
# 아이콘은 icon/AppIcon.icns (다시 그리려면 icon/make_icns.sh)
# 엔진(engine.swift)이 바뀌었으면 설치 뒤 `wifi-exit install` (또는 앱의 '엔진 갱신')으로 root 쪽도 갱신한다.
set -euo pipefail
cd "${0:A:h}"

# 서명 인증서: WIFI_EXIT_IDENTITY 가 없으면 키체인의 첫 "Developer ID Application" 을 쓴다.
# 공증: notarytool store-credentials 로 저장한 키체인 프로필 이름 (WIFI_EXIT_NOTARY_PROFILE)
IDENTITY="${WIFI_EXIT_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
NOTARY_PROFILE="${WIFI_EXIT_NOTARY_PROFILE:-MenuShelf-notary}"
[[ -n "$IDENTITY" ]] || { echo "서명 인증서(Developer ID Application)가 없어요. WIFI_EXIT_IDENTITY 로 정해 주세요." >&2; exit 1; }
NAME="Wi-Fi Exit"
APP="build/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -parse-as-library app.swift rules_window.swift routes_window.swift outside.swift exit_reasons.swift shared.swift conditions.swift -o "$APP/Contents/MacOS/WifiExit"
swiftc -O -swift-version 5 -parse-as-library engine.swift events.swift shared.swift conditions.swift -o "$APP/Contents/Helpers/wifi-exitd"
# 안쪽부터 서명한다. 타임스탬프 서버가 가끔 응답하지 않아 몇 번 다시 시도한다.
sign() { for i in 1 2 3; do codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@" && return 0; sleep 3; done; return 1; }
sign --identifier com.miel.WifiExit.engine "$APP/Contents/Helpers/wifi-exitd"
sign "$APP"
codesign --verify --strict --verbose=2 "$APP"

notarize=0; install=0
for a in "$@"; do
  case "$a" in --notarize) notarize=1 ;; --install) install=1 ;; *) echo "unknown option: $a" >&2; exit 2 ;; esac
done

if (( notarize )); then
    ditto -c -k --keepParent "$APP" "build/WifiExit.zip"
    xcrun notarytool submit "build/WifiExit.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    xcrun stapler validate "$APP"
fi

if (( install )); then
    osascript -e "tell application \"$NAME\" to quit" >/dev/null 2>&1 || true
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    mkdir -p "$HOME/.local/bin"
    ln -sf "/Applications/$NAME.app/Contents/MacOS/WifiExit" "$HOME/.local/bin/wifi-exit"
    # build/ 사본도 wifi-exit:// 를 등록해 버리므로 등록을 지워 링크가 /Applications 쪽으로만 가게 한다
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
    open -g "/Applications/$NAME.app"
    echo "installed: /Applications/$NAME.app (CLI: ~/.local/bin/wifi-exit)"
fi
echo "built: $PWD/$APP"
