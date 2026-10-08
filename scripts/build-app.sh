#!/bin/sh
# Build build/Sprava.app (ad-hoc signed, not launched). Pass SwiftPM options through, e.g. -c release.
set -eu
cd "$(dirname "$0")/.."

bundle="$PWD/build/Sprava.app"
if pgrep -f "$bundle/Contents/MacOS/SpravaApp" >/dev/null 2>&1; then
    echo "Sprava is running from build/Sprava.app. Quit it first, then rebuild." >&2
    exit 1
fi
if pgrep -f "$bundle/Contents/MacOS/sprava-runtime" >/dev/null 2>&1; then
    echo "Sprava's runtime is running from build/Sprava.app. Turn background work off in the app first." >&2
    exit 1
fi
plutil -lint Resources/App-Info.plist
swift build --product SpravaApp "$@"
swift build --product sprava "$@"
swift build --product sprava-runtime "$@"
swift build --product sprava-mcp "$@"
swift build --product sprava-extract "$@"
plutil -lint Resources/LaunchAgents/*.plist
bin_dir=$(swift build --show-bin-path "$@")

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Library/LaunchAgents"
cp Resources/LaunchAgents/*.plist "$bundle/Contents/Library/LaunchAgents/"
cp Resources/App-Info.plist "$bundle/Contents/Info.plist"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cp "$bin_dir/SpravaApp" "$bundle/Contents/MacOS/SpravaApp"
cp "$bin_dir/sprava" "$bundle/Contents/MacOS/sprava"
cp "$bin_dir/sprava-runtime" "$bundle/Contents/MacOS/sprava-runtime"
cp "$bin_dir/sprava-mcp" "$bundle/Contents/MacOS/sprava-mcp"
cp "$bin_dir/sprava-extract" "$bundle/Contents/MacOS/sprava-extract"
# restic, the backup engine (docs/backup.md section 10): a pinned release, signed with the app.
restic_bin="${SPRAVA_RESTIC:-$(command -v restic || true)}"
if [ -z "$restic_bin" ]; then
    echo "restic not found: install it (brew install restic) or set SPRAVA_RESTIC to its path" >&2
    exit 1
fi
cp "$(realpath "$restic_bin")" "$bundle/Contents/MacOS/restic"
restic_license="$(dirname "$(realpath "$restic_bin")")/../LICENSE"
[ -f "$restic_license" ] && cp "$restic_license" "$bundle/Contents/Resources/restic-LICENSE.txt"
codesign --force --sign - --identifier ca.orlenko.sprava.restic "$bundle/Contents/MacOS/restic"
codesign --force --sign - --identifier ca.orlenko.sprava.mcp "$bundle/Contents/MacOS/sprava-mcp"
codesign --force --sign - --identifier ca.orlenko.sprava.extract --entitlements Resources/sprava-extract.entitlements \
    "$bundle/Contents/MacOS/sprava-extract"
codesign --force --sign - --identifier ca.orlenko.sprava.runtime "$bundle/Contents/MacOS/sprava-runtime"
codesign --force --sign - --identifier ca.orlenko.sprava.cli "$bundle/Contents/MacOS/sprava"
codesign --force --sign - --identifier ca.orlenko.sprava "$bundle"
codesign --verify "$bundle"
echo "Built $bundle (not launched)"
