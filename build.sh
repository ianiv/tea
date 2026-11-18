#!/bin/zsh
# Builds Tea.app into ./build.
#   --install          also copies it to ~/Applications
#   --release          signs with Developer ID, hardened runtime and a secure timestamp, and
#                      turns on the Sparkle updater (TeaChecksForUpdates). It doesn't
#                      notarize: that's Scripts/release.sh.
#   --team <ID>        the Apple Developer team to sign for (TEA_TEAM_ID)
#   --identity <name>  the certificate to sign with, by name or SHA-1, or - for ad hoc
#                      (TEA_SIGN_IDENTITY, or TEA_RELEASE_IDENTITY with --release)
#   --config <file>    read the signing settings from <file> instead of signing.env
# Flags beat environment variables, which beat signing.env (gitignored; see
# signing.env.example). With nothing configured, the build is ad hoc, without the widget.
set -euo pipefail
cd "${0:A:h}"
source Scripts/config.zsh

die() { echo "error: $*" >&2; exit 1; }
usage() {
  echo "usage: ./build.sh [--install] [--release] [--team <ID>] [--identity <name|->] [--config <file>]" >&2
  exit 64
}

install=0
release=0
cli_team=
cli_identity=
cli_config=
while (( $# )); do
  case $1 in
    --install) install=1 ;;
    --release) release=1 ;;
    --team) (( $# >= 2 )) || usage; cli_team=$2; shift ;;
    --identity) (( $# >= 2 )) || usage; cli_identity=$2; shift ;;
    --config) (( $# >= 2 )) || usage; cli_config=$2; shift ;;
    *) usage ;;
  esac
  shift
done

if [[ -n $cli_config ]]; then
  tea_read_config "$cli_config" 1
else
  tea_read_config signing.env 0
fi

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

# Signing. The desktop widget needs a real identity, because the App Group the app and
# widget share (<team>.<CFBundleIdentifier>) is authorized by the signature's team ID.
# Resolved before the old build is deleted, so a configuration error leaves it in place:
#   - identity -: ad hoc, without the widget (an error with --release)
#   - an identity: it must be in the keychain, and its certificate's team (the OU) becomes
#     the team; a configured team that differs is an error
#   - only a team: the first valid "Apple Development: " (or, with --release, "Developer
#     ID Application: ") identity whose certificate is for that team
#   - neither: ad hoc, without the widget (an error with --release)
# A configured team or identity that can't be satisfied is an error, never a quiet ad-hoc
# build. Signing is by SHA-1, so a renewed certificate with the same name isn't ambiguous.
team=${cli_team:-${TEA_TEAM_ID:-}}
if (( release )); then
  ident=${cli_identity:-${TEA_RELEASE_IDENTITY:-}}
  prefix="Developer ID Application: "
  # Hardened runtime and a secure timestamp, both required for notarization.
  sign_flags=(--options runtime --timestamp)
else
  ident=${cli_identity:-${TEA_SIGN_IDENTITY:-}}
  prefix="Apple Development: "
  sign_flags=()
fi
if [[ -n $team && ! $team =~ '^[A-Z0-9]{10}$' ]]; then
  echo "error: team ID \"$team\" isn't 10 capital letters and digits" >&2
  exit 64
fi

widget=1
sign_id=-
if [[ $ident == - ]]; then
  (( ! release )) || die "--release can't build ad hoc; TEA_RELEASE_IDENTITY must name a Developer ID identity"
  widget=0
elif [[ -n $ident || -n $team ]]; then
  ids=$(tea_identities)
  shas=()
  names=()
  for line in ${(f)ids}; do
    [[ $line =~ '^ *[0-9]+\) ([0-9A-F]{40}) "(.*)"$' ]] || continue
    (( ! ${shas[(Ie)$match[1]]} )) || continue   # the same identity in two keychains
    shas+=($match[1])
    names+=("$match[2]")
  done
  if [[ -n $ident ]]; then
    found=()
    for (( i = 1; i <= $#shas; i++ )); do
      if [[ ${names[i]} == "$ident" || ${shas[i]} == "${(U)ident}" ]]; then
        found+=($i)
      fi
    done
    (( $#found > 0 )) || die "signing identity \"$ident\" isn't a valid identity in the keychain (security find-identity -v -p codesigning)"
    (( $#found == 1 )) || die "signing identity \"$ident\" is ambiguous; set it to the SHA-1 instead"
    sign_id=${shas[$found[1]]}
    sign_name=${names[$found[1]]}
    cert_team=$(tea_cert_team "$sign_id" "$sign_name")
    [[ -n $cert_team ]] || die "couldn't read the team from the certificate of \"$sign_name\""
    if [[ -n $team && $team != "$cert_team" ]]; then
      die "identity \"$sign_name\" belongs to team $cert_team, not $team"
    fi
    team=$cert_team
  else
    for (( i = 1; i <= $#shas; i++ )); do
      [[ ${names[i]} == "$prefix"* ]] || continue
      if [[ $(tea_cert_team "${shas[i]}" "${names[i]}") == "$team" ]]; then
        sign_id=${shas[i]}
        sign_name=${names[i]}
        break
      fi
    done
    if [[ $sign_id == - ]]; then
      if (( release )); then
        die "no valid ${prefix%: } identity for team $team in the keychain"
      fi
      die "no valid ${prefix%: } identity for team $team in the keychain; pass --identity - for an ad-hoc build"
    fi
  fi
  echo "signing with \"$sign_name\" ($sign_id)"
else
  (( ! release )) || die "--release needs a team: set TEA_TEAM_ID in signing.env (see signing.env.example), or pass --team"
  echo "note: no signing team configured (see signing.env.example); building ad hoc, without the widget" >&2
  widget=0
fi
if (( widget )); then
  group="$team.$(plutil -extract CFBundleIdentifier raw Info.plist)"
fi
sign() { codesign --force --sign "$sign_id" "${sign_flags[@]}" "$@" >/dev/null }

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

  # The App Group, from the same $group in both places: the entitlements (the committed
  # files are templates with an empty group array) and each bundle's TeaAppGroup, which
  # AppGroup.id reads. Ad-hoc builds get neither, so they never touch a group container.
  # plutil splits key paths on dots, hence the escapes.
  for pair in Tea.entitlements:build/Tea.entitlements Widget.entitlements:build/TeaWidget.entitlements; do
    cp "${pair%%:*}" "${pair#*:}"
    plutil -replace 'com\.apple\.security\.application-groups' -json "[\"$group\"]" "${pair#*:}"
  done
  plutil -insert TeaAppGroup -string "$group" "$app/Contents/Info.plist"
  plutil -insert TeaAppGroup -string "$group" "$appex/Contents/Info.plist"
fi

# Inside out, without --deep, so each gets its own entitlements. Sparkle's helpers come
# before the framework, which is signed last (that signs Versions/Current).
sign "$fw/Versions/B/Autoupdate"
sign "$fw/Versions/B/Updater.app"
sign "$fw"
if (( widget )); then
  sign --entitlements build/TeaWidget.entitlements "$appex"
  sign --entitlements build/Tea.entitlements "$app"
  # A wrong team would surface only at runtime, as macOS asking for access to other apps'
  # data, so check it here.
  for bundle in "$appex" "$app"; do
    signed=$(codesign -dvv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [[ $signed == "$team" ]] || die "$bundle is signed with team ${signed:-none}, expected $team"
  done
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
