#!/bin/zsh
# Build Ratio and package it for download as dist/Ratio.dmg and dist/Ratio.zip.
# Signs with the first "Developer ID Application" identity in your keychain (or SIGN_IDENTITY),
# and notarizes with the notarytool keychain profile NOTARY_PROFILE (default "notary"), created
# once per Mac with `xcrun notarytool store-credentials notary`. Without an identity the app keeps
# build.sh's ad-hoc signature; REQUIRE_NOTARIZED=1 makes a missing identity or profile an error.
set -eu
cd "$(dirname "$0")"
./build.sh
identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ { print $2; exit }')}
profile=${NOTARY_PROFILE:-notary}
notarize=false
[[ -n "$identity" ]] && xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 && notarize=true
if [[ "${REQUIRE_NOTARIZED:-}" == 1 ]] && ! $notarize; then
  [[ -z "$identity" ]] && print -u2 'No "Developer ID Application" certificate in your keychain. Create one in Xcode → Settings → Accounts → Manage Certificates.'
  [[ -n "$identity" ]] && print -u2 "No notarytool profile \"$profile\". Run once: xcrun notarytool store-credentials $profile --apple-id <email> --team-id <team id>"
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Ratio.app/Contents/Info.plist)
rm -rf dist && mkdir -p dist

# Submit a file to Apple's notary service and fail with its log unless it is accepted.
submit() {
  local result id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json)
  print -r -- "$result"
  id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$result")
  if [[ $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$result") != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$profile"
    exit 1
  fi
}

if [[ -n "$identity" ]]; then
  # Hardened runtime is required for notarization; entitlements keep browser Automation access.
  codesign --force --options runtime --timestamp --entitlements entitlements.plist --sign "$identity" Ratio.app
fi
codesign --verify --deep --strict Ratio.app
if $notarize; then
  ditto -c -k --keepParent Ratio.app dist/notarize.zip
  submit dist/notarize.zip
  rm dist/notarize.zip
  xcrun stapler staple Ratio.app
fi
ditto -c -k --keepParent Ratio.app dist/Ratio.zip

staging=$(mktemp -d "${TMPDIR:-/tmp}/ratio-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto Ratio.app "$staging/Ratio.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Ratio $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov dist/Ratio.dmg
[[ -n "$identity" ]] && codesign --force --timestamp --sign "$identity" dist/Ratio.dmg
if $notarize; then
  submit dist/Ratio.dmg
  xcrun stapler staple dist/Ratio.dmg
  # Confirm Gatekeeper accepts both the app and the disk image as a downloaded copy would be checked.
  spctl --assess --type execute --verbose Ratio.app
  spctl --assess --type open --context context:primary-signature --verbose dist/Ratio.dmg
fi
hdiutil verify dist/Ratio.dmg
print "Packaged Ratio $version in native/dist ($($notarize && print 'signed and notarized' || { [[ -n "$identity" ]] && print 'signed, not notarized' || print 'ad-hoc signed'; }))"
