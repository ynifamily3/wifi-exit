#!/bin/zsh
# icon/make_icon.swift 로 1024 그림을 그리고, 크기별로 줄여 icon/AppIcon.icns 를 만든다.
set -euo pipefail
cd "${0:A:h}"
tmp=$(mktemp -d)
swiftc -O make_icon.swift -o "$tmp/make_icon"
"$tmp/make_icon" AppIcon-1024.png
set_dir="$tmp/AppIcon.iconset"; mkdir -p "$set_dir"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon-1024.png --out "$set_dir/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d AppIcon-1024.png --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o AppIcon.icns
rm -rf "$tmp"
echo "wrote $PWD/AppIcon.icns"
