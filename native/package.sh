#!/bin/zsh
# Build Ratio and package it for download as dist/Ratio.dmg and dist/Ratio.zip.
set -eu
cd "$(dirname "$0")"
./build.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Ratio.app/Contents/Info.plist)
rm -rf dist && mkdir -p dist
codesign --verify --deep --strict Ratio.app
ditto -c -k --keepParent Ratio.app dist/Ratio.zip
staging=$(mktemp -d "${TMPDIR:-/tmp}/ratio-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto Ratio.app "$staging/Ratio.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Ratio $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov dist/Ratio.dmg
hdiutil verify dist/Ratio.dmg
print "Packaged Ratio $version in native/dist"
