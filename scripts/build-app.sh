#!/bin/sh
# Build build/Sprava.app (signed with the hardened runtime, not launched). Pass SwiftPM options through, e.g. -c release.
# SPRAVA_APP_BUNDLE selects a separate staging bundle for restart-app.sh. Needs restic and, for scripts/build-llm.sh, cmake.
# The app and every helper are signed with one Apple-issued identity (docs/manual-checks.md, "Signing"): macOS keys
# its record of the background jobs to the signer, and an ad-hoc signature changes with every build, so an updated
# ad-hoc build is refused at launch ("Launch Constraint Violation"). SPRAVA_SIGN_IDENTITY names the identity (its
# SHA-1 or its name, as `security find-identity -v -p codesigning` lists it); unset, the one Developer ID Application
# or Apple Development identity in the keychain is used. SPRAVA_SIGN_IDENTITY=- signs ad-hoc, for development only.
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
# The identity, chosen before anything is built.
identity=${SPRAVA_SIGN_IDENTITY:-}
if [ -z "$identity" ]; then
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -E '^ *[0-9]+\) [0-9A-F]{40} "(Developer ID Application|Apple Development): ' | awk '{print $2}' | sort -u)
    count=$(printf '%s' "$found" | grep -c . || true)
    if [ "$count" -eq 0 ]; then
        echo "build-app: no Developer ID Application or Apple Development signing identity in the keychain. Add one (Xcode › Settings › Accounts), name one with SPRAVA_SIGN_IDENTITY=<SHA-1 or name>, or set SPRAVA_SIGN_IDENTITY=- for an ad-hoc development build." >&2
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "build-app: $count signing identities could sign Sprava; name one with SPRAVA_SIGN_IDENTITY=<SHA-1> (security find-identity -v -p codesigning lists them)." >&2
        exit 1
    fi
    identity=$found
fi
if [ "$identity" = - ]; then
    echo "build-app: signing ad-hoc (SPRAVA_SIGN_IDENTITY=-), for development only: macOS does not keep an ad-hoc build's background work across updates." >&2
fi
# No secure timestamp: the build stays offline, and nothing here is notarized, which is what needs one.
sign() { codesign --force --sign "$identity" --timestamp=none --options runtime "$@"; }
team_of() { codesign -d --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }

plutil -lint Resources/App-Info.plist
plutil -lint Resources/LaunchAgents/*.plist
plutil -lint Resources/sprava-extract.entitlements
plutil -lint Resources/sprava-llm-Info.plist
plutil -lint Resources/sprava-llm.entitlements
# The local model helper (docs/conversation.md 11.2): a pinned llama.cpp built into build/llm, kept while its pin holds.
./scripts/build-llm.sh
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
# The app icon: Assets.car (CFBundleIconName, with its dark and tinted looks) and AppIcon.icns (CFBundleIconFile),
# both committed by scripts/make-app-icon.sh, so the build needs no Xcode.
cp Resources/AppIcon/Assets.car "$work/Contents/Resources/Assets.car"
cp Resources/AppIcon/AppIcon.icns "$work/Contents/Resources/AppIcon.icns"
cp "$bin_dir/SpravaApp" "$work/Contents/MacOS/SpravaApp"
cp "$bin_dir/sprava" "$work/Contents/MacOS/sprava"
cp "$bin_dir/sprava-runtime" "$work/Contents/MacOS/sprava-runtime"
cp "$bin_dir/sprava-mcp" "$work/Contents/MacOS/sprava-mcp"
cp "$bin_dir/sprava-extract" "$work/Contents/MacOS/sprava-extract"
cp build/llm/sprava-llm "$work/Contents/MacOS/sprava-llm"
cp build/llm/LICENSES.txt "$work/Contents/Resources/llama.cpp-LICENSES.txt"
cp "$(realpath "$restic_bin")" "$work/Contents/MacOS/restic"
restic_license="$(dirname "$(realpath "$restic_bin")")/../LICENSE"
if [ -f "$restic_license" ]; then cp "$restic_license" "$work/Contents/Resources/restic-LICENSE.txt"; fi
# Nested code first, the bundle last: signing the bundle seals the helpers and the LaunchAgents plists as they are.
sign --identifier ca.orlenko.sprava.restic "$work/Contents/MacOS/restic"
sign --identifier ca.orlenko.sprava.mcp "$work/Contents/MacOS/sprava-mcp"
# The runtime refuses a helper that does not run sandboxed, so a helper signed without its entitlement stops the build.
# The identifier names the helper's sandbox container, where the model helper's socket lives.
sign_sandboxed() {
    if ! sign --identifier "$2" --entitlements "$3" "$work/Contents/MacOS/$1"; then
        echo "build-app: signing the helper $1 failed" >&2
        exit 1
    fi
    if ! codesign -d --entitlements - --xml "$work/Contents/MacOS/$1" 2>/dev/null | grep -q com.apple.security.app-sandbox; then
        echo "build-app: the helper $1 carries no sandbox entitlement after signing" >&2
        exit 1
    fi
}
sign_sandboxed sprava-extract ca.orlenko.sprava.extract Resources/sprava-extract.entitlements
sign_sandboxed sprava-llm ca.orlenko.sprava.llm Resources/sprava-llm.entitlements
sign --identifier ca.orlenko.sprava.runtime "$work/Contents/MacOS/sprava-runtime"
sign --identifier ca.orlenko.sprava.cli "$work/Contents/MacOS/sprava"
sign --identifier ca.orlenko.sprava "$work"
codesign --verify --deep --strict "$work"
# Every executable runs with the hardened runtime: no injected libraries, no DYLD_ variables, no unsigned code.
for exe in "$work"/Contents/MacOS/*; do
    if ! codesign -d --verbose=2 "$exe" 2>&1 | grep -q 'flags=.*runtime'; then
        echo "build-app: $(basename "$exe") is not signed with the hardened runtime" >&2
        exit 1
    fi
done
# One signer for the app and every helper: an Apple-issued identity names a team, the same on each; ad-hoc names none.
team=$(team_of "$work")
if [ "$identity" = - ]; then
    [ "$team" = "not set" ] || { echo "build-app: an ad-hoc build carries the team $team" >&2; exit 1; }
else
    if [ -z "$team" ] || [ "$team" = "not set" ]; then
        echo "build-app: the bundle carries no team after signing with $identity" >&2
        exit 1
    fi
    if ! codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$work"; then
        echo "build-app: the bundle's signature is not Apple-issued for the team $team" >&2
        exit 1
    fi
fi
for exe in "$work"/Contents/MacOS/*; do
    if [ "$(team_of "$exe")" != "$team" ]; then
        echo "build-app: $(basename "$exe") is not signed by the same team as the app" >&2
        exit 1
    fi
    if [ "$identity" != - ] && ! codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$exe"; then
        echo "build-app: $(basename "$exe")'s signature is not Apple-issued for the team $team" >&2
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
