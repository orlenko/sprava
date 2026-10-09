# Code structure

How Sprava's code is divided, so that a feature touches one well-bounded part and an agent can work on it
without reading the rest. Status: proposed 2026-10-08, after PR #2. The migration in section 5 is a series
of behavior-neutral PRs.

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
| 8 | executables | `sprava-runtime` (job scheduling and wiring only), `SpravaApp` (screens), `sprava` (CLI), `sprava-mcp`, `sprava-extract` | Services; `sprava-mcp` only Brains; `sprava-extract` only Extract |

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
3. Each target owns its files in Sprava's support folder and lists them in its header doc. No other target
   reads or writes them; it asks the owner.
4. The command layer is a table of handlers, one file per area (`BinderCommands`, `CaptureCommands`,
   `BackupCommands`, `BrainCommands`, `SettingsCommands`). Adding a command adds a line to one file.
5. The app has one folder per screen (`Shelf/`, `Binder/`, `Inbox/`, `Backup/`, `Brains/`, `Health/`). A
   screen talks only to the runtime client, never to a store.
6. Files stay under about 400 lines; a file that grows past that is split by responsibility, not by length.
7. Tests mirror targets: one test target per library target, so a change runs its own suite in seconds.

## 4. Shared conventions every target uses

- `StateFile`, in `SpravaKit`: read a JSON state file where a missing file means empty, and an existing
  file that cannot be read or decoded throws. Writes are atomic. The caller fails closed on a throw:
  no overwrite, and an error the job reports. This one helper replaces the fifteen hand-written variants
  Bugbot found.
- Errors that reach the person are plain sentences. Logs carry ids and counts, never titles, names or text.
- Every spec rule a target enforces cites the spec section in a one-line doc comment, as now.

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
