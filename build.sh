#!/bin/zsh
# Builds Tea.app into ./build.
#   --install  also copies it to ~/Applications
#   --release  signs with Developer ID, hardened runtime and a secure timestamp, and turns
#              on the Sparkle updater (TeaChecksForUpdates). It doesn't notarize: that's
#              Scripts/release.sh.
set -euo pipefail
cd "${0:A:h}"

install=0
release=0
for arg in "$@"; do
  case $arg in
    --install) install=1 ;;
    --release) release=1 ;;
    *) echo "usage: ./build.sh [--install] [--release]" >&2; exit 64 ;;
  esac
done

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

# Sparkle, pinned and checksummed, cached in .deps/ (gitignored). Fetched before the old
# build is deleted, so a failed download leaves it in place. To build offline, seed the
# cache by copying the tarball into .deps/.
sparkle_version=2.10.1
sparkle_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
sparkle=.deps/sparkle-$sparkle_version
if [[ ! -d $sparkle/Sparkle.framework ]]; then
  mkdir -p .deps
  tarball=.deps/Sparkle-$sparkle_version.tar.xz
  if [[ ! -f $tarball ]]; then
    curl -fsSL --retry 3 -o $tarball.part \
      https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz
    mv $tarball.part $tarball
  fi
  if ! echo "$sparkle_sha256  $tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
    rm -f $tarball
    echo "error: $tarball doesn't match the pinned sha256; deleted it" >&2
    exit 1
  fi
  rm -rf $sparkle.tmp && mkdir -p $sparkle.tmp
  tar -xJf $tarball -C $sparkle.tmp
  mv $sparkle.tmp $sparkle
fi
ln -sfn sparkle-$sparkle_version .deps/sparkle   # Scripts/release.sh uses .deps/sparkle/bin

# Signing: the desktop widget needs a real identity, because the App Group the app and
# widget share (7EN8DG9MKN.local.ianiv.tea) is authorized by the signature's team ID.
# Set TEA_SIGN_IDENTITY to another identity, or to - for an ad-hoc build without the widget.
# --release ignores it and uses TEA_RELEASE_IDENTITY or the Developer ID, with no fallback.
widget=1
sign_flags=()
if (( release )); then
  ident=${TEA_RELEASE_IDENTITY:-"Developer ID Application: Ianiv Schweber (7EN8DG9MKN)"}
  if [[ $ident == - ]]; then
    echo "error: --release can't build ad hoc; TEA_RELEASE_IDENTITY must name a Developer ID identity" >&2
    exit 1
  fi
  # Hardened runtime and a secure timestamp, both required for notarization.
  sign_flags=(--options runtime --timestamp)
else
  ident=${TEA_SIGN_IDENTITY:-"Apple Development: Ianiv Schweber (66J53X6839)"}
fi
if [[ $ident == - ]]; then
  widget=0
else
  # Captured first: under pipefail, grep -q exiting early can fail the pipeline.
  ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
fi
if (( widget )) && ! grep -qF -- "\"$ident\"" <<<"$ids"; then
  if (( release )); then
    echo "error: release signing identity \"$ident\" not found" >&2
    exit 1
  fi
  echo "warning: signing identity \"$ident\" not found; building ad hoc, without the widget" >&2
  ident=-
  widget=0
fi
sign() { codesign --force --sign "$ident" "${sign_flags[@]}" "$@" >/dev/null }

app="build/Tea.app"
appex="$app/Contents/PlugIns/TeaWidget.appex"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

xcrun --sdk macosx swiftc \
  -O -parse-as-library -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/Tea" \
  Sources/Shared.swift Sources/Tea.swift

cp Info.plist "$app/Contents/Info.plist"
cp $icns "$app/Contents/Resources/AppIcon.icns"
# Only release builds start the updater: dev builds share the bundle ID and defaults, so
# an outdated one would otherwise offer to replace itself with the latest release.
if (( release )); then
  plutil -insert TeaChecksForUpdates -bool YES "$app/Contents/Info.plist"
fi

# Every build embeds Sparkle, since the app links it. Tea isn't sandboxed, so Sparkle's
# XPC services are unused; removing them breaks the framework's seal, so it's re-signed below.
fw="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.framework" "$fw"          # ditto keeps the Versions symlinks
rm -rf "$fw/Versions/B/XPCServices" "$fw/XPCServices"

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
fi

# Inside out, without --deep, so each gets its own entitlements. Sparkle's helpers come
# before the framework, which is signed last (that signs Versions/Current).
sign "$fw/Versions/B/Autoupdate"
sign "$fw/Versions/B/Updater.app"
sign "$fw"
if (( widget )); then
  sign --entitlements Widget.entitlements "$appex"
  sign --entitlements Tea.entitlements "$app"
else
  sign "$app"
fi

echo "built $app"

# Only the installed copy's widget should be registered, or the widget gallery lists two.
# --install unregisters it too, since a run of build/Tea.app may have registered it.
if (( widget )); then
  pluginkit -r "$appex" 2>/dev/null || true
fi

if (( install )); then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Tea.app
  cp -R "$app" ~/Applications/
  echo "installed ~/Applications/Tea.app"
  if (( widget )); then
    pluginkit -a ~/Applications/Tea.app/Contents/PlugIns/TeaWidget.appex
    echo "registered the widget"
  fi
fi
