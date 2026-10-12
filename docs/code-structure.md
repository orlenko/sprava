# Code structure

How Sprava's code is divided, so that a feature touches one well-bounded part and an agent can work on it
without reading the rest. Status: proposed 2026-10-08, after PR #2; amended 2026-10-11 after the
architecture review (`docs/architecture-review.md`, issue #214): state-file owners (section 4.1), how the app
reads (rule 5), job bodies and the command table (rules 4 and 8), test files by behavior (rule 7), the shape
check (rule 9). The migration in section 5 is a series of behavior-neutral PRs.

## 1. The problem today

All library code is one SwiftPM target, `SpravaCore` (about 11,000 lines in ten folders). Folders are only a
convention, and they already depend on each other in cycles:

- Ops ↔ Capture ↔ Clerk: the clerk reads `CaptureEvent` and `IntakeReading`; capture builds proposals; Ops'
  `Commands.swift` calls into capture, backup, MCP and the clerk.
- Runtime ↔ Ops: `AtomicFile` lives in Runtime, and Runtime's doctor reads Ops' stores.
- `Commands.swift` is one switch over 27 commands from every area, so every feature edits it.

The Bugbot review of PR #2 showed the cost: one cause (an unreadable state file silently treated as empty)
reappeared in about fifteen places, because each module wrote its own file handling.

## 2. Targets and layers

Each box is a SwiftPM target. A target may depend only on targets in lower layers; SwiftPM refuses a cycle and
the compiler refuses an undeclared import, so the boundaries are enforced rather than remembered.

| Layer | Target | Owns | Depends on (direct) |
|---|---|---|---|
| 0 | `SpravaKit` | JSON (value, parser, writer, edit), `AtomicFile`, `StateFile` (section 4), `SafeFile`, dates and timestamps, `UUIDv7`, `SpravaPaths`, `ProcessCheck` | nothing |
| 1 | `BinderFormat` | reading a binder: `Teka`, items, buckets, rules, catalog levels, the dashboard text, document path rules, the hub's naming rules | SpravaKit |
| 2 | `BinderStore` | writing a binder: op log, transaction guard, op applier, proposals and their store, the record of trusted cards, ids, the privacy ratchet, undo, owner record, adoption, templates, the dashboard keeper | BinderFormat |
| 3 | `Shelf` | which binders exist here: the shelf, lifeproj's registry, recent order, the filing list and binder settings | BinderStore |
| 3 | `Extract` | type sniffing and text extraction, the sandboxed helper's protocol, `IntakeReading` | BinderFormat |
| 4 | `Clerk` | the model seam, date grammar, amounts, code facts, note and document readings, the proposals they become | Extract, Shelf |
| 5 | `Capture` | capture events, the inbox, the intake watcher, the readings store | Clerk |
| 4 | `Hub` | slices, publish and drain, the outbox | Shelf |
| 5 | `Backup` | restic, keys, snapshots, offload, restore, peek | Hub |
| 6 | `Brains` | MCP server and clients; later, the conversation runners (`claude -p`, `codex exec`, `agy -p`, a local model) | Capture |
| 7 | `Services` | the command layer: one handler file per area, behind a command table, plus jobs, the lease, the heartbeat, the doctor, measures and sentinel that read across areas | Brains, Backup, Hub, Capture |
| 8 | executables | `sprava-runtime` (timers, lease, watchdog, power events, XPC and wiring; no job bodies, rule 8), `SpravaApp` (screens), `sprava` (CLI), `sprava-mcp`, `sprava-extract` | Services; `sprava-mcp` only Brains; `sprava-extract` only Extract |

Each target also lists the lower targets it imports directly; the column shows the nearest ones. Where this
differs from the first plan, the reason is a real use, not convenience:
- `Shelf` sits on `BinderStore`, because binder settings and the filing list are written through the store.
- `Extract` needs `BinderFormat` for the document path rules (the key-file rule among them).
- `Clerk` reads the filing list, which lives in `Shelf`.
- `Backup` removes a binder's hub slice before offloading it, so it sits on `Hub`.
- `BinderStore` arrived as two PRs (the writer, then adoption, undo, templates and the dashboard keeper)
  because approving a card needs id minting and the privacy ratchet from the first part.

Moves that broke the earlier cycles:
- The clerk takes a small `ClerkInput` (text, locale, capture day, privacy, id) instead of `CaptureEvent`, so
  `Clerk` never imports `Capture`.
- `IntakeReading` moves to `Extract`, and `IntakeFacts` to `Clerk`.

## 3. Rules for feature work

1. A feature lives in one domain target (layer 3 or 4), plus its handler file in `Services`, its screen
   folder in `SpravaApp`, and its tests. If a feature seems to need edits in three domain targets, the
   design is wrong: add an interface in the lower target, or a new target.
2. A domain target exposes a small public API. Everything else is `internal`. A test target may use
   `@testable import` for its own target only.
3. Each target owns its files in Sprava's support folder; section 4.1 lists them by owner. No other target
   reads or writes them; it asks the owner.
4. The command layer is a table of handlers, one file per area (`BinderCommands`, `CaptureCommands`,
   `BackupCommands`, `BrainCommands`, `SettingsCommands`). Adding a command adds a line to one file. The
   `Commands` type itself lives in `BinderStore` (it holds the trusted-card record); higher targets add their
   areas as extensions in their own target (`Capture`'s `Commands+Inbox.swift`, the handler files in
   `Services`). Extending a lower target's type from above is the intended pattern, not a leak.
5. The app has one folder per screen (`Shelf/`, `Binder/`, `Inbox/`, `Backup/`, `Brains/`, `Health/`). A
   screen reads through read-only facades (`HealthSnapshot`, and a `ShelfSnapshot` when the Shelf needs one)
   or the binder readers of `BinderFormat`, because it must show everything while the runtime is down
   (architecture 2.1). It writes only through `RuntimeClient`. The two exceptions, both because the runtime
   may be down: the app writes `runtime/background-off` and its own capture events.
6. Files stay under about 400 lines; a file that grows past that is split by responsibility, not by length.
7. Tests mirror targets: one test target per library target. A change runs its own target's suite in
   seconds with `./scripts/test.sh --filter <Target>Tests` (the arguments go to `swift test`); the pre-push
   hook runs everything. A test file is named for the behavior it covers (`InboxSweepTests`,
   `OffloadRecoveryTests`), never for the review round that found the bug: a review's regression test goes
   into the file for that behavior. Many older files still carry review names; they are folded in when next
   touched.
8. Job bodies live in `Services` (`Services/Jobs/<Name>Job.swift`), as functions from explicit inputs
   (`Commands`, shelf rows, `now`, and closures for notifications and model availability) to a job outcome,
   so tests reach them without timers. Which job runs when is a pure `Scheduler` value in `Services` too.
   `sprava-runtime` only feeds them the clock and the real system services.
9. Every branch is measured against where it really leaves main by `scripts/pr-check.sh`, which pre-push
   runs: over 1,000 changed lines, or more than one domain target (layers 1 to 6), is refused unless
   `SPRAVA_ALLOW_LARGE=1`; a new test file named after a review round is refused; over 500 lines, a base
   more than 20 commits behind main, and changed files over 400 lines are reported. The PR description
   quotes its first line.

## 4. Shared conventions every target uses

- `StateFile`, in `SpravaKit`: read a JSON state file where a missing file means empty, and an existing
  file that cannot be read or decoded throws. Writes are atomic. The caller fails closed on a throw:
  no overwrite, and an error the job reports. This one helper replaces the fifteen hand-written variants
  Bugbot found. It reads and writes through a `StateDirectory` handle on the file's folder, so a link in
  place of the file or the folder is refused, not followed. A target with several files in one folder
  (`Backup`, `Brains`) holds the `StateDirectory` itself.
- Errors that reach the person are plain sentences. Logs carry ids and counts, never titles, names or text.
- Every spec rule a target enforces cites the spec section in a one-line doc comment, as now.

### 4.1 State files by owner

Paths are relative to Sprava's support folder (`SpravaPaths.supportDirectory()`), except two that an
environment variable can put anywhere: the capture root (`SPRAVA_CAPTURE_ROOT`, for development) and the
backup key file (`SPRAVA_BACKUP_KEY_FILE`), which keep their owners. Inside a binder the format is the
binder's own: `BinderFormat` reads it and `BinderStore` is its only writer (`.sprava/`, `catalog.json`,
`DASHBOARD.md`), except `.sprava/cursors.json` and `.sprava/slice-key`, which `Hub` reads and writes.

| Owner | Files |
|---|---|
| `Shelf` | `shelf.json`, `shelf.lock`, `recent.json`, `binders.json` (the filing list), `label-key` |
| `Capture` | `Captures/` (the capture root), `capture/` (`state.json`, `journal.ndjson`, `producers.json`, `producer-hlc.json`, `intake.json`, `app-notices.ndjson`, `unfiled-digests.json`, `quarantine/`, `interpretations/`, `readings/`), `unfiled/` |
| `BinderStore` | `runtime/proposal-digests.json` (the trusted-card record; it sits in `runtime/` for history and moves under a `BinderStore` folder when next changed) |
| `Brains` | `mcp/` (`clients.json`, the client registry) |
| `Backup` | `backup/` (`settings.json`, `state.json`, `verify/`, `cache/`, `run/`, `keychain.lock`), and the key file wherever `SPRAVA_BACKUP_KEY_FILE` names it |
| `Services` | `device-id`, and the rest of `runtime/` (`sprava-runtime` and the app write them only through `Services`' types): `lease`, `heartbeat.json`, `breakers.json`, `state.json`, `watch.json`, `sentinel.json`, `trust-backlog.json`, `jobs.log` and its rotations, `lease-refusals.log`, `background-off` |

A new state file is added to this table in the PR that creates it.

## 5. Migration, one behavior-neutral PR at a time

Each step moves code and adds `public` where a boundary needs it. No behavior changes; the full suite passes
unchanged. Git records moved files as renames, so the reviewable diff stays small.

1. `SpravaKit` and `StateFile`; switch the state files to `StateFile`.
2. `BinderFormat` and `BinderStore`.
3. `Extract` and `Clerk`, with `ClerkInput`.
4. `Shelf`, `Capture`, `Hub`, `Backup`, `Brains`.
5. `Services`: the command table and handler files; the runtime keeps only scheduling.
6. The app's screen folders; test targets split to match.

New features wait until step 5, so that they land in the new shape. The binder conversation then arrives as
work in `Brains` (the runners and the router), `Services` (`ChatCommands`) and `SpravaApp/Binder/Chat`.
