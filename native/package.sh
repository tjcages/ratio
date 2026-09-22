#!/bin/zsh
# Build Ratio and package it for download as dist/Ratio.dmg and dist/Ratio.zip.
# Set SIGN_IDENTITY to a "Developer ID Application" identity to sign for distribution, and
# NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD (an app-specific password) to notarize.
# Without them the app keeps build.sh's ad-hoc signature.
set -eu
cd "$(dirname "$0")"
./build.sh
identity=${SIGN_IDENTITY:-}
notarize=false
[[ -n "$identity" && -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]] && notarize=true
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Ratio.app/Contents/Info.plist)
rm -rf dist && mkdir -p dist

# Submit a file to Apple's notary service and fail with its log unless it is accepted.
submit() {
  local result id
  result=$(xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait --output-format json)
  print -r -- "$result"
  id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$result")
  if [[ $(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$result") != Accepted ]]; then
    xcrun notarytool log "$id" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
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
