#!/bin/sh
# Build, install and reopen Sprava. SwiftPM options (e.g. -c release) pass through.
# Or install a bundle built and signed on another Mac, without building: --install <Sprava.app> --team <team id>
# (docs/manual-checks.md, "Signing"). The team is the person's to name; it is never read from the bundle.
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

prebuilt=""; team=""
if [ "${1:-}" = --install ]; then
    if [ $# -ne 4 ] || [ "$3" != --team ]; then
        echo "restart-app: usage: restart-app.sh --install <Sprava.app> --team <team id>" >&2
        exit 1
    fi
    prebuilt=$2; team=$4
    if ! printf '%s\n' "$team" | grep -Eqx '[A-Z0-9]{10}'; then
        echo "restart-app: $team is not a team id (ten capital letters and digits)." >&2
        exit 1
    fi
    if [ -L "$prebuilt" ] || [ ! -d "$prebuilt" ]; then
        echo "restart-app: $prebuilt must be an app folder, not a link or file." >&2
        exit 1
    fi
    prebuilt=$(cd "$prebuilt" && pwd -P)
    if [ "$prebuilt" = "$app" ]; then
        echo "restart-app: $prebuilt is the installed app itself." >&2
        exit 1
    fi
fi

team_of() { codesign -d --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
signer() { case "$1" in "not set") echo "ad-hoc" ;; "") echo "a signature that cannot be read" ;; *) echo "the team $1" ;; esac; }
# A bundle signed as the person expects, checked as build-app.sh checks its own: sealed and whole, Sprava's
# identifier, every executable Sprava needs present as a plain file, each Apple-issued for the team and signed with
# the hardened runtime, and the two helpers the runtime starts sandboxed carrying their sandbox entitlement.
required_executables="SpravaApp sprava sprava-runtime sprava-mcp sprava-extract sprava-llm restic"
verify_signed() {   # <bundle> <team>
    if [ "$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null)" != ca.orlenko.sprava ]; then
        echo "restart-app: $1 is not Sprava (another bundle identifier)." >&2; return 1
    fi
    for name in $required_executables; do
        if [ -L "$1/Contents/MacOS/$name" ] || [ ! -f "$1/Contents/MacOS/$name" ]; then
            echo "restart-app: $1 has no $name (an incomplete build)." >&2; return 1
        fi
    done
    if ! codesign --verify --deep --strict "$1"; then
        echo "restart-app: $1 does not pass signature verification." >&2; return 1
    fi
    for exe in "$1" "$1"/Contents/MacOS/*; do
        if [ "$(team_of "$exe")" != "$2" ] ||
            ! codesign --verify -R="anchor apple generic and certificate leaf[subject.OU] = \"$2\"" "$exe"; then
            echo "restart-app: $(basename "$exe") in $1 is not signed by an Apple-issued identity of the team $2." >&2; return 1
        fi
        if ! codesign -d --verbose=2 "$exe" 2>&1 | grep -q 'flags=.*runtime'; then
            echo "restart-app: $(basename "$exe") in $1 is not signed with the hardened runtime." >&2; return 1
        fi
    done
    for name in sprava-extract sprava-llm; do
        if ! codesign -d --entitlements - --xml "$1/Contents/MacOS/$name" 2>/dev/null |
            plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - - 2>/dev/null | grep -qx true; then
            echo "restart-app: $name in $1 is not signed to run sandboxed." >&2; return 1
        fi
    done
}

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
if [ -n "$prebuilt" ]; then
    # Checked where it is, then copied whole onto the install volume and checked again there.
    verify_signed "$prebuilt" "$team"
    ditto "$prebuilt" "$stage/Sprava.app"
    verify_signed "$stage/Sprava.app" "$team"
    new_team=$team
else
    SPRAVA_APP_BUNDLE="$stage/Sprava.app" "$repo/scripts/build-app.sh" "$@"
    new_team=$(team_of "$stage/Sprava.app")
fi
# macOS keeps its record of the background jobs, launch constraint included, under the old signer, and an ad-hoc
# signature changes with every build: only an Apple-issued, team-signed app is installed. Over an ad-hoc one that is
# the intended move to stable signing; over a team-signed one, the team must stay the same. A move to ad-hoc, or to
# another team, is refused, with no way around it here.
if [ -z "$new_team" ] || [ "$new_team" = "not set" ]; then
    echo "restart-app: the new Sprava is not signed by a team (ad-hoc builds, SPRAVA_SIGN_IDENTITY=-, are for development only); the installed app was left as it was." >&2
    exit 1
fi
if [ -d "$app" ]; then
    old_team=$(team_of "$app")
    if [ -n "$old_team" ] && [ "$old_team" != "not set" ] && [ "$old_team" != "$new_team" ]; then
        echo "restart-app: the installed Sprava is signed by $(signer "$old_team") and the new one by $(signer "$new_team"). Sprava does not move between teams; the installed app was left as it was." >&2
        exit 1
    fi
fi

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
