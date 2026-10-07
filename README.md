# sprava

Life projects organized, one self-maintaining folder at a time.

Sprava keeps one binder (a *teka*) per episode of a person's life and keeps it current, locally, on a Mac.
The plan is in [docs/](docs/): start with [docs/kickoff-summary.md](docs/kickoff-summary.md), then
[docs/mvp.md](docs/mvp.md). Decisions are logged in [docs/decisions.md](docs/decisions.md).

## Status

MVP increment 1 (read-only Shelf and Now pages; docs/mvp.md section 5) is in progress. Nothing Sprava
does yet writes inside a binder.

## Build and test

Requires macOS 27 and Swift 6.4 (Command Line Tools are enough).

```sh
./scripts/test.sh              # Swift Testing suites, on invented fixtures only
swift build
$(swift build --show-bin-path)/sprava shelf
$(swift build --show-bin-path)/sprava now ~/binders/kitchen-reno
./scripts/build-app.sh         # build/Sprava.app, ad-hoc signed, not launched
```

The shelf lists the live tekas in lifeproj's registry (`$CMIRROR_CONFIG` or `~/.config/cmirror/config.toml`),
read-only, plus folders added with `sprava shelf add <folder>` or File › Add Folder… in the app.
Sprava's own state lives in `~/Library/Application Support/Sprava` (`$SPRAVA_SUPPORT_DIR` overrides it).
