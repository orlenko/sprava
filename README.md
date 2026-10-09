# sprava

Life projects organized, one self-maintaining folder at a time.

Sprava keeps one binder per episode of a person's life and keeps it current, locally, on a Mac.
The plan is in [docs/](docs/): start with [docs/kickoff-summary.md](docs/kickoff-summary.md), then
[docs/mvp.md](docs/mvp.md). Decisions are logged in [docs/decisions.md](docs/decisions.md).

## Status

The MVP increments of docs/mvp.md section 5 are built. They reach `main` as a stack of pull requests: the
design docs and git hooks first, then the code, one layer at a time. Until the whole stack is merged, `main`
may hold only the docs, and the commands under "Build and test" need the code layers. The increments:

1. The Shelf and each binder's Now page, read-only.
2. The runtime: a LaunchAgent with a heartbeat, watchdog, breakers, the deadline sentinel and the daily
   summary, plus the outside watcher (docs/manual-checks.md lists the checks that need a person).
3. Adoption in place, the op log with the transaction guard, review cards, undo, the hub lane, the
   DASHBOARD.md switch, the manual addendum and the doctor.
4. Claude Code over MCP, proposing only, and the Brains screen.
5. The capture inbox: notes, however their text was produced, become code-built cards within a minute;
   files in a binder's `intake/` become filing cards.
6. The clerk: Apple's on-device model splits, dates and files notes, checked by code.
7. Reading intake: every file in a binder's `intake/`, and every message a mail monitor writes to
   `intake/mail/`, is read in a sandboxed helper (OCR included), then by the clerk; documents worth a careful
   reading wait for a connected brain (docs/adaptation-layer.md).
8. Templates for new binders (blank, tax year), and encrypted backup with offload (docs/backup.md).

Nothing touches a live binder until you adopt it in the app.

## Build and test

Requires macOS 27 and Swift 6.4 (Command Line Tools are enough).

```sh
./scripts/test.sh              # Swift Testing suites, on invented fixtures only
swift build
$(swift build --show-bin-path)/sprava shelf
$(swift build --show-bin-path)/sprava now ~/binders/kitchen-reno
./scripts/build-app.sh         # build/Sprava.app, ad-hoc signed, not launched
```

Developer commands (invented data only; `sprava dev` refuses any folder in lifeproj's registry):

```sh
sprava note "Call the notary by Friday"      # a typed note, as the app writes one
sprava clerk "Pay the plumber 625 dollars next week" --binder "rental=Rental on Elm Street"
./scripts/sign-dev-helper.sh                 # after each swift build: sign the file reader with its sandbox
sprava read-document <invented-file>         # read a file as intake would (needs the signed reader)
sprava clerk-gate Tests/ClerkGate/fixtures.json   # the clerk's release gate
sprava dashboard <folder>                    # the DASHBOARD.md Sprava would write
sprava measures --days 30                    # the shadow run's measures (mvp.md 1.2)
```

The shelf lists binders made with New Binder and folders added with `sprava shelf add <folder>` or
File › Add Folder… in the app. Older binders come in one at a time that way. lifeproj's registry
(`$CMIRROR_CONFIG` or `~/.config/cmirror/config.toml`) is listed too, read-only, only when
`"showRegistry": true` is set in Sprava's `shelf.json`.
Sprava's own state lives in `~/Library/Application Support/Sprava` (`$SPRAVA_SUPPORT_DIR` overrides it).
