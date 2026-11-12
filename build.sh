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

# Signing: the desktop widget needs a real identity, because the App Group the app and
# widget share (7EN8DG9MKN.local.ianiv.tea) is authorized by the signature's team ID.
# Set TEA_SIGN_IDENTITY to another identity, or to - for an ad-hoc build without the widget.
ident=${TEA_SIGN_IDENTITY:-"Apple Development: Ianiv Schweber (66J53X6839)"}
widget=1
if [[ $ident == - ]]; then
  widget=0
else
  # Captured first: under pipefail, grep -q exiting early can fail the pipeline.
  ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
fi
if (( widget )) && ! grep -qF -- "\"$ident\"" <<<"$ids"; then
  echo "warning: signing identity \"$ident\" not found; building ad hoc, without the widget" >&2
  ident=-
  widget=0
fi

app="build/Tea.app"
appex="$app/Contents/PlugIns/TeaWidget.appex"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun --sdk macosx swiftc \
  -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -o "$app/Contents/MacOS/Tea" \
  Sources/Shared.swift Sources/Tea.swift

cp Info.plist "$app/Contents/Info.plist"
cp $icns "$app/Contents/Resources/AppIcon.icns"

if (( widget )); then
  mkdir -p "$appex/Contents/MacOS"
  xcrun --sdk macosx swiftc \
    -O -parse-as-library -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -application-extension -Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$appex/Contents/MacOS/TeaWidget" \
    Sources/Shared.swift Sources/Widget/TeaWidget.swift
  cp Widget-Info.plist "$appex/Contents/Info.plist"
  for key in CFBundleShortVersionString CFBundleVersion; do
    plutil -replace $key -string "$(plutil -extract $key raw Info.plist)" "$appex/Contents/Info.plist"
  done
  # Inside out, without --deep, so each gets its own entitlements.
  codesign --force --sign "$ident" --entitlements Widget.entitlements "$appex" >/dev/null
  codesign --force --sign "$ident" --entitlements Tea.entitlements "$app" >/dev/null
else
  codesign --force --sign - "$app" >/dev/null
fi

echo "built $app"

# Only the installed copy's widget should be registered, or the widget gallery lists two.
# --install unregisters it too, since a run of build/Tea.app may have registered it.
if (( widget )); then
  pluginkit -r "$appex" 2>/dev/null || true
fi

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Tea.app
  cp -R "$app" ~/Applications/
  echo "installed ~/Applications/Tea.app"
  if (( widget )); then
    pluginkit -a ~/Applications/Tea.app/Contents/PlugIns/TeaWidget.appex
    echo "registered the widget"
  fi
fi
