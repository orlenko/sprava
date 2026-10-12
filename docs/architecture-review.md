# Sprava architecture review (issue #214)

Date: 2026-10-11. Scope: merged `origin/main` at 8e5752e (worktree `arch-main`), the pending stack at
`origin/stack/13-app` 8a3fe61 (worktree `arch-stack`), the newest Backup drafts on `fix/10-final`, and PR #232.
Read-only. Every example below is invented. Line counts are `wc -l` over `*.swift` unless stated.

## 1. Verdict

The architecture is sound and should be kept. The layered SwiftPM targets of `docs/code-structure.md` are real,
enforced by the compiler, and the merged code respects them: no target imports a higher one, the domain targets
expose value types with injectable seams, and the one-writer rule is visible in the code. The pending code is
also far smaller than the PR totals suggest: the four drafts add about 7,700 source lines and 4,500 test lines
on top of main, not 50,000 (section 2.1). Most of it can land mostly as designed, split mechanically.

Three things should change before the rest lands, all cheap and behavior-preserving:

1. The runtime executable on the stack holds the job bodies (803 lines in `Runtime.swift`), which is the one
   place that contradicts the design ("job scheduling and wiring only"). The job bodies must land in `Services`
   as testable functions; the executable keeps timers, lease, watchdog and XPC.
2. The pending Backup drafts (`fix/10-final`) are written against a Backup model that main has since replaced.
   They cannot be split mechanically; restore, peek, forget and requests must be re-cut onto main's
   `BackupModels`/`BackupState`, as the first six Backup slices were.
3. Two hook checks are missing that would have prevented the most expensive review rounds: a PR-size and
   cross-target check against the real merge base, and a stale-base check. Both are an afternoon's work.

Everything else in this report is incremental: splitting the five files over 400 lines, renaming review-round
test files by behavior, converging the two state-file conventions, and a signing prerequisite for the Keychain.

## 2. Findings by focus area, most consequential first

Each finding says what was verified (a command, a file and line, a count) and what is inferred.

### 2.1 The pending work is about a sixth of what the PR numbers say

Verified. The stack branched from main at 747d386; main has 240 commits since, the stack 34 on its first-parent
line (`git merge-base`, `git rev-list --count`). PR #18's "+32,682 / 244 files" is `git diff origin/main...HEAD`
over the whole stack since that old base, which includes every file that main has since re-landed in other
shapes. Measured by target on the stack worktree versus main:

| Target | main | stack | pending delta |
|---|---|---|---|
| Sources/Services | 77 | 2,093 | ~2,000 |
| Sources/Brains | 148 | 848 | ~700 |
| Sources/SpravaApp | 0 | 2,101 | 2,101 |
| Sources/sprava-runtime | 0 | 1,006 | 1,006 |
| Sources/sprava | 0 | 444 | 444 |
| Sources/sprava-mcp | 0 | 65 | 65 |
| Sources/Backup | 3,366 | 1,429 (older) | restore, peek, forget, requests from `fix/10-final`: ~1,000 |
| Tests (Services, Brains, App) | 258 | 4,432 | ~4,200 |

Main's Backup is newer and larger than the stack's: the re-cut slices (#213 to #231) added identity, manifests,
offload pins and recovery that the stack never had. So every pending piece that calls Backup (the stack's
`BackupCommands.swift`, `Runtime.backup()`, `BackupView.swift`, `HealthSnapshot.checks`) must be adapted to
main's API, not copied.

Consequence: the plan should budget for about fifteen PRs of 300 to 800 lines, not fifty.

### 2.2 Domain boundaries and dependency direction: good, with four blurs

Verified on main:

- `Package.swift` declares the layers; `swift build` enforces them. Imports per target
  (`grep -rh '^import' Sources/<t>`) match the declared graph: Backup imports SpravaKit, BinderFormat,
  BinderStore, Shelf and Hub (it removes a binder's hub slice and its Shelf row when offloading) and Apple
  frameworks; Brains imports only SpravaKit; Capture imports Clerk, Extract, Shelf,
  BinderStore, BinderFormat, SpravaKit. No upward import exists.
- Public surface is sizeable but not reckless: Backup 154 `public` declarations, BinderStore 176, Capture 146
  (plus 46 `package`), Hub 21, Shelf 50, Services 5. `package` access is used where tests or the command layer
  need a seam, as the design intends.
- Environment variables are read in exactly one place per concern (`SPRAVA_SUPPORT_DIR` in
  `SpravaKit/SpravaPaths.swift:6`, `SPRAVA_BACKUP_KEY_FILE` in `Backup/BackupKeyStorage.swift:47`,
  `SPRAVA_RESTIC` in `Backup/Restic.swift:35`, `SPRAVA_CAPTURE_ROOT` in Capture, `OSAVUL_SPOOL`/`XDG_DATA_HOME`
  in Hub, `CMIRROR_CONFIG` in Shelf). Good: one owner per knob.

The blurs:

1. State-file ownership crosses a layer. `BinderStore/Commands.swift:30` writes
   `runtime/proposal-digests.json`, a file in the `runtime/` folder that the runtime (Services and the
   executable) otherwise owns (`heartbeat.json`, `breakers.json`, `lease`, `jobs.log`, `watch.json`,
   `sentinel.json`, `state.json`, `background-off`). Code-structure §3.3 says each target lists the files it
   owns in its header doc; no target does (`grep -rlniE 'owns|state files' Sources/*/*.swift` finds only
   incidental uses). This is the kind of thing that makes an agent edit the wrong target. Fix: a table of state
   files by owner in `docs/code-structure.md` (section 4), and the digests file moved under a BinderStore-owned
   folder when the file is next touched (not now: it is a path change the author's install would feel).
2. Two generations of the state-file convention coexist. Code-structure §4 says one helper, `StateFile`,
   replaces the fifteen hand-written variants. On main `StateFile.read` has 8 callers (Capture 5, Shelf 2,
   BinderStore 1) and is path-based. Backup and Brains instead use `StateDirectory` (PR #218), which holds a
   directory descriptor so a link swapped in cannot redirect a read or write (`SpravaKit/StateDirectory.swift:4`;
   `Backup/BackupState.swift:10`; `Brains/MCPClients.swift:55`). The stack's `Services/Sentinel.swift:21`
   (`BinderIDs.load`) hand-rolls the pattern a third way (`fileExists` then `try? Data(contentsOf:)`). Two
   reviewers have already filed link-swap races against the path-based variant (#227). Fix: make `StateFile`
   read and write through `StateDirectory` so the 8 callers get the handle discipline for free, then point the
   stack's hand-rolled reads at it. Behavior-preserving, SpravaKit only.
3. On the stack, `Services` mixes transport, identity and domain logic by file. `Services/XPC.swift` holds the
   `@objc` XPC protocol, the code-signing peer check (imports `Security`), `RequestQueues` (the serial
   command queue that makes the runtime the single writer, line 93) and `DeviceID` (line 130).
   `Services/Sentinel.swift` holds `BinderIDs`, `SentinelReport`, `OutsideEdits` (which opens a `TekaStore`
   and appends `external_edit` ops, lines 139 to 174) and `TrustBacklog` (line 198). `Services/Doctor.swift`
   holds the doctor and `DevelopmentGuard` (line 87), a CLI concern. None of this breaks the layer graph, but
   files named by one topic that hold four make small PRs hard. Fix when landing (section 3): one type per
   file, named for what it is.
4. The app talks to stores directly, which the written rule forbids and the architecture requires.
   Code-structure §3.5: "A screen talks only to the runtime client, never to a store." Architecture §2.1: the
   app reads binders from disk and must show everything while the runtime is down. The stack does the latter:
   `SpravaApp/Shelf/ShelfView.swift:29` constructs `ShelfStore`, `:35` reads `LifeprojRegistry`,
   `Binder/NowView.swift:18` calls `Teka.read`, `Inbox/Inbox.swift:106` loads `DeviceID` and writes a capture
   event through `CaptureProducer`, `Health/Health.swift:138` writes `runtime/background-off`. Writes to
   binders do go through `RuntimeClient` (`RuntimeClient.swift:5`), which is the invariant that matters. Fix the
   rule, not the code: "a screen reads through the read-only facades (`HealthSnapshot` and, to add, a
   `ShelfSnapshot`) and writes only through `RuntimeClient`". The two app-side writes (`background-off`, the
   capture event) are legitimate because the runtime may be down; name them in the rule as the only exceptions.

Inferred: the `Commands` struct lives in BinderStore and is extended by Capture (`Commands+Inbox.swift`, 6
lines) and by Services (the command tables). Extending a lower-layer type upward is a fine way to keep the
command table out of BinderStore; it should be stated in code-structure so no reviewer flags it as a leak.

### 2.3 Transport, domain logic, scheduling, persistence and views

Verified on the stack:

- Transport is thin and separable: the XPC listener (`sprava-runtime/XPCService.swift`, 63 lines) only checks
  the peer and hands the JSON string to `Commands.handle`; the MCP shim (`sprava-mcp/main.swift`, 65 lines)
  copies lines without parsing MCP; the MCP server's `handle(line:)` (`Brains/MCPServer.swift:103`) is pure
  over a `Commands`, a `shelf` closure and a `now` closure (line 20 to 26). These are the right shapes.
- Persistence is behind value types with injected seams: `Backup` takes `uploadCheck`,
  `secondLocationCheck`, `afterSnapshot`, `atStep` (`Backup/Backup.swift:14-21`); `ResticProcess` takes
  `clock` and `diskProgress` (`Backup/ResticProcess.swift:24-25`); `StateDirectory` takes a `Flush`
  (`SpravaKit/StateDirectory.swift:14`). Tests use them (`atStep` 8 uses, `uploadCheck` 24, `Flush(` 8).
- Scheduling is not separable today. `sprava-runtime/Runtime.swift` (803 lines) holds the heartbeat
  (line 174), the watchdog thread (211), IOKit power notifications (245), the 15-second scheduler (276), the
  per-job run/finish bookkeeping (295 to 370) and then every job body: `sentinel()` (372), `hub()` (420 area),
  `capture()`, `intake()`, `clerk()`, `dashboards()`, `backup()`, `summary()`, `checkAlerts()`, plus
  `UNUserNotificationCenter` and `SystemLanguageModel` probing. `schedule()` and `run()` call `Date()` directly
  (lines 277, 299, 300, 309 to 314) and `DispatchQueue.global` (line 319). `ServicesTests/RuntimeTests.swift`
  tests `JobRecord` only (5 `@Test` on main); nothing tests which jobs run when, the wake catch-up, the clock
  change re-arm, or the wedged detection, because they cannot be reached without the real timers.
- Views: the screens are one folder each as the rule asks (Shelf, Binder, Inbox, Backup, Brains, Health), all
  under 360 lines, models are `ObservableObject` with `@Published`, and `SpravaAppTests/AppModelTests.swift`
  drives them against a `StandInRuntime` that answers XPC requests in-process (line 13). This is the right
  seam and it already exists.

The fix for scheduling is one behavior-preserving extraction (section 3.1, landing with #17a): a pure `Scheduler` value in
Services with `func due(now:records:deadlines:) -> [JobKey]` and `mutating func started(_:now:)`, and each job
body as a function in `Services/Jobs/<Name>Job.swift` taking its dependencies as parameters (`Commands`,
`ShelfRows`, `now`, a `Notifier` closure, a `ModelProbe` closure). `Runtime.swift` then shrinks to timers,
lease, watchdog, power events and wiring, under 300 lines, and the job matrix of architecture §3.4 becomes a
table-driven test.

### 2.4 Files and tests by responsibility; focused runners

Verified on main:

- Five source files exceed the 400-line rule of code-structure §3.6: `BinderStore/TekaStore+Recovery.swift`
  661, `Capture/CaptureInbox+Sweep.swift` 613, `BinderStore/Proposals.swift` 613, `Capture/Intake.swift` 512,
  `BinderStore/Adoption.swift` 439. On the stack, `sprava-runtime/Runtime.swift` 803, `Brains/MCPServer.swift`
  494, `Services/Jobs.swift` 409, `sprava/main.swift` 444. On `fix/10-final`, `Backup/Backup.swift` 705,
  `BackupSnapshots.swift` 643, `BackupOffload.swift` 621.
- Test files are named after review rounds, not behavior: 67 of 115 test files on main match
  `AstraReview|Bugbot|CalibratedReview|LayerReview|ReviewRegression|CodexReview|StackReview`, holding 10,307
  of about 19,500 test lines. Capture is the worst: 24 of 29 files (`CalibratedReview2Tests` through
  `CalibratedReview11Tests`, `BugbotFinal2Tests` through `BugbotFinal4Tests`). The stack's `ServicesTests`
  continues the pattern (`AstraReview2Tests` to `AstraReview6Tests`, `ReviewRegression2Tests`,
  `ReviewRegression3Tests`). An agent asked "where is undo tested" has to grep every file. The suites inside
  are often well named; the files are not.
- Runners: `scripts/test.sh` passes its arguments to `swift test`, so `./scripts/test.sh --filter BackupTests`
  already works (line 24, `run "$@"`), but nothing documents it. The pre-push hook always runs the whole suite
  per new commit, which is right for a gate. There is one test-support target shared by all
  (`Tests/SpravaTestSupport`, 39 lines: fixtures, `makeTeka`, fixed dates), plus `ClerkTestSupport` and
  `CaptureTestSupport`. Test counts per target: Capture 210, BinderStore 157, Backup 142, Hub 71, Extract 55,
  Clerk 54, BinderFormat 45, SpravaKit 43, Shelf 14, Brains 11, Services 5.

Inferred: the review-named files are the residue of the gate working as designed (each round adds a file).
The cost is discoverability, not correctness. A rule plus a hook lint stops the growth; consolidation can be
gradual.

### 2.5 Crash recovery, concurrency, clock and filesystem seams

Verified on main, what is good:

- Crash recovery is testable where it matters most. `Backup.atStep` fires at each durable step boundary;
  `BackupOffloadPinTests` takes a disk image there and resumes from it ("run every interruption point through
  to leaving, with the binder, Trash and spool in each crash image", PR #232). `BinderStoreTests/
  RecoveryMatrixTests.swift` (366 lines) and `RandomSequenceTests.swift` (452) do the same for the op log.
  This is the strongest part of the test design and should be the template for the runtime's own state
  (`breakers.json`, `state.json`, the requests queue).
- The clock is a parameter in the domain targets: `now: Date = Date()` on every entry point in Capture (31
  signatures found by `grep 'now: Date'`), in Backup (10), `CalendarDate.today(now:)`, `UUIDv7.make(now:)`.
  The only direct `Date()` in Backup outside a default argument is `BackupSnapshots.swift:49` (`started`,
  used for a duration). `ResticProcess` reads a suspending clock through an injectable closure.
- The filesystem has two seams: `StateDirectory.Flush` for fsync, and the closures on `Backup`. `AtomicFile`
  does temp, fsync, rename, directory fsync (`SpravaKit/AtomicFile.swift:26`).
- Concurrency is deliberately simple: no Swift `actor` anywhere (the 86 `actor` hits in BinderStore are the
  JSON field `actor`), four `@unchecked Sendable` classes in all of main (`StateDirectory`, `Lease`, one in
  Backup, one in Extract), value types elsewhere. On the stack the one-writer rule is a serial
  `DispatchQueue` (`RequestQueues.commands`, `Services/XPC.swift:93`) that XPC, the MCP listener and the jobs
  share; jobs that write hop onto it with `xpc.queue.sync` (`Runtime.swift`, `clerk()` lines 112 and 118,
  `onCommandQueue`). The MCP listener uses a thread per connection with socket timeouts
  (`Brains/MCPSocket.swift:119, 140, 156`).

What tests cannot reach today:

1. The scheduler, wake catch-up, clock change and wedged detection (section 2.3). All in the executable, all
   on real timers and `Date()`.
2. The watchdog: `Thread.sleep(forTimeInterval: 60)` on a `SuspendingClock` (`Runtime.swift:211-220`). The
   decision ("no tick for 120 s awake, or wedged 10 min, exit 70") is a pure function of two readings and
   should be one.
3. Notifications and model availability: `UNUserNotificationCenter` and `SystemLanguageModel.default` are
   called inline (`Runtime.swift` lines 324 to 354). A `Notifier` and a `ModelProbe` closure, defaulting to
   the real ones, make `summary()`, `checkAlerts()` and the "Alerts are off" line testable.
4. The one-writer rule itself. Nothing asserts that every binder write happens on the command queue; it is a
   convention read in comments. A debug-only assertion (`dispatchPrecondition(condition: .onQueue(...))`) at
   `TransactionGuard` entry, injected as a closure so tests can set it, would make a violation fail a test
   instead of a review.
5. The MCP socket end to end. `MCPServer.handle(line:)` is tested in-process; the preamble, the per-call
   timeouts and the pause-after-10-failures rule live in `MCPListener` and need a real Unix socket. That is
   fine for one integration test in `BrainsTests` that connects over a socket in a temporary folder; it does
   not need a seam.

Inferred: the `DispatchQueue` plus `@unchecked Sendable` style is the right call under Swift 6 with Command
Line Tools only (no macros), and should not be migrated to actors now. It does need the one assertion above.

### 2.6 Signing and Keychain prerequisites

Verified:

- The bundle is ad-hoc signed with the hardened runtime, each executable under its own identifier
  (`scripts/build-app.sh:43-58`: `ca.orlenko.sprava`, `.runtime`, `.cli`, `.mcp`, `.extract`, `.restic`), no
  entitlements except the sandbox on `sprava-extract`.
- The XPC peer check pins the app's cdhash read from the runtime's own bundle at connection time, plus same
  uid and same executable path (`Services/XPC.swift:30-85`, `XPCService.swift:30-45`). This is a correct
  stand-in until a Team ID exists, and the comment says what it does not defend.
- The backup key uses the data-protection keychain (`kSecUseDataProtectionKeychain: true`,
  `Backup/BackupKeyStorage.swift:59`) with an access group derived from the signing team
  (`accessGroup(team:)`, lines 15-17), which is nil under ad-hoc signing. The header says so: "Host
  executables (the app and the runtime) need the `keychain-access-groups` entitlement ... ad-hoc development
  runs have no team and use the file override" (lines 8-9). The file override is `SPRAVA_BACKUP_KEY_FILE`.
- The LaunchAgent plist sets no environment (`Resources/LaunchAgents/ca.orlenko.sprava.runtime.plist`: Label,
  BundleProgram, KeepAlive, MachServices, ProcessType only), and launchd does not inherit a shell's
  environment.

Inferred from those four facts: in the app that `build-app.sh` produces today, the runtime has neither a team
(so no access group) nor the file override, so `BackupKey.load()` finds no key and backup reports "not set
up". The Keychain code path (1,100 lines across `BackupKeyStorage`, `BackupKeyRecovery`, with 16 `SecItem`
calls) has no executable in the repository that can run it. Tests run the file path only. That is not a bug
in the code; it is a missing prerequisite that must be written down and gated:

- A Developer ID identity and an entitlement file for the runtime only (`Resources/sprava-runtime.entitlements`,
  with `keychain-access-groups` = `<team id>.ca.orlenko.sprava`; the app gets no access group, since no app
  code path touches the key, next bullet) that `build-app.sh` applies when `SPRAVA_SIGN_IDENTITY` is set. The
  script writes the team id into the plist itself (`$(TeamIdentifierPrefix)` is an Xcode setting `codesign`
  does not expand), so the group matches `BackupKey.accessGroup(team:)`,
  and refuses to combine with ad-hoc signing silently (print which key store the build will use).
- Only the runtime loads the key (verified: `BackupKey.load` is called only as the default argument of
  `Backup.init`, `Backup/Backup.swift:26`; `HealthSnapshot.checks` passes `key: nil`; `sprava` and
  `sprava-mcp` do not import Backup). Keep it that way and state it in `docs/backup.md` §4: the app never
  needs the access group for reading, only for the setup commands it sends over XPC, which run in the runtime.
- The XPC pin must be re-derived at the same time (the comment at `XPC.swift:27` already says: Developer ID
  replaces the cdhash pin with `anchor apple generic`, the team, and the app's identifier `ca.orlenko.sprava`,
  which architecture §2.1 requires: a team alone admits every program the developer signs). Put both in one "signed build" checklist
  in `docs/manual-checks.md`, and add a `Doctor` finding that names the key store actually selected (the file
  when `SPRAVA_BACKUP_KEY_FILE` is set; otherwise the Keychain, which an ad-hoc build reaches with no access
  group) so the Health page says it. (Corrected after review: `BackupKey.load` picks the file only when the
  override is set, and otherwise calls the Keychain whatever the signature.)

### 2.7 PR sizing and checks

Verified:

- The hooks are strong on privacy and correctness: pre-commit scans every staged byte and file name for
  private tokens and builds the staged snapshot in a separate tree (`scripts/git-hooks/pre-commit:1-30`);
  pre-push tests every new commit in a detached worktree with a tree-hash cache (`pre-push`, `suites.sh`).
- The hooks check nothing about shape: no diff-size check, no "how many `Sources/<target>` folders does this
  commit touch", no test-file-name lint, no file-length lint, no check that the branch is based on current
  main.
- The cost of the missing checks is in the merged PR history. The twelve split PRs since the re-cut
  (`gh pr view ... --json reviews,files`): #225 "stable backup ids and manifests" was +1,270 lines across
  Backup and SpravaKit (two domain-layer targets) and collected 58 review events; #228 +872, 33 events; #231
  +939, 14 events; #220 +1,096, 10 events; #222 +875, 8 events. The PRs under 400 lines in one target (#213,
  #216, #217, #218, #219, #226) each closed with 0 to 5. The correlation is size and target count, not
  difficulty.
- The stale base is a separate failure: #15 to #18 report +7,041 to +32,682 lines because each is diffed
  against a branch that no longer resembles main (section 2.1).

What to add (section 5 has the exact checks): a `scripts/pr-check.sh` run by pre-push on the pushed ref's
range from `merge-base origin/main HEAD`, reporting lines changed, targets touched, files over 400 lines, and
test files with review-round names; refusing over 1,000 lines or more than one domain target unless
`SPRAVA_ALLOW_LARGE=1`; and warning when the merge base is more than N commits behind `origin/main`.

## 3. The pending drafts

Order of landing is in 3.5. Each item says: land mostly as is, restructure before landing, or redesign.

### 3.1 #17 Services and runtime: restructure, then land in six PRs

Land as is (split by file): `Jobs.swift` (JobSpec, JobOutcome, JobRecord, JobRecords, WatchBox, JobDeadlines,
RuntimeState; 409 lines, pure, already tested in `RuntimeTests`), `Heartbeat.swift` (190, the Appendix A
schema), `CommandTable.swift` + `BinderCommands` + `CaptureCommands` + `SettingsCommands` (391 lines, tested by
`CommandsTests` and the Bugbot/Astra suites), `Measures.swift` (161), `Doctor.swift` without
`DevelopmentGuard` (about 90), the `sprava` CLI (444).

Restructure before landing:

- `XPC.swift` becomes three files: `XPCProtocol.swift` (the `@objc` protocol and `XPCNames`), `XPCPeer.swift`
  (the signing check), `RequestQueues.swift`; `DeviceID` becomes `Services/DeviceID.swift`.
- `Sentinel.swift` becomes `BinderIDs.swift`, `SentinelReport.swift`, `OutsideEdits.swift`,
  `TrustBacklog.swift`.
- `DevelopmentGuard` moves to the `sprava` executable (it exists for `sprava dev`).
- `BackupCommands.swift` (108) and `BrainCommands.swift` (74) wait for their domains (3.2, 3.3) and land with
  them, rewritten against main's Backup API.
- `sprava-runtime`: `Runtime.swift` is split as in 2.3. The job bodies move into
  `Services/Jobs/CaptureJob.swift`, `ClerkJob.swift`, `IntakeJob.swift`, `HubJob.swift`, `DashboardJob.swift`,
  `SentinelJob.swift`, `SummaryJob.swift`, `AlertsJob.swift`, `BackupJob.swift`, each a function from
  explicit inputs to `JobOutcome`, with the notifier and model probe as closures. A `Scheduler` value holds
  `schedule()`'s decisions. The executable keeps `main.swift`, `XPCService.swift`, `OutsideWatcher.swift` and
  a `Runtime.swift` of timers, lease, watchdog, power notifications and wiring. The job specs table
  (`Runtime.specs`) moves next to the jobs.

Why restructure rather than land and refactor: the job bodies are where the next features go (the conversation
runners, the companion relay job), and the review rounds on Backup show that code without a test seam costs
3 to 10 rounds. Moving them now is a rename-heavy diff; moving them after they land is a second review of the
same lines.

Nothing to drop.

### 3.2 #16 Brains: land mostly as is, in three PRs

- `MCPClients`: main already has the newer registry (148 lines, handle-based, PR #216 and #217); the stack's
  100-line version is older. Discard the stack's copy; keep main's.
- PR 1: `MCPServer.swift` (494 lines) plus `BrainsTests/MCPTests` and the review suites that drive
  `handle(line:)`. Pure over `Commands`, `shelf` and `now`. Split the file into `MCPServer.swift` (JSON-RPC
  and eras), `MCPTools.swift` (the static tool list and schemas, lines 32-100) and `MCPServer+Calls.swift`
  (`call(_:_:)`, line 312 on), to get under 400 each. Move-only within the PR.
- PR 2: `MCPSocket.swift` (254) and `sprava-mcp/main.swift` (65) with one socket integration test in a
  temporary support folder.
- PR 3: `BrainCommands.swift` with its command tests, once the command table is on main.

The dependency Brains → Capture (for intake readings) is in the design table; fine. The `Commands` trust
record it uses is `package` API of BinderStore (`loadDigests`, `key`), which is the one place a higher target
reaches into another's `package` surface (`MCPServer.swift:289`). Acceptable, but it is worth one public
`Commands.isRecorded(_:in:)` so Brains does not depend on BinderStore's internal key format.

### 3.3 #15 rest of Backup: redesign onto main's model, in five PRs

The stack's `Backup.swift` (943 lines, one file) and `fix/10-final`'s `Backup.swift` (705) + `BackupOffload`
(621) + `BackupSnapshots` (643) are a different decomposition from main's (`BackupModels`, `BackupState`,
`BackupIdentity`, `BackupManifest`, `BackupSnapshots`, `BackupOffload`, `BackupOffloadChecks`,
`BackupOffloadRecovery`, `BackupSetup`, `BackupStatus`, `BackupDestinations`, `BackupKey*`, `Restic`,
`ResticProcess`, `BinderSprava`, and `BackupLeave` from #232). The state schema differs too (`fix/10-final`
has `restoredContents`, `rewrites`, `Forgotten`, `RestoredContents`, `Rewrite` in `State`; main's `State` has
offload jobs, pins and checkpoints). Mechanical splitting is not possible; the drafts are the specification
and the test ideas, not the code.

Re-cut, in this order, each against main:

1. `BackupRequests` (the queue; `fix/10-final` 203 lines) + `BackupCommands` + the runtime's `backup()` job
   function. Needed first because the app's Backup screen and Health page drive everything through it.
2. Restore (`fix/10-final` `BackupRestore.swift`, 281 lines, which already has the staging-folder and
   resume design) onto main's `Offloaded`/pins model. One PR with the crash-image tests in the
   `BackupOffloadPinTests` style.
3. Peek (`restic dump` into a temporary folder, `cleanPeeks`), small.
4. Forget (`BackupForget.swift`, 306 lines): the `rewrite --exclude --forget` flow with per-repository scopes.
   This is the most intricate state machine in the drafts and should be last; it is also the one the MVP can
   ship without (expunge is a binder-v0 open question).
5. Maintenance (`maintain(rows:deviceID:now:)`: retention, weekly check, monthly read-data subset, drill
   reminders) as a `BackupJob` function in Services.

Open issues #221, #223, #224, #229, #230, #233 to #236 are all Backup edge cases from these reviews. None
changes the structure; #230 (offloaded registry binders stay on the Shelf) belongs in Shelf and should land
before restore so restore can clear the exclusion.

### 3.4 #18 SpravaApp: land as is, in seven PRs

The app on the stack is 2,101 lines in ten files, none over 360, already by screen folder, already tested
through `StandInRuntime`. Split by folder:

1. `RuntimeClient.swift` + `SpravaApp.swift` + `Shelf/` (433 lines, reading through a new `ShelfSnapshot`
   facade in Services instead of constructing `ShelfStore`, so the slice obeys rule 5) + `AppModelTests` + `Resources/App-Info.plist`
   + `scripts/build-app.sh` and the LaunchAgents plists. The script bundles the products that exist so far;
   `sprava-mcp` joins it with Brains PR 2.
2. `Binder/` (596: NowView, Review, BinderActions).
3. `Inbox/` (286).
4. `Health/` (359), including `SMAppService` registration and the restart path.
5. `Backup/` (280), rewritten against main's `Backup.status`, `offload(... nameCollides:)` and the request
   queue of 3.3.
6. `Brains/` (147).
7. `HealthSnapshot` (91, in Services) can go with 4; `ShelfSnapshot` goes with 1.

Before 1, amend code-structure §3.5 as in 2.2 (4), so the reviewer does not flag `ShelfStore` in the Shelf
model as a rule violation.

### 3.5 Landing order

The order minimizes forward references and puts the testable groundwork first:

1. Groundwork (behavior-preserving, main only): R1 to R3 of section 4 that the pending code lands onto:
   `StateFile` over `StateDirectory`; the hook checks; the code-structure amendments (state-file table, rule
   3.5, the `Commands` extension pattern).
2. #17a Services core: Jobs, Heartbeat, Scheduler (new, pure), DeviceID, XPCProtocol, XPCPeer, RequestQueues.
3. #17b Command table: CommandTable, BinderCommands, CaptureCommands, SettingsCommands, the `sprava` CLI.
4. #17c Cross-area readers: BinderIDs, SentinelReport, OutsideEdits, TrustBacklog, Doctor, Measures,
   HealthSnapshot.
5. #17d Runtime executable skeleton: main, lease, heartbeat, watchdog, power, XPCService, OutsideWatcher,
   with the sentinel, summary and alerts job functions.
6. #18 (1) app shell + Shelf + build script; then #18 (2) Binder, (3) Inbox, (4) Health. At this point the
   author has a working read-only app with approvals over XPC.
7. #17e capture, clerk, intake, dashboard, hub job functions (the runtime now files captures).
8. #16 Brains in three PRs, then #18 (6) Brains screen.
9. #15 re-cut: requests + commands + backup job; R12 (#230, the Shelf exclusion that restore clears); restore;
   peek; then #18 (5) Backup screen.
10. #15 forget and maintenance; the Backup issues (#221 to #236) as they fit.

Steps 6 to 9 can interleave with 1 to 5 when a PR is independent, but the app shell should not wait on
Brains or Backup.

## 4. Refactor PRs for the merged code, prioritized

Behavior-preserving first. Sizes are estimates of changed lines including tests.

| # | Goal | Targets | Size | Behavior |
|---|---|---|---|---|
| R1 | `StateFile.read`/`write` go through `StateDirectory`; the 8 callers unchanged; tests for a link swapped under a read | SpravaKit (+ its tests) | 200-300 | preserving |
| R2 | Hook checks: `scripts/pr-check.sh` (size, targets touched against the real merge base, files over 400 lines, review-named test files, stale base), wired into pre-push as a report and a refusal above thresholds; `test-hooks.sh` cases | scripts | 300-400 | preserving (tooling) |
| R3 | `docs/code-structure.md`: the state-file ownership table; rule 3.5 restated as read facades + `RuntimeClient` writes; the `Commands` extension pattern; "job bodies live in Services"; the `--filter` runner | docs | 150 | preserving |
| R4 | Split `TekaStore+Recovery.swift` (661) into recovery matrix vs replay; `Proposals.swift` (613) into the store vs the record; move-only | BinderStore | 700 moved | preserving |
| R5 | Split `CaptureInbox+Sweep.swift` (613) and `Intake.swift` (512) by stage (scan, candidates, readings, replacement); move-only | Capture | 800 moved | preserving |
| R6 | Capture tests by behavior: fold the 24 review-named files into `InboxSweepTests`, `InboxCarryTests`, `IntakeTests`, `PrivacyTests`, `CorrectionsTests`; suites keep their names so history is greppable. Two PRs of about 900 | CaptureTests | 2 × 900 | preserving |
| R7 | Same for BinderStoreTests (13 review-named files) and HubTests (6) | BinderStoreTests, HubTests | 2 × 700 | preserving |
| R8 | `Commands.isRecorded` public, so Brains stops using the `package` digest key | BinderStore | 40 | preserving |
| R9 | Signing prerequisite: entitlement files, `SPRAVA_SIGN_IDENTITY` in `build-app.sh`, a Doctor finding naming the key store in use, `docs/manual-checks.md` checklist | Resources, scripts, Services (Doctor) | 200 | changes a Health line only |
| R10 | `Adoption.swift` (439): split the synced-location checks and the stamp out; move-only | BinderStore | 450 moved | preserving |
| R11 | Debug assertion that binder writes run on the command queue, injected as a closure on `TransactionGuard` | BinderStore, Services | 80 | preserving in release |
| R12 | Issue #230: Shelf exclusion list for offloaded folders | Shelf | 150 | behavior |

R1 to R3 before any pending PR. R4, R5, R10 whenever those files are next touched, not before. R6 and R7
are optional and can be deferred indefinitely if the hook lint of R2 stops new review-named files; the
cheapest version is to require that any new test file added by a review round goes into an existing
behavior-named file.

## 5. Seams and checks that would cut review rounds

Where tests cannot reach today, and the seam that fixes each:

| Behavior | Today | Seam |
|---|---|---|
| Which jobs run at a tick, after a wake, after a clock change; backoff and half-open timing | `Runtime.schedule()`/`run()` on real timers and `Date()` | `Scheduler` value: `due(now:awake:records:deadlines:) -> [JobKey]`; the executable feeds it `Date()` |
| Watchdog decision (stall, wedged) | thread with `Thread.sleep(60)` | `Watchdog.verdict(tick:lastTick:awakeSince:wedged:) -> Exit?` pure; the thread calls it |
| Notifications and "alerts off" | `UNUserNotificationCenter` inline | `Notifier` closure `(title, body, id) -> Bool` on the job inputs; `AlertsProbe` closure |
| Model availability line | `SystemLanguageModel.default` inline | `ModelProbe` closure returning `Heartbeat.Model` |
| Runtime state crash recovery (`breakers.json`, `state.json`, `requests.json`) | written in `finish()`; no crash images | the `atStep` pattern from Backup: a step closure at each save, tests image the folder and restart `Runtime`'s pure parts |
| One-writer rule | convention | the R11 assertion |
| MCP listener over a real socket | untested | one `BrainsTests` integration test with a temporary support folder; no seam needed |
| Keychain store | file override in tests, no executable runs the Keychain path | a `KeyStore` protocol with `FileKeyStore` and `KeychainKeyStore`, chosen in one place by the signature (team present or not), so the ad-hoc app runs the file store deliberately, and the signed build is the only one that touches the Keychain |

Checks for the hooks (R2), each a few lines of shell in `pr-check.sh`, run by pre-push on
`$(git merge-base origin/main <sha>)..<sha>` for the commit each pushed ref names (never `HEAD`, which may be
another branch):

1. Lines changed (`git diff --shortstat`): warn above 500, refuse above 1,000 unless `SPRAVA_ALLOW_LARGE=1`.
2. Domain targets touched: the set of `Sources/<t>` for `t` in layers 1 to 6 (not SpravaKit, not Services,
   not tests, not executables); refuse when more than one unless allowed. (#225 touched Backup and SpravaKit,
   one domain target by this count; check 1 would have refused it for its 1,270 lines. SpravaKit is exempt
   because any feature may add a shared helper there.)
3. Stale base: if `git merge-base origin/main HEAD` is more than 20 first-parent commits behind `origin/main`,
   warn and print the real diff size against the merge base, so a PR description never carries an inherited
   total.
4. Files over 400 lines among the changed files: warn (not refuse; move-only splits are their own PR).
5. New test files whose name matches the review-round pattern: refuse with "add the test to the behavior's
   file".
6. The same report printed by `scripts/pr-check.sh` on demand, so the PR description can paste its first
   line ("+612/-40 in Backup, 1 target, base 0 behind").

Review-process checks that need no code: the PR description states the target and the real size from
`pr-check.sh`; a reviewer prompt that asks only about the stated target, so the cloud review does not spend
its rounds on inherited files.

## 6. Tradeoffs, and what is not worth changing now

- Do not move to Swift actors or structured concurrency. The `DispatchQueue` plus value-type style is
  consistent, the compiler toolchain forbids the macros that make actors pleasant, and the one-writer rule is
  one serial queue. The R11 assertion buys most of the safety for 80 lines.
- Do not rename the on-disk `runtime/proposal-digests.json` now, and do not rename `Teka*` types to
  `Binder*`. P18 keeps the old names on disk; the type names follow. A rename sweep is a 2,000-line diff with
  no behavior and would collide with every pending PR.
- Do not introduce a `Clock` protocol. `now: Date = Date()` parameters are already the convention in the
  domain targets and are simpler to read; the Scheduler extraction removes the remaining direct `Date()`
  calls that matter.
- Do not route the app's reads over XPC to satisfy rule 3.5 as written. The architecture requires reading
  while the runtime is down; the read facades keep the rule's intent (no store writes from the app) without
  a second transport.
- Do not consolidate the review-named test files before the hook lint exists; without the lint the next
  review round recreates them.
- Do not split `Backup` into two targets (keys vs repository). It is 3,366 lines in 19 files of under 360
  each, and the dependency graph already isolates it; the cost is in the pending code's shape, not the
  target's.
- The `package` access level is used in 100 places across targets. It is the right tool for test seams and
  for the command layer; the only cleanup worth doing is R8, where a higher target depends on a lower one's
  internal key format.
- The MCP shim and listener are hand-rolled JSON-RPC (decisions A10). Keep it; the server is 494 lines and
  pure, and a dependency would bring a second build system into a Command Line Tools-only project.
- The `fix/10-final` drafts keep their value as the record of what the reviews found (restore staging and
  resume, forget scopes per repository, the rewrite reconciliation). Keep the branch until the re-cut lands;
  do not try to rebase it.
