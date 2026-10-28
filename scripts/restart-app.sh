#!/bin/sh
# Build, install and reopen Sprava. SwiftPM options (e.g. -c release) pass through.
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd -P)
install_dir=${SPRAVA_INSTALL_DIR:-/Applications}
mkdir -p "$install_dir"
install_dir=$(cd "$install_dir" && pwd -P)
app="$install_dir/Sprava.app"
if [ -L "$app" ] || { [ -e "$app" ] && [ ! -d "$app" ]; }; then
    echo "restart-app: $app must be an app folder, not a link or file." >&2
    exit 1
fi

# This checkout's own build, the one copy besides the installed app whose background work may be handed over: a
# person who ran build/Sprava.app moves to the installed app. Only a genuine bundle qualifies: a real folder (no link
# at build/ or the app), whose signature verifies, with Sprava's bundle identifier and a regular runtime executable.
build_app="$repo/build/Sprava.app"
genuine_build() {
    [ -d "$repo/build" ] && [ ! -L "$repo/build" ] && [ -d "$build_app" ] && [ ! -L "$build_app" ] || return 1
    [ -f "$build_app/Contents/MacOS/sprava-runtime" ] && [ ! -L "$build_app/Contents/MacOS/sprava-runtime" ] || return 1
    [ -f "$build_app/Contents/Info.plist" ] && [ ! -L "$build_app/Contents/Info.plist" ] || return 1
    [ "$(plutil -extract CFBundleIdentifier raw -o - "$build_app/Contents/Info.plist" 2>/dev/null)" = ca.orlenko.sprava ] || return 1
    codesign --verify --deep --strict "$build_app" >/dev/null 2>&1
}

domain="gui/$(id -u)"
jobs=""
for label in ca.orlenko.sprava.runtime ca.orlenko.sprava.watch; do
    if job=$(launchctl print "$domain/$label" 2>/dev/null); then
        # An SMAppService job keeps its registered bundle path. Replacing another
        # copy would leave the old runtime serving the new app. Older macOS prints
        # that path as "program = …"; macOS 27 prints only "program identifier =
        # Contents/MacOS/sprava-runtime", so a running job is placed by its
        # process's executable, and a job that is not running is left for the app
        # to start (which copy it would start is not shown).
        program=$(printf '%s\n' "$job" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)
        if [ -z "$program" ]; then
            pid=$(printf '%s\n' "$job" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1)
            [ -n "$pid" ] || continue
            program=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
        fi
        if [ "$program" != "$app/Contents/MacOS/sprava-runtime" ]; then
            if [ "$program" != "$build_app/Contents/MacOS/sprava-runtime" ]; then
                echo "restart-app: background work belongs to another Sprava copy ($program). Remove that copy's background item in System Settings › General › Login Items, then run this script again." >&2
                exit 1
            fi
            if ! genuine_build; then
                echo "restart-app: background work runs from $build_app, which is not a genuine Sprava build (a link, a changed signature or another bundle identifier); it was left as it is." >&2
                exit 1
            fi
        fi
        jobs="$jobs $label"
    fi
done

# Stage on the destination volume: the running app and runtime retain their
# old executable files until the complete, signed bundle is ready to install.
stage=$(mktemp -d "$install_dir/.sprava-update.XXXXXX")
trap 'rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SPRAVA_APP_BUNDLE="$stage/Sprava.app" "$repo/scripts/build-app.sh" "$@"

# Older builds keep Inbox drafts only in memory. Let the person save them and
# finish pending saves before requesting Quit; never force-kill the UI.
if pgrep -x SpravaApp >/dev/null 2>&1; then
    echo "Quitting Sprava…"
    osascript <<'APPLESCRIPT'
if application id "ca.orlenko.sprava" is running then
    display dialog "Save any unfinished notes in Sprava and wait for saves to finish before continuing. Choose Cancel to leave Sprava running." with title "Update Sprava" buttons {"Cancel", "Quit and Update"} default button "Cancel" cancel button "Cancel"
    tell application id "ca.orlenko.sprava" to quit
end if
APPLESCRIPT
fi
attempt=0
while pgrep -x SpravaApp >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
        echo "restart-app: Sprava has not quit. Finish any open dialog and run this script again; the installed app was left as it was." >&2
        exit 1
    fi
    sleep 1
done

if [ -d "$app" ]; then
    mv "$app" "$stage/previous.app"
fi
if ! mv "$stage/Sprava.app" "$app"; then
    if [ -d "$stage/previous.app" ]; then
        mv "$stage/previous.app" "$app"
        open "$app"
    fi
    exit 1
fi

# The replacement app renews its SMAppService records before starting background
# work. A kickstart here would use the previous ad-hoc bundle's launch constraints.
# Only the already loaded jobs verified above request this update handoff.
if [ -n "$jobs" ]; then
    open "$app" --args --refresh-background-registration
else
    open "$app"
fi
echo "Installed and opened $app. Check Health for background-work status."
