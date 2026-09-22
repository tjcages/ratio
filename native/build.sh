#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p Ratio.app/Contents/MacOS Ratio.app/Contents/Frameworks Ratio.app/Contents/Resources
cp vendor/Sparkle/LICENSE Ratio.app/Contents/Resources/Sparkle-LICENSE.txt
ditto vendor/Sparkle/Sparkle.framework Ratio.app/Contents/Frameworks/Sparkle.framework
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/ratio-universal.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
for architecture in arm64 x86_64; do
 xcrun swiftc -target "$architecture-apple-macos12.0" -module-cache-path "${TMPDIR:-/tmp}/ratio-swift-cache" Sources/main.swift -o "$build_dir/Ratio-$architecture" -framework AppKit -framework CoreGraphics -F vendor/Sparkle -framework Sparkle -framework ServiceManagement -Xlinker -rpath -Xlinker @executable_path/../Frameworks
done
lipo -create "$build_dir/Ratio-arm64" "$build_dir/Ratio-x86_64" -output Ratio.app/Contents/MacOS/Ratio

# Verify both executable slices retain the advertised deployment target.
python3 - <<'CHECK'
import subprocess,re
binary='Ratio.app/Contents/MacOS/Ratio'
assert set(subprocess.check_output(['lipo','-archs',binary],text=True).split()) == {'arm64','x86_64'}
assert re.findall(r'minos (\S+)',subprocess.check_output(['xcrun','vtool','-show-build',binary],text=True)) == ['12.0','12.0']
CHECK
codesign --force --deep --sign - Ratio.app
Ratio.app/Contents/MacOS/Ratio --self-test
