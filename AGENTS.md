# Working on Sprava

Read this first; then `docs/code-structure.md` for which target owns what.

## The repository is public

- No personal data in code, tests, docs or commit messages: no real names, addresses, account numbers,
  legal or tax facts, or contents of real binders. Every example is invented.
- The pre-commit hook scans the staged content of every added or changed file, binary or not, for private
  tokens, read from a list kept outside the repository (`~/.config/sprava/private-tokens`). It names a match
  by file and line, never by its text, and a scan that fails (a list that exists but cannot be read, such as
  one behind a locked folder or a dangling symlink, or a malformed pattern) rejects the commit. Only when the
  list is certainly absent is the scan skipped; scan by hand then.
- Never read inside the author's live binders or run lifeproj commands that touch the real registry or spool
  (`new`, `equip`, `archive`, `restore`, `root`, `home`, `publish`, `drain`). `sprava dev` refuses registry
  folders for this reason.

## How a change is made

1. One feature or fix per PR, preferably under 1,000 changed lines. Moving files counts as a rename.
2. The change lives in one target (see `docs/code-structure.md` section 3). If it spreads across several
   domain targets, stop and add an interface instead.
3. Tests: `./scripts/test.sh` (Swift Testing; invented fixtures only). Every fix gets a regression test.
   There is no hosted CI; git hooks are the gate (install once per clone with `./scripts/install-hooks.sh`):
   pre-commit scans the staged files for private tokens and builds the staged snapshot (a copy of the index
   under the git directory, never the working tree), and rejects the commit if anything is staged while it
   runs; pre-push runs the suite on every pushed commit that is new to the remote and changes Swift code,
   `Resources/`, `Package.swift`, `Package.resolved` or `companion/`, oldest first, so a broken commit is caught even when a
   later one reverts it. Each commit is tested in a detached worktree kept at `<git dir>/sprava-hooks/push-tree`
   with its own `.build`, never in the checkout itself. A push of N such commits
   runs the suite N times, except for trees that already passed: each pass is recorded by tree hash in
   `<git common dir>/sprava-hooks/passed-trees` and not run again. To test a stack once before pushing it, run
   `./scripts/git-hooks/test-tree.sh $(git rev-list --reverse origin/main..HEAD)`. Never bypass the hooks with
   `--no-verify`; after changing them, run `./scripts/git-hooks/test-hooks.sh`.
4. The gate before merge: the suite passes; Codex Bugbot's comments on the PR are answered (fixed, or
   dismissed with a reason) and their threads resolved; a local Codex review on the `gpt-6-astra` model
   passes. If Bugbot's quota is exhausted, the local review is the gate.
5. Commit messages say what changed and why, in plain words.

## Build facts

- macOS 27, Swift 6.4, Command Line Tools only. SwiftUI macros such as `@State` are unavailable; app state
  lives in `ObservableObject` models with `@Published`.
- `./scripts/build-app.sh` builds `build/Sprava.app` (ad-hoc signed). It refuses to run while the app is open.
- The design docs in `docs/` are the source of truth for behavior; `docs/decisions.md` is the decision log.
