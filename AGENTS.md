# Working on Sprava

Read this first; then `docs/code-structure.md` for which target owns what.

## The repository is public

- No personal data in code, tests, docs or commit messages: no real names, addresses, account numbers,
  legal or tax facts, or contents of real binders. Every example is invented.
- The pre-commit hook scans the staged content of every added or changed file, binary or not, and the names
  of added, renamed and copied files (a name that matches is never printed), for private tokens, read from a list kept outside the repository (`~/.config/sprava/private-tokens`). It names a match
  by file and line, never by its text, and a scan that fails (a list that exists but cannot be read, such as
  one behind a locked folder or a dangling symlink, or a malformed pattern) rejects the commit. Only when the
  list is certainly absent is the scan skipped; scan by hand then. The commit-msg hook scans the commit message
  with the same list and rules.
- Never read inside the author's live binders or run lifeproj commands that touch the real registry or spool
  (`new`, `equip`, `archive`, `restore`, `root`, `home`, `publish`, `drain`). `sprava dev` refuses registry
  folders for this reason.

## How a change is made

1. One feature or fix per PR, preferably under 1,000 changed lines. Moving files counts as a rename.
2. The change lives in one target (see `docs/code-structure.md` section 3). If it spreads across several
   domain targets, stop and add an interface instead.
3. Tests: `./scripts/test.sh` (Swift Testing; invented fixtures only), or `./scripts/test.sh --filter
   <Target>Tests` for one target. Every fix gets a regression test.
   There is no hosted CI; git hooks are the gate (install once per clone with `./scripts/install-hooks.sh`):
   pre-commit scans the staged files for private tokens and builds the staged snapshot (a copy of the index
   under the git directory, never the working tree), and rejects the commit if anything is staged while it
   runs; commit-msg scans the message; pre-push tests every pushed commit that is new to the remote, oldest
   first, so a broken commit is caught even when a later one reverts it: the test targets of the targets it
   changes and of every target that depends on them (`scripts/affected-tests.sh`), or the whole suite when it
   changes `Package.swift`, `Package.resolved`, `scripts/test.sh` or shared test support; the companion suite
   for `companion/`; the hook suite for the hooks. Each commit is tested in a detached worktree kept at `<git dir>/sprava-hooks/push-tree`
   with its own `.build`, never in the checkout itself. A push of N such commits
   runs the suite N times, except for trees that already passed: each pass is recorded by tree hash in
   `<git common dir>/sprava-hooks/passed-trees` and not run again. To test a stack once before pushing it, run
   `./scripts/git-hooks/test-tree.sh $(git rev-list --reverse origin/main..HEAD)`. Never bypass the hooks with
   `--no-verify`; a push that changes them also runs their own tests (`test-hooks.sh`, `test-pr-check.sh`, `test-gate.sh`).
4. The gate before merge, with a review budget so a PR converges:
   - a local Codex review on the `gpt-6-astra` model passes (no MUST-FIX finding);
   - the cloud review gets one round. Findings in the classes of "Review guidelines" below are fixed; every
     other finding is answered with a link to an issue that records it, and its thread resolved. A further
     round only when a fix changed behavior;
   - `./scripts/merge-pr.sh <number>` runs the whole suite once on the PR's tip, refuses a tip that does not
     contain the current main (so the tree tested is the tree merged), then merges.
5. Commit messages say what changed and why, in plain words.

## Tools (`scripts/dev/`, for Claude, Codex and the author alike)

- `status.sh`: every open PR, its base, the cloud review's state, unresolved threads, whether it holds main.
- `open-pr.sh [<branch> [<base>]]`: opens a PR from its commits, with the shape line of `scripts/pr-check.sh`.
- `review.sh [<base>] [--claude]`: the local review of step 4, against "Review guidelines" below.
- `threads.sh list|reply|file`: reads a PR's review threads; answers and resolves one; or records a finding that
  does not block in a new issue, answers with its link and resolves it.
- `../merge-pr.sh <number>`: the last step of the gate.
- `prune-worktrees.sh [--apply]`: removes worktrees under `.claude/worktrees` that hold nothing unmerged.

## Review guidelines

For every reviewer, human or model. Sprava has no users yet; it is built for the MVP (`docs/mvp.md`).
Report a finding only when it can cause, in ordinary use or from an untrusted input (files in a binder's
`intake/`, capture events, the hub's outbox, MCP requests, anything from the companion relay):

- loss or corruption of a binder, its documents or its backups;
- a privacy leak: more than a binder's disclosure reaching the hub, anything outside a brain's scope
  reaching a brain, titles or content in logs, notifications or the heartbeat, anything the relay can read;
- a security hole reachable from an untrusted input: a path escape, reading credential files, a sandbox
  bypass, code execution;
- a crash or hang from an untrusted input or ordinary use;
- a silent failure that loses something the person wrote or approved;
- a dependency on a higher layer (`docs/code-structure.md`).

Do not report:

- races that need another program running as the same user (a link swapped in, a rename or a write between
  Sprava's check and its use, a file grown or replaced under it). The threat model (`docs/architecture.md`
  section 1) does not defend against them; they are collected in issue #227;
- missing migrations or backward compatibility for Sprava's own state in the support folder: there is no
  installed base (decisions.md A14). Binders do keep compatibility (binder-v0, lifeproj);
- wording in a doc that differs from the code, unless the code breaks a rule the doc states;
- style, naming, refactoring, or more tests for behavior already tested;
- a point already answered in a resolved thread of the same PR.

## Build facts

- macOS 27, Swift 6.4, Command Line Tools only. SwiftUI macros such as `@State` are unavailable; app state
  lives in `ObservableObject` models with `@Published`.
- `./scripts/build-app.sh` builds `build/Sprava.app` (ad-hoc signed). It refuses to run while the app is open.
- The design docs in `docs/` are the source of truth for behavior; `docs/decisions.md` is the decision log.
