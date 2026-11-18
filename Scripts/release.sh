#!/bin/zsh
# Builds, notarizes and publishes a Tea release.
#
#   Scripts/release.sh                     the real release: checks the tag, the tree and
#                                          origin/main, creates the GitHub release, then
#                                          adds the item to appcast.xml. Pushing the appcast
#                                          is left to you, and printed at the end.
#   Scripts/release.sh --local <base-url>  a rehearsal: skips the git and GitHub checks,
#                                          serves the zip from <base-url>, and writes
#                                          build/release/appcast.xml instead of the repo's.
#                                          It still notarizes.
#
# Needs the Developer ID identity, the notarytool keychain profile tea-notary, and Sparkle's
# EdDSA private key in the login keychain. Bump CFBundleShortVersionString and
# CFBundleVersion in Info.plist and commit them first.
set -euo pipefail
cd "${0:A:h}/.."

repo=ianiv/tea
profile=tea-notary
team=7EN8DG9MKN

local_mode=0
base=
case ${1:-} in
  '') (( $# == 0 )) || { echo "usage: Scripts/release.sh [--local <base-url>]" >&2; exit 64; } ;;
  --local)
    (( $# == 2 )) || { echo "usage: Scripts/release.sh [--local <base-url>]" >&2; exit 64; }
    local_mode=1
    base=$2
    [[ $base == */ ]] || base+=/
    ;;
  *) echo "usage: Scripts/release.sh [--local <base-url>]" >&2; exit 64 ;;
esac

die() { echo "error: $*" >&2; exit 1; }

v=$(plutil -extract CFBundleShortVersionString raw Info.plist)
b=$(plutil -extract CFBundleVersion raw Info.plist)
out=build/release
app=build/Tea.app

# 1. Checks.
[[ $v =~ '^[0-9]+(\.[0-9]+)*$' ]] || die "CFBundleShortVersionString \"$v\" isn't like 1.2.3"
[[ $b =~ '^[0-9]+$' ]] || die "CFBundleVersion \"$b\" isn't an integer"

if (( ! local_mode )); then
  gh auth status >/dev/null 2>&1 || die "gh isn't logged in; run gh auth login"
  if git rev-parse -q --verify "refs/tags/v$v" >/dev/null; then
    die "tag v$v already exists locally"
  fi
  remote=0
  git ls-remote --exit-code --tags origin "refs/tags/v$v" >/dev/null || remote=$?
  case $remote in
    2) ;;
    0) die "tag v$v already exists on origin" ;;
    *) die "couldn't list origin's tags (git ls-remote exited $remote)" ;;
  esac
  if gh release view "v$v" -R $repo >/dev/null 2>&1; then
    die "release v$v already exists on GitHub"
  fi
  [[ -z $(git status --porcelain) ]] || die "the working tree isn't clean"
  git fetch -q origin main
  [[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] ||
    die "HEAD isn't origin/main; push or pull first, so the tag points at a pushed commit"
fi

for existing in $(grep -o '<sparkle:version>[^<]*' appcast.xml | sed 's/.*>//' || true); do
  (( b > existing )) || die "CFBundleVersion $b isn't greater than $existing, already in appcast.xml"
done
if grep -qF "<sparkle:shortVersionString>$v</sparkle:shortVersionString>" appcast.xml; then
  die "version $v is already in appcast.xml"
fi

# The keychain's Sparkle key must match SUPublicEDKey, or installed copies would reject the
# update. Checked before building, so a wrong key doesn't cost a notarization round trip.
# generate_keys -p prints only the public key; neither key is printed here.
[[ -x .deps/sparkle/bin/generate_keys ]] || die "Sparkle's tools aren't in .deps/sparkle; run ./build.sh once to fetch them"
keychain_key=$(.deps/sparkle/bin/generate_keys -p 2>/dev/null || true)
plist_key=$(plutil -extract SUPublicEDKey raw Info.plist)
[[ -n $keychain_key && $keychain_key == "$plist_key" ]] ||
  die "the keychain's Sparkle key doesn't match SUPublicEDKey in Info.plist (or there's none)"

rm -rf $out && mkdir -p $out

# 2. Build: Developer ID, hardened runtime, timestamp, updater on.
./build.sh --release

# 3. Notarize. --wait's exit code doesn't say whether Apple accepted it, so read the status,
# and fetch the log when it isn't Accepted, even if submit itself failed.
ditto -c -k --keepParent $app $out/notarize.zip
xcrun notarytool submit $out/notarize.zip --keychain-profile $profile --wait --output-format json > $out/notary.json || true
notary_status=$(plutil -extract status raw $out/notary.json 2>/dev/null || echo unknown)
notary_id=$(plutil -extract id raw $out/notary.json 2>/dev/null || echo unknown)
if [[ $notary_status != Accepted ]]; then
  echo "notarization $notary_id: $notary_status" >&2
  [[ $notary_id == unknown ]] || xcrun notarytool log "$notary_id" --keychain-profile $profile >&2 || true
  exit 1
fi
echo "notarized ($notary_id)"

# 4. Staple.
xcrun stapler staple $app
xcrun stapler validate $app

# 5. Check what users will get.
codesign --verify --strict --deep --verbose=2 $app
assessment=$(spctl -a -vv -t exec $app 2>&1 || true)
echo $assessment
[[ $assessment == *accepted* && $assessment == *"source=Notarized Developer ID"* ]] ||
  die "Gatekeeper doesn't accept $app as notarized"
[[ $(codesign -dvv $app/Contents/PlugIns/TeaWidget.appex 2>&1) == *"TeamIdentifier=$team"* ]] ||
  die "the widget isn't signed by team $team"

# 6. Zip the stapled app.
zip=$out/Tea-$v.zip
ditto -c -k --keepParent $app $zip
rm $out/notarize.zip

# 7. EdDSA-sign it, with the key from the login keychain (checked against SUPublicEDKey above).
sig=$(.deps/sparkle/bin/sign_update -p $zip)
len=$(stat -f %z $zip)
.deps/sparkle/bin/sign_update --verify $zip "$sig"

# 8. The appcast item, inserted newest first below the marker line.
(( local_mode )) || base=https://github.com/$repo/releases/download/v$v/
cat > $out/item.xml <<EOF
    <item>
      <title>Version $v</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$b</sparkle:version>
      <sparkle:shortVersionString>$v</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$repo/releases/tag/v$v</sparkle:fullReleaseNotesLink>
      <enclosure url="${base}Tea-$v.zip" length="$len" type="application/octet-stream" sparkle:edSignature="$sig"/>
    </item>
EOF
# Built in $out either way; real mode copies it over appcast.xml only once the release exists.
feed=$out/appcast.xml
grep -q 'release.sh inserts each release' appcast.xml || die "appcast.xml has no insertion marker"
awk -v item=$out/item.xml '{print} /release.sh inserts each release/ {while ((getline l < item) > 0) print l}' \
  appcast.xml > $out/appcast.tmp
mv $out/appcast.tmp $feed
xmllint --noout $feed

if (( local_mode )); then
  echo
  echo "rehearsal ready in $out ($zip, $feed). To serve it:"
  echo "  python3 -m http.server 8765 --bind 127.0.0.1 --directory $out"
  exit 0
fi

# 9. The GitHub release, at the commit just checked against origin/main.
if ! gh release create "v$v" $zip -R $repo --target "$(git rev-parse HEAD)" --title "Tea $v" --generate-notes; then
  echo "error: gh release create failed. appcast.xml is untouched." >&2
  echo "If it left a release or tag behind (gh release view v$v -R $repo), remove it before retrying:" >&2
  echo "  gh release delete v$v -R $repo --yes --cleanup-tag" >&2
  exit 1
fi
cp $feed appcast.xml

# 10. The appcast goes up only after the asset exists, or clients would get a 404.
echo
echo "released Tea $v ($b). Now publish the appcast:"
echo "  git add appcast.xml && git commit -m \"Release $v\" && git push origin main"
