#!/bin/sh
# Ad-hoc sign the `swift build` extraction helper with its sandbox entitlement, so a development run of the CLI or
# the runtime can read intake files: the helper is refused unless it runs sandboxed. Run it after every
# `swift build` that rebuilt sprava-extract. Pass SwiftPM options through, e.g. -c release.
set -eu
cd "$(dirname "$0")/.."

entitlements=Resources/sprava-extract.entitlements
helper="$(swift build --show-bin-path "$@")/sprava-extract"
if [ ! -x "$helper" ]; then
    echo "sign-dev-helper: $helper is missing; run swift build --product sprava-extract $* first" >&2
    exit 1
fi
plutil -lint "$entitlements" >/dev/null
if ! codesign --force --sign - --identifier ca.orlenko.sprava.extract --entitlements "$entitlements" "$helper"; then
    echo "sign-dev-helper: signing $helper failed" >&2
    exit 1
fi
if ! codesign -d --entitlements - --xml "$helper" 2>/dev/null | grep -q com.apple.security.app-sandbox; then
    echo "sign-dev-helper: $helper carries no sandbox entitlement after signing" >&2
    exit 1
fi
echo "Signed $helper with its sandbox entitlement"
