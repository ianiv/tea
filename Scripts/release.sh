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
# Also takes --team <ID>, --identity <name>, --notary-profile <name> and --config <file>,
# in any order, which beat TEA_TEAM_ID, TEA_RELEASE_IDENTITY and TEA_NOTARY_PROFILE in the
# environment, which beat signing.env (see signing.env.example).
#
# Needs a team (TEA_TEAM_ID) and its Developer ID identity in the keychain, the notarytool
# keychain profile (TEA_NOTARY_PROFILE, default tea-notary), and Sparkle's EdDSA private
# key in the login keychain. Bump CFBundleShortVersionString and CFBundleVersion in
# Info.plist and commit them first.
set -euo pipefail
cd "${0:A:h}/.."
source Scripts/config.zsh

# This project's home and update channel; not part of the signing configuration.
repo=ianiv/tea

usage() {
  echo "usage: Scripts/release.sh [--local <base-url>] [--team <ID>] [--identity <name>] [--notary-profile <name>] [--config <file>]" >&2
  exit 64
}

local_mode=0
base=
cli_team=
cli_identity=
cli_profile=
cli_config=
while (( $# )); do
  case $1 in
    --local) (( $# >= 2 )) || usage; local_mode=1; base=$2; shift ;;
    --team) (( $# >= 2 )) || usage; cli_team=$2; shift ;;
    --identity) (( $# >= 2 )) || usage; cli_identity=$2; shift ;;
    --notary-profile) (( $# >= 2 )) || usage; cli_profile=$2; shift ;;
    --config) (( $# >= 2 )) || usage; cli_config=$2; shift ;;
    *) usage ;;
  esac
  shift
done
if (( local_mode )); then
  [[ -n $base ]] || usage
  [[ $base == */ ]] || base+=/
fi

if [[ -n $cli_config ]]; then
  tea_read_config "$cli_config" 1
else
  tea_read_config signing.env 0
fi
team=${cli_team:-${TEA_TEAM_ID:-}}
identity=${cli_identity:-${TEA_RELEASE_IDENTITY:-}}
profile=${cli_profile:-${TEA_NOTARY_PROFILE:-tea-notary}}

die() { echo "error: $*" >&2; exit 1; }

# A release states its team, so the checks in step 5 have something to compare against.
[[ -n $team ]] || die "--release needs a team: set TEA_TEAM_ID in signing.env (see signing.env.example), or pass --team"
if [[ ! $team =~ '^[A-Z0-9]{10}$' ]]; then
  echo "error: team ID \"$team\" isn't 10 capital letters and digits" >&2
  exit 64
fi

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

# One network call, but it saves a build and a notarization upload when the profile is missing.
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 ||
  die "notarytool keychain profile \"$profile\" not found or not valid (xcrun notarytool store-credentials $profile …)"

rm -rf $out && mkdir -p $out

# 2. Build: Developer ID, hardened runtime, timestamp, updater on.
build_args=(--release --team "$team")
[[ -z $identity ]] || build_args+=(--identity "$identity")
[[ -z $cli_config ]] || build_args+=(--config "$cli_config")
./build.sh "${build_args[@]}"

# 3. Notarize. --wait's exit code doesn't say whether Apple accepted it, so read the status,
# and fetch the log when it isn't Accepted, even if submit itself failed.
ditto -c -k --keepParent $app $out/notarize.zip
xcrun notarytool submit $out/notarize.zip --keychain-profile "$profile" --wait --output-format json > $out/notary.json || true
notary_status=$(plutil -extract status raw $out/notary.json 2>/dev/null || echo unknown)
notary_id=$(plutil -extract id raw $out/notary.json 2>/dev/null || echo unknown)
if [[ $notary_status != Accepted ]]; then
  echo "notarization $notary_id: $notary_status" >&2
  [[ $notary_id == unknown ]] || xcrun notarytool log "$notary_id" --keychain-profile "$profile" >&2 || true
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
group="$team.$(plutil -extract CFBundleIdentifier raw Info.plist)"
for bundle in $app $app/Contents/PlugIns/TeaWidget.appex; do
  [[ $(codesign -dvv $bundle 2>&1) == *"TeamIdentifier=$team"* ]] ||
    die "$bundle isn't signed by team $team"
  [[ $(codesign -d --entitlements - --xml $bundle 2>/dev/null) == *"<string>$group</string>"* ]] ||
    die "$bundle's entitlements don't have the App Group $group"
  [[ $(plutil -extract TeaAppGroup raw $bundle/Contents/Info.plist 2>/dev/null) == "$group" ]] ||
    die "$bundle's Info.plist doesn't have TeaAppGroup $group"
done

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
