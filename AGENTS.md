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

1. One feature or fix per PR, preferably under 1,000 changed lines. Moving files counts as a rename. A screen
   with its model and tests may pass that with `SPRAVA_ALLOW_LARGE=1` when splitting it would leave no part
   that works alone; the PR says why. Split at a natural seam when there is one.
2. The change lives in one target (see `docs/code-structure.md` section 3). If it spreads across several
   domain targets, stop and add an interface instead.
3. Tests: `./scripts/test.sh` (Swift Testing; invented fixtures only), or `./scripts/test.sh --filter
   <Target>Tests` for one target. Every fix gets a regression test.
   There is no hosted CI; git hooks are the gate (install once per clone with `./scripts/install-hooks.sh`):
   pre-commit scans the staged files for private tokens and builds the staged snapshot (a copy of the index
   under the git directory, never the working tree), and rejects the commit if anything is staged while it
   runs; commit-msg scans the message; pre-push tests every pushed commit that is new to the remote, oldest
   first, in a detached worktree, never in the checkout: the test targets `scripts/affected-tests.sh` names, or
   the whole suite; the companion suite for `companion/`; the hook suite for the hooks (`scripts/git-hooks/suites.sh`).
   Each pass is recorded in `<git common dir>/sprava-hooks/passed-trees` and not run again; a Swift pass is
   keyed by the package's inputs, so a rebase onto a docs-only main keeps it. To test a stack once before
   pushing it, run `./scripts/git-hooks/test-tree.sh $(git rev-list --reverse origin/main..HEAD)`. Planned, not
   yet in force: pre-push tests only the tip of each PR in a stack. Never bypass the hooks with `--no-verify`;
   a push that changes them also runs their own tests (`test-hooks.sh`, `test-pr-check.sh`, `test-gate.sh`).
4. The gate before merge. The tier and the review rounds follow "Review and test process" below:
   - round 1 is the local review, `./scripts/dev/review.sh` (Codex on the `gpt-6-astra` model), plus the cloud
     Codex review of the PR in tier B. A finding in the classes of "Review guidelines" is a blocker (MUST-FIX).
     Any other finding is fixed, or answered in one line; in the cloud review with `threads.sh reply`, or with
     `threads.sh file` to record it in an issue;
   - after a fix to a blocker, `./scripts/dev/review.sh <reviewed commit>` reviews only the fix: at most 1 such
     round in tier C, 2 in tier B. When rounds keep finding new cases of one kind, change the design so the
     kind cannot occur (one safe reader for a file every caller uses; a feature off until it can be made safe)
     instead of patching each caller;
   - a conflict-free rebase onto main needs no new review. `./scripts/merge-pr.sh <number>` still refuses a tip
     that does not contain the current main (so the tree tested is the tree merged) or has unresolved review
     threads; it runs the whole suite once on the tip when the PR changes Swift inputs, unless the passed-trees
     cache shows those inputs already passed, then merges.
5. Commit messages say what changed and why, in plain words.

## Review and test process

The owner adopted the shared [review and test process v0.3](https://github.com/orlenko/software-quality/blob/main/docs/process.md)
for Sprava on 2026-11-13. It sets the tiers, review rounds, caps, stop rules and the record. This section is
Sprava's part. Sprava has no tier A.

- **Sensitive-path list.** A change to one of these files is tier B:
  - secrets, Keychain, signing, launchd: `Sources/SpravaKit/{LocalKeychainSecret,LegacyKeychainInteraction}.swift`,
    `Sources/Services/DeviceID.swift`, `Sources/Services/Claude/ClaudeSubscriptionSecrets.swift`,
    `Sources/SpravaApp/Health/{RuntimeKeeper,WatcherRepair,BundleSignature}.swift`, `Sources/sprava-runtime/**`,
    `Resources/LaunchAgents/**`, `Resources/{*.entitlements,App-Info.plist}`, `scripts/{build-app,build-llm,restart-app}.sh`;
  - writing, moving or deleting documents; backup and restore: `Sources/Backup/**`,
    `Sources/Services/Commands/BackupCommands.swift`, `Sources/BinderFormat/DocumentPaths.swift`,
    `Sources/SpravaKit/{SafeFile,AtomicFile,StateDirectory}.swift`, `Sources/SpravaApp/Binder/Drop/IntakeDropModel.swift`,
    `Sources/BinderStore/{OpApplier,TransactionGuard,Undo,TekaStore+*,TurnHistory*,Adoption,AdoptionStamp,DashboardKeeper,DocumentPaths+Writing,CompanionOperationTransaction,ProposalStore+BoundedReading}.swift`,
    `Sources/Capture/{BinderWrite,CaptureInbox+Carry,CaptureInbox+Handoff,CaptureInbox+Retraction,CaptureInbox+Unfiled}.swift`;
  - network and data leaving the Mac: `Sources/Capture/IMAP/**`, `Sources/Services/Jobs/DraftPlacing.swift`,
    `Sources/Services/XPCPeer.swift`, `Sources/sprava-mcp/**`, `Sources/Brains/{MCPSocket,MCPServer*,MCPTools}.swift`,
    `Sources/Companion/{CompanionKeychain,OwnerVault,PairingKeys,OwnerRelay,RelayStream,SealedObject,Wire,OwnerPublication,IndexPublication,OutcomesPublication,ViewProjection,OwnerPairingDelivery,BinderSharing,SelfRevocation}.swift`,
    `companion/relay/src/**`, `companion/web/src/{relay-client,pairing-*}.ts`;
  - agent sandbox: `Sources/Brains/{AgentContainment,AgentEgressProxy,AgentSessionAdmission,ClaudeReadLaunch,LLMHelper}.swift`,
    `Sources/Services/Claude/ClaudeNativeConversation.swift`, `Sources/AgentSandboxProbe/**`, `Sources/Extract/ExtractHelper.swift`.
- **Triggers**, also tier B: the change parses model output into actions or to-dos the person relies on; or it
  changes behavior across a restart, an update or a change of signing identity.
- **Round-1 question:** what deletes or loses a user file or a stored secret?
- **Reviewers:** tier C, the local review; tier B, the local review and the cloud review (step 4). When one is out
  of quota, use the other; `review.sh --claude` runs the local review through Claude instead of Codex.
- **Tests:** while working, `./scripts/test.sh --filter '<pattern>'` with the pattern that
  `./scripts/affected-tests.sh origin/main HEAD` prints (`ALL` means the whole suite), and `companion/test.sh` for
  `companion/`. The whole suite, `./scripts/test.sh`, runs once on the final head; `merge-pr.sh` runs it.
- **Smoke checklist:**
  - tier B, automated, once on the final head (one test run): replies recorded from the real model on invented
    binders, replayed through the reply parser. Planned; until the fixtures exist the record says "none yet".
  - each signed build, by the owner, about 20 minutes (real Keychain and launchd): install it with
    `./scripts/restart-app.sh` over the previous build (an ad-hoc one the first time), quit and reopen Sprava, and
    check that the Claude sign-in, the mail password and the backup key are still there, Health shows the runtime
    running, and `runtime/watch.json` gets a new `ran_at` at the next quarter hour.
- **Documents:** design and process documents get one critique and one revision. They do not go through the Codex
  review loop, local or cloud.

## Tools (`scripts/dev/`, for Claude, Codex and the author alike)

- `status.sh`: every open PR, its base, the cloud review's state, unresolved threads, whether it holds main.
- `open-pr.sh [<branch> [<base>]]`: opens a PR from its commits, with the shape line of `scripts/pr-check.sh`.
- `review.sh [<base>] [--claude]`: the local review of step 4, against "Review guidelines" below as they stand on
  the base, so a PR cannot rewrite its own rubric.
- `threads.sh list|reply|file`: reads a PR's review threads; answers and resolves one; or records a finding that
  does not block in a new issue, answers with its link and resolves it.
- `../merge-pr.sh <number>`: the last step of the gate.
- `prune-worktrees.sh [--apply]`: removes worktrees under `.claude/worktrees` that hold nothing unmerged and no file
  but build products; `test-prune.sh` tests it.

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

Also answer the round-1 question in "Review and test process" above, and name any of its triggers the change
matches.

Do not report:

- races that need another program running as the same user (a link swapped in, a rename or a write between
  Sprava's check and its use, a file grown or replaced under it). The threat model (`docs/architecture.md`
  section 1) does not defend against them; they are collected in issue #227;
- missing migrations or backward compatibility for Sprava's own state in the support folder: there is no
  installed base (decisions.md A14). Binders do keep compatibility (binder-v0, lifeproj);
- what a binder's Claude session can do with the whole shell the person gives it by allowing file changes, while
  the walls of its sandbox hold: starting any program the system or Homebrew installed, running scripts with them,
  or reading what other programs show in their environment, which no sandbox rule stops. The author accepted this
  (decisions.md D36). A way past those walls still counts: reading outside the binder, writing outside it, the
  network beyond the proxy, the person's other apps, clipboard or Keychain, or running a program from a writable folder;
- a hang or delay from a slow, stalled, network or removable volume: binders are ordinary local folders, offloaded
  when not in use and restored when needed (decisions.md A15);
- wording in a doc that differs from the code, unless the code breaks a rule the doc states;
- style, naming, refactoring, or more tests for behavior already tested;
- a point already answered in a resolved thread of the same PR.

## Build facts

- macOS 27, Swift 6.4, and Xcode (27.2 here) selected with `xcode-select -s /Applications/Xcode.app`; the package
  does not build with Command Line Tools alone. Views use `@State` for their own local state; app state lives in
  `ObservableObject` models with `@Published`.
- `./scripts/build-app.sh` builds `build/Sprava.app`, signed with an Apple-issued identity, or ad-hoc with
  `SPRAVA_SIGN_IDENTITY=-` (`docs/manual-checks.md`, "Signing"). It refuses to run while the app is open.
- The design docs in `docs/` are the source of truth for behavior; `docs/decisions.md` is the decision log.
