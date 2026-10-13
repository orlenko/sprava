#!/bin/sh
# Build build/Sprava.app (ad-hoc signed with the hardened runtime, not launched). Pass SwiftPM options through, e.g. -c release.
# SPRAVA_APP_BUNDLE selects a separate staging bundle for restart-app.sh.
# The bundle is assembled and signed beside its destination and moved into place only once its signature verifies:
# a build that stops halfway leaves the previous bundle as it was, never a bundle whose resources are not sealed
# (SMAppService refuses to load a LaunchAgent plist from such a bundle: "Codesigning failure loading plist ... -67056").
set -eu
cd "$(dirname "$0")/.."

bundle="${SPRAVA_APP_BUNDLE:-$PWD/build/Sprava.app}"
if pgrep -f "$bundle/Contents/MacOS/SpravaApp" >/dev/null 2>&1; then
    echo "Sprava is running from $bundle. Quit it first, then rebuild." >&2
    exit 1
fi
if pgrep -f "$bundle/Contents/MacOS/sprava-runtime" >/dev/null 2>&1; then
    echo "Sprava's runtime is running from $bundle. Turn background work off in the app first." >&2
    exit 1
fi
# restic, the backup engine (docs/backup.md section 10): a pinned release, signed with the app. Checked before anything
# is built or copied.
restic_bin="${SPRAVA_RESTIC:-$(command -v restic || true)}"
if [ -z "$restic_bin" ] || [ ! -x "$restic_bin" ]; then
    echo "restic not found: install it (brew install restic) or set SPRAVA_RESTIC to its path" >&2
    exit 1
fi
plutil -lint Resources/App-Info.plist
plutil -lint Resources/LaunchAgents/*.plist
plutil -lint Resources/sprava-extract.entitlements
swift build --product SpravaApp "$@"
swift build --product sprava "$@"
swift build --product sprava-runtime "$@"
swift build --product sprava-mcp "$@"
swift build --product sprava-extract "$@"
bin_dir=$(swift build --show-bin-path "$@")

mkdir -p "$(dirname "$bundle")"
work="$(dirname "$bundle")/.building-$(basename "$bundle")"
rm -rf "$work"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/Contents/MacOS" "$work/Contents/Resources" "$work/Contents/Library/LaunchAgents"
cp Resources/LaunchAgents/*.plist "$work/Contents/Library/LaunchAgents/"
cp Resources/App-Info.plist "$work/Contents/Info.plist"
cp LICENSE "$work/Contents/Resources/LICENSE.txt"
cp "$bin_dir/SpravaApp" "$work/Contents/MacOS/SpravaApp"
cp "$bin_dir/sprava" "$work/Contents/MacOS/sprava"
cp "$bin_dir/sprava-runtime" "$work/Contents/MacOS/sprava-runtime"
cp "$bin_dir/sprava-mcp" "$work/Contents/MacOS/sprava-mcp"
cp "$bin_dir/sprava-extract" "$work/Contents/MacOS/sprava-extract"
cp "$(realpath "$restic_bin")" "$work/Contents/MacOS/restic"
restic_license="$(dirname "$(realpath "$restic_bin")")/../LICENSE"
if [ -f "$restic_license" ]; then cp "$restic_license" "$work/Contents/Resources/restic-LICENSE.txt"; fi
# Nested code first, the bundle last: signing the bundle seals the helpers and the LaunchAgents plists as they are.
codesign --force --sign - --options runtime --identifier ca.orlenko.sprava.restic "$work/Contents/MacOS/restic"
codesign --force --sign - --options runtime --identifier ca.orlenko.sprava.mcp "$work/Contents/MacOS/sprava-mcp"
# The runtime refuses a helper that does not run sandboxed, so a helper signed without its entitlement stops the build.
if ! codesign --force --sign - --options runtime --identifier ca.orlenko.sprava.extract --entitlements Resources/sprava-extract.entitlements \
    "$work/Contents/MacOS/sprava-extract"; then
    echo "build-app: signing the extraction helper failed" >&2
    exit 1
fi
if ! codesign -d --entitlements - --xml "$work/Contents/MacOS/sprava-extract" 2>/dev/null | grep -q com.apple.security.app-sandbox; then
    echo "build-app: the extraction helper carries no sandbox entitlement after signing" >&2
    exit 1
fi
codesign --force --sign - --options runtime --identifier ca.orlenko.sprava.runtime "$work/Contents/MacOS/sprava-runtime"
codesign --force --sign - --options runtime --identifier ca.orlenko.sprava.cli "$work/Contents/MacOS/sprava"
codesign --force --sign - --options runtime --identifier ca.orlenko.sprava "$work"
codesign --verify --deep --strict "$work"
# Every executable runs with the hardened runtime: no injected libraries, no DYLD_ variables, no unsigned code.
for exe in "$work"/Contents/MacOS/*; do
    if ! codesign -d --verbose=2 "$exe" 2>&1 | grep -q 'flags=.*runtime'; then
        echo "build-app: $(basename "$exe") is not signed with the hardened runtime" >&2
        exit 1
    fi
done
# SMAppService loads each agent's plist only from the bundle's sealed resources.
for plist in Resources/LaunchAgents/*.plist; do
    name=$(basename "$plist")
    if ! grep -Fq "<key>Library/LaunchAgents/$name</key>" "$work/Contents/_CodeSignature/CodeResources" 2>/dev/null; then
        echo "build-app: the LaunchAgent plist $name is not sealed in the bundle's signature" >&2
        exit 1
    fi
done
rm -rf "$bundle"
mv "$work" "$bundle"
codesign --verify --deep --strict "$bundle"
echo "Built $bundle (not launched)"
