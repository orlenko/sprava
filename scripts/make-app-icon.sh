#!/bin/sh
# Rebuild the app icon from the drawn sketches in Resources/AppIcon and commit the result; build-app.sh only copies
# AppIcon.icns and Assets.car, so building the app never needs Xcode.
# - AppIcon.icns, from icon-light.png: the icon macOS shows when it does not read the asset catalog. Needs swift
#   and iconutil (Command Line Tools).
# - Assets.car, from AppIcon.icon (an Icon Composer file: a cream fill, navy when dark, under the folder keyed out
#   of icon-dark.png): the icon with its dark, tinted and clear looks. Needs Xcode's actool; without Xcode it is
#   left as it is.
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d "${TMPDIR:-/tmp}/sprava-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swift scripts/make-app-icon.swift iconset Resources/AppIcon/icon-light.png "$work/AppIcon.iconset"
iconutil --convert icns --output "$work/AppIcon.icns" "$work/AppIcon.iconset"
mv "$work/AppIcon.icns" Resources/AppIcon/AppIcon.icns
echo "Wrote Resources/AppIcon/AppIcon.icns"

if ! actool=$(xcrun --find actool 2>/dev/null); then
    echo "make-app-icon: actool not found (it comes with Xcode); Resources/AppIcon/Assets.car left as it is" >&2
    exit 0
fi
swift scripts/make-app-icon.swift folder Resources/AppIcon/icon-dark.png Resources/AppIcon/AppIcon.icon/Assets/folder.png
mkdir "$work/compiled"
"$actool" Resources/AppIcon/AppIcon.icon --compile "$work/compiled" --platform macosx \
    --minimum-deployment-target 27.0 --app-icon AppIcon --output-partial-info-plist "$work/partial.plist" \
    --errors --warnings --output-format human-readable-text
mv "$work/compiled/Assets.car" Resources/AppIcon/Assets.car
echo "Wrote Resources/AppIcon/Assets.car"
