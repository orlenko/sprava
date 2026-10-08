# Working on Sprava

Read this first; then `docs/code-structure.md` for which target owns what.

## The repository is public

- No personal data in code, tests, docs or commit messages: no real names, addresses, account numbers,
  legal or tax facts, or contents of real binders. Every example is invented.
- The pre-commit hook scans the staged diff for private tokens, read from a list kept outside the repository
  (`~/.config/sprava/private-tokens`). Without that list the scan is skipped; scan by hand then.
- Never read inside the author's live binders or run lifeproj commands that touch the real registry or spool
  (`new`, `equip`, `archive`, `restore`, `root`, `home`, `publish`, `drain`). `sprava dev` refuses registry
  folders for this reason.

## How a change is made

1. One feature or fix per PR, preferably under 1,000 changed lines. Moving files counts as a rename.
2. The change lives in one target (see `docs/code-structure.md` section 3). If it spreads across several
   domain targets, stop and add an interface instead.
3. Tests: `./scripts/test.sh` (Swift Testing; invented fixtures only). Every fix gets a regression test.
   There is no hosted CI; git hooks are the gate (install once per clone with `./scripts/install-hooks.sh`):
   pre-commit builds and scans the staged diff for private tokens, pre-push runs the whole suite. Never
   bypass them with `--no-verify`.
4. The gate before merge: the suite passes; Codex Bugbot's comments on the PR are answered (fixed, or
   dismissed with a reason) and their threads resolved; a local Codex review on the `gpt-6-astra` model
   passes. If Bugbot's quota is exhausted, the local review is the gate.
5. Commit messages say what changed and why, in plain words.

## Build facts

- macOS 27, Swift 6.4, Command Line Tools only. SwiftUI macros such as `@State` are unavailable; app state
  lives in `ObservableObject` models with `@Published`.
- `./scripts/build-app.sh` builds `build/Sprava.app` (ad-hoc signed). It refuses to run while the app is open.
- The design docs in `docs/` are the source of truth for behavior; `docs/decisions.md` is the decision log.
