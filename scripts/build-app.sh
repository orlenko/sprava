#!/bin/sh
# Build build/Sprava.app (ad-hoc signed, not launched). Pass SwiftPM options through, e.g. -c release.
set -eu
cd "$(dirname "$0")/.."

bundle="$PWD/build/Sprava.app"
if pgrep -f "$bundle/Contents/MacOS/SpravaApp" >/dev/null 2>&1; then
    echo "Sprava is running from build/Sprava.app. Quit it first, then rebuild." >&2
    exit 1
fi
plutil -lint Resources/App-Info.plist
swift build --product SpravaApp "$@"
swift build --product sprava "$@"
bin_dir=$(swift build --show-bin-path "$@")

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Resources/App-Info.plist "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cp "$bin_dir/SpravaApp" "$bundle/Contents/MacOS/SpravaApp"
cp "$bin_dir/sprava" "$bundle/Contents/MacOS/sprava"
codesign --force --sign - --identifier ca.orlenko.sprava.cli "$bundle/Contents/MacOS/sprava"
codesign --force --sign - --identifier ca.orlenko.sprava "$bundle"
codesign --verify "$bundle"
echo "Built $bundle (not launched)"
