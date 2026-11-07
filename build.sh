#!/bin/zsh
# Builds Tea.app into ./build. Pass --install to also copy it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"

# App icon: regenerate Resources/AppIcon.icns when the drawing script changes.
icns=Resources/AppIcon.icns
if [[ ! -f $icns || Scripts/make-icon.swift -nt $icns ]]; then
  mkdir -p Resources build
  iconset=build/AppIcon.iconset
  rm -rf $iconset && mkdir -p $iconset
  xcrun --sdk macosx swift Scripts/make-icon.swift build/icon-1024.png >/dev/null
  for size in 16 32 128 256 512; do
    sips -z $size $size build/icon-1024.png --out $iconset/icon_${size}x${size}.png >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out $iconset/icon_${size}x${size}@2x.png >/dev/null
  done
  iconutil -c icns $iconset -o $icns
  echo "made $icns"
fi

app="build/Tea.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun --sdk macosx swiftc \
  -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -o "$app/Contents/MacOS/Tea" \
  Sources/Tea.swift

cp Info.plist "$app/Contents/Info.plist"
cp $icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app" >/dev/null

echo "built $app"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Tea.app
  cp -R "$app" ~/Applications/
  echo "installed ~/Applications/Tea.app"
fi
