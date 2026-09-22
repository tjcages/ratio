#!/bin/zsh
# Build a signed, notarized Ratio and publish it as GitHub release v<version>.
# Bump CFBundleShortVersionString in Ratio.app/Contents/Info.plist and update RELEASE-NOTES.md first.
set -eu
cd "$(dirname "$0")"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Ratio.app/Contents/Info.plist)
tag="v$version"
repo=$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  print -u2 "$tag is already released. Bump the version in Ratio.app/Contents/Info.plist first."; exit 1
fi
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Commit or stash your changes first, so the release matches the pushed source.'; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { print -u2 'Check out the latest main (git checkout main && git pull) first.'; exit 1; }

REQUIRE_NOTARIZED=1 ./package.sh

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release create "$tag" dist/Ratio.dmg dist/Ratio.zip --title "Ratio $version" --target "$(git rev-parse HEAD)" --latest --notes-file ../RELEASE-NOTES.md --repo "$repo"
else
  # Without the GitHub CLI, finish in the browser: the page opens with the tag filled in.
  open "https://github.com/$repo/releases/new?tag=$tag&title=Ratio%20$version"
  open -R dist/Ratio.dmg
  print "Drag Ratio.dmg and Ratio.zip from the Finder window onto the release page, paste RELEASE-NOTES.md, and publish."
fi
