# Decisions log

> Started 2026-10-06; rewritten 2026-10-30 so that each entry states what holds now. Status: **decided** (by the
> author) · **recommended** (by a planning session; it stands until the author overrides it) · **open** (needs
> the author). Entries keep their numbers, because the other docs and the code cite them. An entry that no
> longer holds is listed under "Retired" at the end with what replaced it; its old text is in git history
> (`git log -p docs/decisions.md`).

## Product and scope

- **P1 decided.** A local Mac app; Sprava itself needs no subscription. Three tiers: Tier 0 the structured
  organizer with no model; Tier 1 the on-device clerk; Tier 2 the binder's agent, which Sprava runs per binder on
  the person's own Claude (later Codex or Antigravity) subscription and which is the front door when connected
  (D22). Without an engine, Tiers 0 and 1 still work. Apple's Private Cloud Compute is not a tier: it is only for
  App Store apps in the Small Business Program with a managed entitlement.
- **P2 recommended.** macOS 27 only, Apple silicon only. The clerk is designed for a **4,096-token**
  budget and reads `SystemLanguageModel.contextSize` at runtime (8,192 on M3-or-later Macs with 12 GB,
  which run the 20B-sparse "Core Advanced" model; 4,096 on M1/M2, which run the 3B "Core" model).
- **P3 recommended.** The clerk uses the Swift `FoundationModels` framework directly. The `fm` CLI and Apple's
  Python SDK are developer tools only (`fm` needs a one-time `sudo fm license`, cannot drive tool calls through
  `fm serve`, and its legal notice forbids programmatic use beyond what is expressly permitted; the Python SDK
  needs full Xcode). The local open model is D5's.
- **P4 recommended.** Distribution: a Developer ID notarized DMG first (hardened runtime, not
  sandboxed, the holos precedent). The Mac App Store later, only once the licence route is settled.
- **P5 recommended.** The clerk's scope (Tier 1): one capture or one short document at a time. Normalize, split
  into items, extract dates, amounts and people, pick a binder from a closed list (or "not sure"), check
  duplicates against a handful of retrieved candidates, title and date a short document, draft a one-line nudge.
  Reconciling a binder, cross-referencing documents and drafting letters are the agent's (D22).
- **P8 recommended.** Languages: the clerk covers what Apple's on-device model supports (24 locales, including
  en-CA and fr-CA; not Ukrainian). Other languages go through the agent (D22) and translation at filing (D8).
- **P9 decided (2026-10-31, by the author).** Sprava supports any personal project. Templates are editable files
  outside source code, containing folder structure, an undated checklist and a project guide for filing, search
  and preparation. The app discovers and previews them; each created binder retains its own copy. Shipped
  examples do not define a fixed set of project types. No inferred statutory deadline rules.
- **P10 decided (2026-10-07, at implementation).** SwiftUI with AppKit where needed, using `ObservableObject`
  rather than the `@Observable` and `@State` macros: the Command Line Tools ship no SwiftUI macro plugin. A
  hidden `--snapshot` option renders the window offscreen with invented binders for layout checks.
- **P11 recommended.** Names. "Osavul" stays a private codename: an existing AI company filed OSAVUL in classes 9
  and 42 in the EU, the UK and the US the week of 2026-09-29. "teka" is no longer a term (P18) and was never to
  be an app name (Teka Industrial holds it for appliances and ships a "Teka Home" app). "Sprava" has no live mark
  in classes 9/42 in the US, Canada or EU, but npm `sprava`, sprava.ai, sprava.dev and two iOS apps use the
  name; sprava.app, sprava.io and sprava.ca were free on 2026-10-06. Get a clearance opinion before announcing.
  Not legal advice.
- **P12 decided (2026-10-07, by the author).** Sprava is input-agnostic. How a person turns thoughts into text is
  not Sprava's concern (dictation, the keyboard, holos, anything): Sprava receives text, and documents and images
  through an adaptation layer per type of input. No producer is privileged and none is a dependency: the
  capture-event format is Sprava's own inbound contract, which any adapter may write. The adaptation layer is
  drafted in `docs/adaptation-layer.md` (open).
- **P13 decided (2026-10-07, by the author).** Intake is per binder: each binder's own `intake/` folder, where
  files arrive from downloads, from an email monitor, or because the person dropped them. A file there is read
  in full at once (OCR, the deterministic steps that simplify classification, then a model that understands it)
  and filed with Undo (D2, D24). A file that is very unusual, or looks like an error, is held for the person.
- **P14 decided (2026-10-07, by the author).** Input types are text, images, office documents and PDFs. Audio
  and video are not part of Sprava.
- **P15 decided (2026-10-07, by the author).** Intake accepts files, not only text, from the person and from
  outside programs alike.
- **P16 decided (2026-10-07, by the author).** Sprava always records how a piece of information was obtained: by
  email, a scanned paper letter, a download, a note. The person usually says so, and Sprava keeps what they say.
  This is the channel; the tool used to produce text is left out (P12).
- **P17 decided as a direction (2026-10-07, by the author).** Integrations are plugins attached to a binder:
  **importers** bring material from an outside system (mail from one label, updates from a work-tracking
  account) into the binder's `intake/`; **exporters** act on approved instructions in the binder's `outgoing/`
  (first: an email draft the person reviews and sends, D13). Built-in plugins first: IMAP with a filter,
  monday.com, and an IMAP draft exporter. Drafted in `docs/integrations.md`.
- **P18 decided (2026-10-07, by the author).** "Binder" is the name of the thing, one folder per life project, in
  product language and in the format ("binder v0", `docs/spec/binder-v0.md`). On-disk names that carry the old
  word "teka" stay for compatibility (`meta.format: "teka"`, `.teka.lock`, the `rename_teka` op, the
  `teka-year-seq` id scheme, the `teka-dashboard` marker, the `teka` field of slices and outboxes, the
  `urn:sprava:teka:v0:` schema ids). Exporter instructions live in `outgoing/`, apart from the hub spool's
  `outbox/`.
- **P19 decided (2026-10-08, by the author).** The online surface for to-dos is Sprava's own companion: an
  installable web app (it must work on Android) backed by a relay that stores only end-to-end encrypted data.
  Not Google Tasks, not Apple Reminders. The Mac stays the source of truth; the phone views, checks off,
  snoozes and captures. The relay is portable (one small service plus an S3-compatible bucket) and becomes the
  foundation for sharing a binder and a second Mac. It comes right after the MVP. Designed in `docs/companion.md`.
- **P20 decided (2026-10-13, by the author).** Sprava owns its binders and shares them with no other program. They
  live in `~/Sprava`, a visible folder in the home folder (not `~/Documents`, which iCloud often syncs; Sprava
  refuses synced locations, architecture 2.3). New Binder creates the binder there. A binder made with lifeproj
  is imported once: Sprava copies it into `~/Sprava/<name>` and processes the copy on its own (F13); the
  original is left untouched, and Sprava never writes into it or offers to remove it. A binder stays an ordinary
  folder the person can open and browse, but its management goes through Sprava. The owner record
  (`.sprava/owner.json`) guards another Mac after a restore, and a development build beside the installed app.
  Recommended with it: a development build keeps its binders in a folder of its own and refuses `~/Sprava`.

## Licence

- **L1 open, leaning GPL-3.0.** The author has said GPL-3.0 is acceptable. It matches holos and gives the
  strongest protection against proprietary forks; the App Store conflict is moot while there is one copyright
  holder and is handled by a section-7 additional permission (the libsignal/Nextcloud pattern) adopted before the
  first outside contribution, plus a DCO or CLA. MPL-2.0 is the alternative if outside contributions come soon.
- **L2 recommended.** The spec is permissive: CC-BY-4.0 for prose, Apache-2.0 for JSON Schemas, validators and
  conformance tests, with an explicit note that no trademark rights in "Sprava" are granted.
- **L3 recommended.** The capture-event boundary stays for product reasons even under GPL-3.0: holos works alone,
  the two ship on their own cycles, and a phone app or an email intake can speak the same format.

## The binder format (`docs/spec/binder-v0.md`)

- **F1 recommended.** `catalog.json` is the truth of **state**; the op log is the truth of **history**. Every op
  records the catalog's content hash before and after (RFC 8785 canonical form). A broken chain means someone
  else edited the catalog; the runtime then records an `external_edit` op holding the diff. What Sprava writes in
  a binder is F13's list.
- **F2 recommended.** v0 keeps lifeproj's enforced rules as the core: `id`, `title`, `status`, `priority`
  required; `status` in open|waiting|blocked|done; `priority` in high|normal|low; `due` XOR `no_deadline: true`,
  `due` matching `^\d{4}-\d{2}-\d{2}$` strictly; `waiting_on` required when waiting or blocked; ids unique and
  never reused (an id in `processing_log[]` is closed); `tags` a list; `redact` a boolean; `slice_title` a
  non-empty string. Every implementation **must preserve unknown fields and unknown arrays** on rewrite.
- **F3 recommended.** v0 additions to items: `follow_up_at` (date; required when waiting or blocked; derived and
  marked as derived on import when missing), `expected_by` (optional date the other party gave), `kind` (closed
  list; required when `redact` is true), `recurrence` ({freq: monthly|yearly, day, month?}; `due` holds the next
  occurrence; completing advances it, dismissing ends it), `created_at` and `updated_at` (optional), `provenance`
  (optional: source event ids, who proposed it, who approved). `due` survives on a waiting item; "overdue"
  applies only when `status` is open.
  **Recurrence brought into Sprava (2026-11-15, by the owner).** The person sets and removes `recurrence`; no clerk,
  brain or drained change does. Done names the occurrence it completes (`occurrence_due`) and records
  `next_due = next_after(max(due, today))`; the guard refuses a Done for an occurrence the item has already moved
  past, so one Done never advances a series twice. The hub rule: no repeats on a binder lifeproj can still reach
  (binder-v0 §8.1), since lifeproj's drain closes a recurring item for good; on a binder Sprava owns, Sprava is the
  only drainer, and a hub check-off without `due` waits rather than advancing the item (binder-v0 §8.3). Dismissal
  stays as before.
- **F4 recommended.** One bucket taxonomy for the Now page, the roll-up and the brief: Overdue · Today · Next 7
  days · Later · No deadline · Nudge (waiting or blocked with `follow_up_at` today or earlier) · Waiting ·
  Recently closed (7 days).
- **F5 recommended.** Closing is mechanical: a `complete` or `drop` op moves the item from `open_items[]` to
  `processing_log[]` with `closed_at`, `action`, `source`. The slice carries items closed in the last 7 days in a
  separate `closed[]` array. A Sprava-managed catalog never holds `status: done` in `open_items[]`; import
  tolerates it.
- **F6 recommended.** `meta` additions: `format: "teka"`, `format_version: "0"` (keep `schema_version: 2` for
  lifeproj), `modules[]`, `disclosure` (full|title|kind|none; what a cross-binder view may show), `id_scheme`.
  Ids: `<binder>-<year>-<NNN>` recommended; bare ids accepted and prefixed at the slice boundary. Conformance:
  `meta.name` equals the folder basename.
- **F7 recommended.** `documents[]` minimal schema: `id`, `title`, `path` (relative, inside the binder), optional
  `date`, `kind`, `source`, `sha256`, `provenance`. `processing_log[]` entries: `at` (or `closed_at`) and
  `action`, everything else open. `entities[]`: `id`, `status`, open attributes. `ledger/`, `timeline.md` and
  `chapters/` are folder conventions, left opaque.
- **F8 recommended.** The federation profile is optional: agenda slice v1 = lifeproj's nine item fields unchanged
  plus additional fields a hub may ignore; outbox v1 keeps lifeproj's completion semantics exactly. Its use
  follows A17.
- **F9 recommended.** Not part of the format: `AGENTS.md` and `CLAUDE.md`, `.claude/`, `.agents/`,
  `catalog_check.py`, `scripts/`, `.git/`. Sprava itself never executes hooks or scripts found inside a binder.
  In a binder Sprava owns, `AGENTS.md` and `CLAUDE.md` are Sprava's own files (F14).
- **F10 recommended.** JSON conventions: UTF-8 unescaped, two-space indent, trailing newline, key
  order preserved on rewrite, canonical form (RFC 8785) only for hashing; JSON Schema 2020-12.
- **F11 open.** A structure-only survey of the author's live binders (keys, types, counts; never values) would
  confirm the `documents[]` and `processing_log[]` shapes. A script is ready; only the author should run it.
- **F12 open.** A binder's own `.git/` is tolerated and ignored. Whether its history counts as a provenance
  fallback is the author's call. Sprava's per-turn history (D24) lives outside the folder and is not this.
- **F13 decided (2026-10-13, by the author).** An import does its processing on its own. What the adoption check
  and its cards did (the survey, lossless fixes, repairs, the dashboard switch, the stamp; binder-v0 §9.4) runs
  as part of the import: ops with actor `import`, listed in an import report. An import has no Undo; to start
  over, the person removes the imported binder and imports the original again. The copy is made in a hidden
  staging folder by a background job and renamed into place only when complete, so a cancelled or crashed import
  leaves no partial binder; an unfinished staging folder is deleted for good, and a binder that would not fit is
  refused before the copy starts. Only a change that needs the person's judgement becomes a card: an item that
  breaks a rule because a value is missing (a due date or `no_deadline`, a party for a waiting item, a kind for a
  redacted item, an entity row's `status`, the v0 value of a `meta` field whose found value the v0 types reject);
  an open item whose id already closes a processing log entry; a name the binder cannot have in `~/Sprava`, which
  the person picks before the copy is made; and an item left at `status: done` with no closing date. The
  `migrate`s that add v0 keys beside legacy ones, `set_meta` for `modules` and `id_scheme`, the starting
  disclosure (`full` when the binder published slices before, else `none`) and the stamp are automatic; the
  stamp waits until the cards are settled. What Sprava itself writes in a binder it owns: `.sprava/`,
  `catalog.json` through ops, `DASHBOARD.md` and `AGENTS.md` with its one-line `CLAUDE.md` (F14), `.teka.lock`,
  `intake/_converted/`, and new files filed into document folders; beyond these it never deletes or overwrites a
  file. The binder's agent works under D23 and D24.
- **F14 decided (2026-10-13, by the author).** `AGENTS.md`, with a one-line `CLAUDE.md` that points at it, and
  `DASHBOARD.md` are Sprava's own files in every binder it owns, written at creation or import with no prompt.
  Sprava keeps its own section of `AGENTS.md` between two marker lines and rewrites only that section; the rest
  of the file is free for the person (amended by D33: not for the binder's Claude). `DASHBOARD.md` is rendered as binder-v0 §7.1 says, and an
  imported binder's hand-kept dashboard text moves into its Notes section. The files are not part of the format;
  nothing in them is executed by Sprava, and their text is data, never instructions, for the clerk (binder-v0
  §3.4), except the person's part of `AGENTS.md`, which the clerk reads as the person's filing guidance within
  D43's limits (amended by D43). Recommended with it: Sprava's section says to propose through Sprava, never to edit `catalog.json` by
  hand, to write `DASHBOARD.md` only below `## Notes`, and to run no lifeproj command; an imported binder's old
  `CLAUDE.md` and `AGENTS.md` are saved byte for byte in `.sprava/adopted/` and not carried into the new files.
- **F15 open (2026-10-13).** The format's promise to lifeproj readers. After an import lifeproj no longer touches
  a binder Sprava owns (P20). Open: whether v0 keeps lifeproj compatibility (so a binder can go back to lifeproj,
  and the hub can read its slices) or drops it; and what the import's copy leaves behind (recommended: leave out
  `catalog_check.py`, and `.claude/settings.json` when it declares hooks). Until this is decided the format does
  not change. Decided now, as a privacy floor: every hidden file or folder at the binder's top level
  (`.claude/`, `.codex/`, `.mcp.json` and the like) is set aside under `.sprava/adopted/top-level/` instead of
  copied into place, and every agent manual of binder-v0 §4.3's list, at any depth, under
  `.sprava/adopted/manuals/` (binder-v0 §9.4 step 2).

## Capture events (`docs/spec/capture-event-v0.md`)

- **C1 recommended.** The envelope: `id` (UUID; v7 recommended), `hlc` ({wall_ms, counter, node}), `device` ({id,
  name}), `source` ({app, kind: dictation|meeting|text|document|share|email, version}), `captured_at` (ISO 8601
  with offset), `locale`, `text`, optional `alt_text`, `media[]` ({kind, path or hash, bytes, seconds}),
  `people_hints[]`, `app_context`, `sensitivity` (unmarked|private), optional `binder_hint`, optional
  `supersedes`. Events are immutable; a later change produces a new event that `supersedes` the old one.
- **C2 recommended.** Transport: one JSON file per event, `<capture-root>/<device-id>/<id>.json` with media
  beside it, written atomically, never modified, never deleted by the producer. The consumer keeps its own
  cursor.
- **C3 recommended.** Derived events: `{id, kind: interpretation|proposal|filing, inputs[], producer: {tier,
  model, variant, os_build, prompt_version}, outcome, content, supersedes?}`. The clerk's typed interpretation of
  a capture is the Tier-1 derived event; proposals are built by code from interpretations and point back at them.
  Outcomes include `context_exceeded`, `guardrail`, `unsupported_language`, `refused`, `rate_limited`.

## Architecture (`docs/architecture.md`)

- **A1 recommended.** One supervised runtime: a user LaunchAgent registered with `SMAppService` from the app
  bundle, a `flock` single-instance lease, a heartbeat file, a health page in the app. Its jobs: capture watcher,
  deadline sentinel, nudge and recurrence, roll-up, backup, index maintenance, the clerk's digest, the binder
  agents' processes, and the MCP server for them. Silence is an alarm: the app shows the age of the last
  heartbeat. The runtime is a user agent (Foundation Models from a root daemon is unknown).
- **A2 recommended.** The op log and transaction guard live in the runtime; every op is validated
  against the spec before it is applied; undo appends a compensating op; external edits are detected
  on every read of the catalog.
- **A3 recommended.** The clerk is Swift on `FoundationModels`: one small task per call, guided generation into
  the interpretation schema, greedy sampling for classification, relative dates resolved by code. Retrieval
  comes from a per-binder, rebuildable SQLite FTS5 index in `.sprava/index.sqlite` (scope: D7); embeddings later.
  Never CoreSpotlight for binder content: donated items appear in the system Spotlight UI.
- **A4 recommended.** Sprava's MCP server is the tool surface of the binder's agent (conversation.md §18.5): a
  small stdio shim forwarding to the runtime over a Unix domain socket, dual-era (the 2025-11-25 handshake and
  2026-07-28 stateless). Its clients are Sprava's own agent sessions, each with a token Sprava creates and revokes
  and passes through the environment; the person registers nothing (D29). The tool list never varies per
  connection; the session's binder and that binder's `disclosure` decide what a call may return. Binder reads
  paginate. What a call may change follows D3, D23 and D24.
- **A5 recommended.** Proposal cards remain only where no binder conversation applies: a capture in the Inbox
  whose binder is unknown (D9) and an import's judgement cards (F13). A card offers approve, edit, reject; applied
  ops carry `approved_by`; undo is a compensating op. In a binder, changes apply with Undo (D2, D24).
- **A7 recommended.** An explicit inventory of what leaves the Mac, kept in the docs and the app: nothing by
  default; backup ciphertext (A11); the companion relay's ciphertext (P19); a binder's content to its agent's
  provider, per binder and opt-in (D4, D22); the agent's web requests, each listed in its turn (D23); and,
  until the hub lane ends, the hub's Google Tasks mirror (A17); and an email draft the person approved, placed in their
  mail account's Drafts folder at that moment (D41). Sprava ignores `.claude/settings.json` and the
  lifeproj routing hooks and never calls TypeSafe itself.
- **A9 recommended.** Mechanical docs are generated from a capability manifest; a `doctor` command
  checks binders and docs against reality; every hook and job is timed with a circuit breaker.
- **A10 decided (at implementation).** The MCP server is hand-rolled dual-era JSON-RPC in Swift (the official
  Swift SDK covers 2025-11-25 only), not a bundled Python or Node sidecar.
- **A11 decided (2026-10-07, by the author).** Backup is a setting, not a plugin. Binders always live in a local
  folder; a live binder inside a synced folder is not supported (architecture 2.3). Backup keeps a mirror in a
  folder the person chooses, usually one their cloud app syncs, plain or encrypted. The engine is restic,
  bundled with the app. Where the key is kept is the person's choice. Designed in `docs/backup.md`.
- **A12 decided (2026-10-07, by the author).** The mirror lives in iCloud Drive (other destinations later).
  restic snapshots are the backup's versions; the per-turn history that gives Undo in a binder is separate (D24).
  A live binder stays entirely local; a finished binder is offloaded whole and restored with one click when
  needed. Offloading requires a second, independent backup (another cloud service's folder or an external
  disk). Open items in a binder being offloaded produce a warning the person may confirm.
- **A13 decided (2026-10-12, by the author).** Sprava's own state lives in SQLite (the system `libsqlite3`), not
  in hand-written JSON files: one database per owning target in the support folder, opened without following
  links, in WAL mode, every read-change-write in one `BEGIN IMMEDIATE` transaction. `SpravaKit.StateStore` is the
  one door. Binders stay plain files; append-only logs (`jobs.log`, the capture journal) stay files. Where
  `docs/architecture.md` names a JSON state file in the support folder, this entry governs its storage.
- **A14 decided (2026-10-12, by the author).** No backward compatibility for Sprava's own state before the MVP
  ships: no readers for older formats, no migrations. Binders keep theirs (binder-v0; lifeproj, F15).
- **A15 decided (2026-10-12, by the author).** Binders are ordinary local folders. A binder not in use is
  offloaded and restored when needed, so while it is in use it is fully local. Sprava does not defend against
  slow, stalled, network or removable volumes: a read that waits on one is not a defect, and reviews do not
  report it.
- **A17 open (2026-10-13; direction set 2026-10-30).** The hub lane. lifeproj publishes and drains binders through
  a spool, and the hub mirrors them to Google Tasks (F8; architecture 11). The author, 2026-10-30: Google Tasks
  was a temporary solution; remote access comes from the companion (P19), and the overall view is Sprava's own
  (D26). So the hub lane and its Google Tasks mirror retire. Open: when, and what happens to the originals'
  registry entries. Until then Sprava neither publishes nor drains an imported binder whose original is still in
  lifeproj's registry.
- **A18 recommended (2026-10-13).** cmirror: backup is Sprava's restic mirror (A11, A12), so Sprava neither
  registers nor checks cmirror for a binder it owns, and cmirror's part ends with the hub lane (A17).
- **A19 decided (2026-10-14, by the author).** Background work is not optional. When the app starts, it checks
  that the runtime is running and starts it without asking if it is not; an action that finds it not running
  does the same and goes on. There is no Turn Off. Only the Login Items approval is left to the person, shown as
  one line with a button, never opened by itself. Each start is bounded (architecture 3.1).
- **A20 decided (2026-10-27).** Subscription tokens and email passwords survive background restarts in
  Sprava's own non-synchronized Keychain items. A provisioned runtime uses the data-protection Keychain;
  only a missing-entitlement refusal selects the Mac login Keychain for a build without the entitlement, ad-hoc or
  Developer ID (Apple TN3137). A read there says only "not found" (macOS 27, 2026-11-02), so a not-found read is
  followed by a change to the same absent item, whose refusal is the one that names the entitlement.
  Locked or damaged Keychains fail visibly. Only an explicit credential save may ask macOS to authorize
  access. No plaintext file or memory-only success substitutes for a credential that could not be saved.
  The backup key follows the same rule for its local items (2026-10-28): the login Keychain does not enforce
  ThisDeviceOnly; an ad-hoc runtime cannot reach iCloud Keychain, so opting in is refused and, with opt-out, "not
  checked" is recorded in the backup settings and shown until a store reaches it; a key re-entered after an update
  must open the mirror before it is saved (`docs/backup.md` §4).

## MVP (`docs/mvp.md`)

- **M1 recommended (scope restated 2026-10-30 from the decisions it follows).** The smallest release that proves
  "a binder that keeps itself": Shelf (create a binder, import one into `~/Sprava`, P20) → a binder page that is a
  conversation with its agent (D1, D22) beside a to-do list with plain controls (D25) → intake filed with Undo
  (P13, D2, D24) → the Inbox for captures whose binder is unknown (D9) → the cross-binder to-do list and a General
  binder (D26) → templates → backup and offload with restic (A11, A12) → Health.
- **M2 recommended.** Deferred past the MVP: the companion (P19, right after it), sync, sharing, per-binder keys,
  Private Cloud Compute.
- **M3 recommended.** A measurable success criterion: for 30 days the author's live binders stay current with no
  hand edit of `catalog.json`; every capture is filed or carded within a minute of landing; no deadline is missed
  that the catalog knew about; a stopped runtime is visible in the app within five minutes.
- **M4 decided (2026-10-15).** A binder is on the clerk's filing list until the person takes it off ("Suggest
  this binder for notes from the Inbox and the phone", under "About this binder" in its settings); one with no line
  about it is offered by its name, which never leaves the Mac (the clerk is on-device). A binder at disclosure
  `none` stays off until the person opts it in with a line they wrote (architecture 5.4). A note typed in a
  binder names that binder, and the clerk keeps it there whether or not the binder is on the list
  (capture-event-v0 §6.4 step 2, §8.1). Why: the list's only effect is routing notes written elsewhere.

## The binder conversation (`docs/conversation.md`)

- **D1 decided (2026-10-14).** A binder's main screen is a conversation with that binder, privately to it ("I
  want to come to the right specialist's office", conversation.md §1), with smooth drag and drop, import by path
  or description, questions, and tasks beside the chat. The top-level Inbox stays only for captures whose binder
  is unknown.
- **D2 decided (2026-10-14).** Documents dropped, imported, or arriving in a binder's `intake/` on their own are
  read and filed at once, reported in the conversation with Undo, with no approval card; instructions before or
  after steer or redo the filing; a question comes only for reasons code finds (conversation.md §5).
- **D3 decided (2026-10-14; revised 2026-10-30).** What applies where. Inside the binder, every change applies at
  once and the turn can be undone (D24). Class C stays in the app's own controls, never in the conversation:
  disclosure, privacy markers, names, expunge, engine and backup settings, and anything outward. Code decides the
  class from the op and its target, never a model. Document text is data, never instructions: an obligation read
  from a document is a suggestion unless the person's turn asked for it, and no log entry is written from a
  document's text. Adds `move_document`, `unfile_document` and `transfer_document` to binder-v0
  (conversation.md §6).
- **D4 decided (2026-10-14; revised 2026-10-30).** How the binder's agent runs. Claude Code or, second, Codex,
  as a long-lived session per binder (one warm process, under a lock), driven over the agent's structured
  protocol (Claude Code `-p` with stream-json, resumed by session id; Codex's `app-server` JSON-RPC), never a
  scripted terminal, in an agent home of Sprava's own per binder, so the person's own setup is never loaded and
  clearing deletes the whole home. Its role is D22's and its reach D23's. "Open in Terminal" resumes the binder's
  session in a real terminal after Sprava ends its own process on it, until the person presses Resume; its turns
  are imported into the transcript (conversation.md §4.2). Turning an agent on for a binder is made in the app's
  window and is the consent for the binder's documents, private and intake ones included.
- **D5 decided (2026-10-14; role revised 2026-10-30).** The local model is the most capable one the Mac can run,
  not Apple's on-device model, which stays the clerk. It shadows the agent (D27) and is the binder's voice only
  when no engine is connected. The runtime is a pinned llama.cpp build bundled as `llama-server`, run as the
  sandboxed helper `sprava-llm` on a Unix socket, with schema-constrained `/completion` calls. The model is chosen
  by memory from a pinned list of Apache-2.0 models (Gemma 4 E4B at 16 GB, tested; larger above), downloaded once
  with consent and checked by SHA-256. MLX is out: the Command Line Tools have no `metal` compiler.
- **D6 decided (2026-10-14).** The transcript lives in the binder, `.sprava/conversation/<YYYY-MM>.ndjson`,
  append-only, written by the runtime, listed in binder-v0 §7.2 as history. Never on the hub, the Today page, the
  companion, logs or notifications (conversation.md §3).
- **D7 decided (2026-10-14).** The per-binder index covers documents' full text in passages with page numbers,
  translations, items, log entries and the person's own lines. With no engine connected, a local answer is
  quoted passages with document and page plus at most one sentence pointing at them (conversation.md §9).
- **D8 decided (2026-10-14).** A document not in the person's language is translated at filing with Apple's
  on-device Translation framework where the pair is installed, else by the agent; the original is the document
  of record (conversation.md §9.4).
- **D9 decided (2026-10-14).** The Inbox keeps its note field for notes whose binder is unknown; in a binder the
  person types in its conversation.
- **D11 decided (2026-10-14).** Every correction the person makes to a filing (an Undo followed by their fix, or an
  edit) becomes a written filing rule in the rules part of Sprava's section of the binder's `AGENTS.md` (F14),
  read by the agent and the shadow on every filing. Rules follow a fixed grammar and steer only filing within
  the binder (conversation.md §8.1).
- **D12 decided (2026-10-14).** Sprava keeps a one-page brief per binder (parties, pending, key dates, key facts),
  read first on every job. Code writes the parts that come from the catalog; key facts are a document's own
  sentences stored verbatim with their citation and checked by code. Models read the brief as data, never as
  instructions. Recommended place: a visible `BRIEF.md`, Sprava's own file (conversation.md §8.2).
- **D13 decided (2026-10-14).** Big requests become task cards with progress, Stop and a draft at the end, each in
  its own agent session, so the conversation goes on meanwhile. Sprava never does an outward action (sending
  email, filing with a court or tax office, paying); results land as drafts in the binder's `drafts/` for the
  person to send (conversation.md §10).
- **D14 decided (2026-10-14).** Import by path or description ("include the March statement from Downloads"): the
  app window does it, as the person's direct command with the person's file permissions, leaves the original,
  and asks only when more than one file matches (conversation.md §5.2).
- **D15 recommended (2026-10-14).** The record decides what happened: the catalog, the op log and the runtime's
  request and task receipts, never a resumed session or the brief. Every agent or task change through Sprava's
  tools goes through the guard, bound to a stable id, the revision it was based on and its exact effect; a retry
  returns the earlier outcome; a changed revision is a conflict. Brief lines record their sources and are marked
  stale before any job reads them. Originals keep their bytes and id; a late Undo applies only to fields
  unchanged since; a repeated arrival is recorded on the existing document. An empty search is "no relevant
  passage was found" (conversation.md §17).
- **D16 recommended (2026-10-14).** A binder with mixed information scopes, detected at import or declared, gets
  no model at all until the person splits it. A per-binder session never gets cross-binder access
  (conversation.md §17.4).
- **D17 recommended (2026-10-14).** Sprava's tools offer named contracts for the old workflows (attachments with
  their message, arrival provenance, page and legibility coverage, page images, original beside translation,
  validation and replay, correction history, drafts, freshness); a missing capability is named, never invented
  (conversation.md §17.5).
- **D18 recommended (2026-10-27).** A verb's scores belong to the engine that earned them: model, variant and
  prompt version, as C3's `producer` records them. When any of these changes, the verb goes back on probation, its
  old scores kept beside the new ones.
- **D19 recommended (2026-10-27).** Verbs differ in whether a miss is seen. A misfiling is seen and undone; a date
  or to-do never found produces no signal. Verbs whose miss is unseen (dates found, to-dos found) are measured by
  recall as well, and are never handed down (D27).
- **D20 recommended (2026-10-27).** Small counts cannot show high accuracy: 30 right of 30 still allows a true
  error rate near 10%. Graduation counts the person's cases of a verb across all their binders for the same
  engine (D18), as counts only, never content, in Sprava's state; probation stays per binder; the bar is a lower
  confidence bound (D27).
- **D22 decided (2026-10-30, the author).** The agent is the front door. In a binder with an engine connected,
  every typed message goes to that binder's agent session: Sonnet drives, and a turn that reads a document or
  needs hard reasoning or writing runs on Opus. The local model shadows (D27) and is the voice only when no
  engine is connected (conversation.md §18.2). Why: a usable tool from the start beats a ladder of weaker models.
- **D23 decided (2026-10-30).** The agent's reach: read, write and run tools inside its binder folder and its own
  agent home, enforced by an operating-system sandbox; nothing outside them. Sprava's own files (the catalog, the
  to-do list, the brief, Sprava's dot folders) are read-only to it and change only through Sprava's tools. Web
  search and fetch are allowed: every request goes through Sprava's proxy and is listed in the turn's summary,
  and once a turn has read untrusted text a request to a domain new to the binder waits for the person's tap
  (allow once, always for this binder, deny); D42 makes every new host wait, untrusted text or not. Outward actions
  stay drafts (D13) (conversation.md §18.3).
- **D24 decided (2026-10-30; the store settled 2026-11-01).** Undo by version history: a history per binder kept outside
  the folder, in Sprava's own store of bytes by hash rather than git (a copied project's `.git` would hide its files, and
  a friend's Mac may have no git), an entry before each turn for changes since the last one and an entry after it for the
  turn's changes; Undo reverts one turn alone and names a conflict instead of overwriting a later edit; each turn ends
  with a one-line summary and Undo. Key files are never copied into it. restic stays the backup (conversation.md §18.4).
- **D25 decided (2026-10-30).** Plain controls for plain actions: done, cancel, deadline, priority, description and
  adding a to-do are controls in the to-do list, applied by code with no model. A shopping list is to-dos with a
  tag, not a separate kind (conversation.md §18.2).
- **D26 decided (2026-10-30).** No agent for the overall view. The cross-binder to-do list, the briefs and their
  sync are code, with the on-device model where wording is needed; a built-in General binder holds what fits no
  other. General is an ordinary private binder, created only when opened or first used for a note or to-do,
  beside future new binders (fresh default `~/Sprava`). A location change affects future binders, not General.
  It stays on this Mac's Shelf: removal, transfer and offload are refused before session cleanup; backups still
  work. A missing or replaced folder requires restoring the original, never silently starting an empty one.
  Remote access comes from the companion (P19) (conversation.md §18.2).
- **D27 decided (2026-10-30; method from Consultant's reading of Steve Yegge's "The Counting House").**
  Shadowing: the agent acts; for each of Sprava's structured tool calls a local model decides the same input in
  shadow, unapplied and unshown. It is scored against the person's outcome on the agent's action (accepted,
  edited, undone), never against the agent alone, and a verb hands down, agent to local model to code, when the
  Wilson lower bound of that score passes a bar set by the verb's error cost (D18, D20); a sampled share keeps
  going to the agent forever, and a rise in Undo or edits sends the verb back; unseen-miss verbs (D19) never hand
  down. Every turn and call is measured as counts only (conversation.md §18.5 to §18.7).
- **D28 decided (2026-10-30).** Engines: Claude first; Codex and Antigravity behind the same contract, each on the
  person's own subscription, routed to whichever has capacity. Open, for the sharing story: Anthropic's Agent SDK
  documentation says that, unless previously approved, third-party developers may not offer claude.ai login or
  its rate limits for their products and should use API keys; whether that covers Sprava driving the person's
  own Claude Code with their own token is to be settled before Sprava is offered to others.
- **D29 decided (2026-10-30).** The Brains page no longer registers Sprava in the person's own Claude Code. A
  person's own session can open a binder folder directly; the registration added a token to manage per Claude
  profile and nothing a folder does not give. App and CLI registration/grant paths are removed. Opening
  Assistant revokes the old fixed client capability. Personal Claude config files stay untouched because
  the old installer recorded no profile or entry provenance; Assistant explains manual entry identification.
  The private in-app Claude setup and the MCP server/runtime sessions for agent tools remain.

## Retired

Each line names what replaced the entry; its old text is in git history.

- **D30 decided (2026-11-02, by the author).** A chat reply is drawn from a small subset of Markdown, by Sprava's own
  parser and Foundation's inline Markdown, with no outside package: headings, bullet and numbered lists, code, bold,
  italics and links. The author asked that links be clickable. Nothing loads by itself: an image stays its alt text. A
  click opens only `http`, `https` and `mailto`, or shows a file inside this binder in Finder, never running it; any other
  link stays plain words. A web link that shows other words also shows its host, because a reply can repeat what a
  document told the model to write. The person's own lines, drafts and previews stay plain text.
- **D31 decided (2026-11-02, by the author).** To-dos are one list on both pages: a row at the top to add, then rows in their
  groups, with dates, priority and binder lined up in columns, and no form. The author first asked for a spreadsheet; an
  adversarial review and renders of both at both widths showed why not: most cells would be empty, a grid has no place for
  who a task waits on, a date set in a sorted grid moves the row under the cursor, and five columns do not fit a third of the
  window. Return adds; clicking away keeps a draft, so a stray click files nothing. An open row saves on Return or on moving
  away, and moves to its group only then. Items do not move between binders yet: no op does that. The note box leaves the
  binder's page; pasted lines add a task each, directly.
- **D32 decided (2026-11-02, the author).** Claude changes to-dos itself. "The Claude, the concierge that I'm talking to, should
  be able to add to-dos, mark them done or remove them. Most of the workflow is the conversation." So add, edit, complete
  and remove are tools of the person's turn that apply at once with the turn's Undo (conversation.md §18.5), and the proposal
  and its Add To-do button are gone from new replies; earlier replies keep theirs. This takes class B's tap off closing an
  item (§6.1), as §18.4 had planned for the binder's own changes. What holds a document that tries to steer it: the policy
  (only what the person asks), the turn's line naming each title, Undo, and a limit of 50 changes a turn; a model's promise
  is not a wall, so a hostile document can still get a to-do added or closed until the person reads that line. Those are
  reversible. Disclosure, deletion of a binder and anything outward stay out of reach, as before.
- **D33 decided (2026-11-02, the author).** A binder that allowed file changes keeps one continuing Claude session, on Opus,
  and Claude finds what it needs itself. "I would rather have a continuous claude session running in the background, and have
  *it* decide what file fragments to upload." Each message used to start fresh with up to 1 MiB of history and binder text; now
  the instructions never change between turns, nothing of the binder is sent ahead, and the prompt cache carries the rest. A message
  carries today's date and `DASHBOARD.md`'s revision, and only a session's first message carries earlier dialogue (the last 10
  exchanges, at most 64 KiB). A binder without that consent keeps the old way: fresh each turn, with a source pack. A turn cut short by a
  limit, a sign-in failure or a Stop leaves the session to continue; any other failure, or one in a session's first turn, starts
  the next turn fresh. The session's scope is its binder, as it was for its tools.
  The author also chose no permission prompts, leaning to the skip-permissions flag. That flag cannot be used: the CLI's restricted
  mode refuses it, and scrubbing the token from commands' environments turns it off (CLI 2.1.317). The launch keeps both and names a
  longer list of commands instead, which ask nothing of the person: file and text programs, `sed -i` and pipes included, and `find` without `-exec`.
  Nothing on the list can start another program, so `awk`, `xargs`, `env`, `sort` and shell `rg` stay off it; the agent's Grep and Glob are its `rg` and `find`. Loops, substitutions
  and redirects are refused. Allowing the whole shell also worked on an invented binder, and it would let a steered command run the CLI binary with a preload and read
  what other programs show in their environment, which the author was told and accepted for this design. The review guidelines count that as outside a brain's scope, so it
  stays off unless the author changes those guidelines. It would then be one line in `allowedTools`.
  The session keeps where things stand under Notes in `DASHBOARD.md` through a tool, `update_notes`, which replaces that section and nothing else
  and which the turn's Undo reverses unless the person changed the Notes since. `search_binder` searches the binder's index, so it sees inside PDFs where Grep cannot.
  This amends F14: `AGENTS.md` and `CLAUDE.md` are now the person's to write, closed to Claude's writes, and the session is told to
  read `AGENTS.md` as how the person works in this binder. Project settings stay off (`--setting-sources ""`), so a binder's
  `.claude` folder adds no hooks.
- **D34 decided (2026-11-02, the author).** Sprava can hold a token for each of the person's Claude accounts, by a name they give it, and can ask a
  command of theirs which to use. "For someone else who uses the tool and does not do the whole aiq story, this simply becomes
  'claude', with a single token pre-configured." So one token named `main` stays the ordinary case, and Sprava knows nothing of what the command runs. The
  command is set only from the app's window, runs outside the sandbox with no binder data for up to 10 seconds, and is never logged. It runs when a session starts or an account refuses, since
  a switch loses the prompt cache. What it prints is an account's name; nothing printed or exit 75 means none has quota; a name with no token stops the turn and says which;
  a command that fails leaves the account in use. A turn refused for its limit before any tool ran starts again on the next account; after a tool ran it does not, since it may have changed something.
  A token is saved only after one data-free turn shows it works, though an account at its limit is kept. Each shows its saved day and a reminder a month before its year ends.
- **D35 decided (2026-11-02, the author).** "When we do a 'new conversation', we should archive the previous convo *in the binder*. Export it, file it, it remains available."
  New conversation is in the conversation's "…" menu, with a quiet line, never blocking, once a session reaches about 100,000 tokens or 70% of its window, whichever comes first; Opus reports a window of a million, so the
  first figure is what fires. The order: Claude brings the Notes up to date in a last ordinary turn of up to two minutes, skipped if it cannot; the transcript is filed as a private document under `conversations/`;
  only then the session ends and the screen clears, with a link to the transcript. If filing fails nothing is cleared. The older Clear stays, for a conversation the person does not want kept.
- **D36 decided (2026-11-03, the author; amends D33).** "I accept the whole shell, yes." A binder with file changes allowed gives Claude the whole shell instead of a named list of commands, so
  redirects, loops, `awk` and `rg` work. The cost, put to the author in those words: a steered command can start other programs, run scripts, and read what other programs show in their environment, which no sandbox rule stops
  (kern.procargs2). The sandbox still holds reads and writes to the binder and the session's home, the network to the proxy, and programs to those the system or Homebrew installed. With a whole shell the sandbox also closes every system service but a short list, since a service works outside the sandbox on the caller's behalf: `open`, Finder, the clipboard, preferences and Spotlight were reachable or would have been, and are not. The review guidelines record this, so a report of the accepted part is not a finding, and a way past those walls still is.
  An audit of those walls the same day found two that did not hold, and both are now closed: the rules against listening named only IP addresses, so a command could serve a binder file from a Unix socket to a program outside, and System V shared memory let a command read and write another process's segment. Neither reached the internet, and other programs in the person's account would have had to take part.
- **D37 decided (2026-11-03, the author, on an outside design audit).** Where things sit. The conversation stays in the middle of a connected binder's page, about half the width beside the to-dos: "it's not an afterthought", and the path is the one Cursor took, from a chat in a sidebar to a chat at the centre with the files optional. A binder with no conversation gives Project the whole page, with a button to start one. The person talks to Sprava, since the engine behind it may change (D28): "Talk to Sprava", and replies labelled Sprava. A screen that discloses where data goes, or that concerns a particular account, still names the real engine and company. The app opens on Today, the To-dos page renamed, with a line for cards waiting for an OK. Backup and Assistant move to the Settings window, and Health becomes a status line at the bottom of the sidebar that turns red when something breaks, with a notice on every page. Letting Claude change files stays ticked by default when connecting.
- **D38 decided (2026-11-03, from the author's reaction to a review card: "give me your best shot at a summary and give me a
  link to the document").** A card shows the document, what its button will do, and
  only what could change the decision, each said once; its full record is under a closed Details. The buttons name their
  result for that card ("File 3 documents and add 7 to-dos"), and the other says what really happens ("Leave in intake", since a
  rejected file stays and is asked about again only if it changes). The clerk's summary is labelled as the clerk's, and a held
  file shows its reason and nothing that looks like a reading. Anything that widens privacy, changes an existing task, or says
  the list may be incomplete stays on the card. A card Sprava did not write shows only its title and lines. A card's files are
  shown in Finder, never opened by Sprava, under the rule of D30.
- **D39 decided (2026-11-04, from the author, filing waiting cards: "He should be able to detect duplicates, figure out if
  we've already filed something and generally act intelligently").** A file in intake that is an exact copy of a filed document
  gets no card, and a waiting card goes once its document is filed. A message's text may be rendered another way, so with its
  original filed its text does not count; a file added beside them does. Empty files never match.
  What counts is what the filed file holds now, so a filed document edited or gone never hides a copy. Nothing is deleted: the copy stays in intake, and
  the binder's page says how many there are. Exact bytes count, and for an email the same headers and body (amended
  2026-11-04: exact copies matched none of the author's duplicates, which were the same emails fetched or saved again).

  The same email is one whose message file (a dropped `.eml`, or the original a mail monitor keeps beside its `.md`) has
  the headers that identify it and say how it reads as a filed `.eml` holds them now, byte for byte, and the same body
  byte for byte, its line endings evened out only where they carry no data (CRLF taken as LF when no CR in the message
  stands alone and nothing in it declares the binary transfer encoding); then its rendered text does not count, as
  with an exact original, and any other file beside it must still match by its bytes. The identifying headers
  alone are not enough: anyone who received an email knows them and the sender proves nothing, so a forgery copying them,
  filed first, must never hide the real email; the body, and how it is to be read, must match too. A message is read
  whole (at most 32 MiB, its header within 64 KiB); one whose headers are missing, repeated, longer than 998 bytes or
  hold a control character has no match of this kind. A filed email edited later, header or body, or gone, no longer
  matches. Mail filed as a `.md` with no original, and every other document, has nothing of the kind to match: only its
  exact bytes count.
- **D40 decided (2026-11-06, the author: "1a", with a daily cap of 100).** In a binder connected to Claude with intake
  shared, Sprava asks Claude (Sonnet) one question about each intake document as it arrives: who wrote it, who is asked
  to do what, and what falls to the person. Its answer replaces the clerk's to-dos and summary on the card, labelled as
  Claude's. The call has no tools, runs on the binder's own connection, and sends only that document's text with code's
  verdict on whether the person wrote it, never the person's addresses (amended by D43: the person's instructions go as written). This changes when intake text leaves the Mac, not
  what may leave: the binder's Claude may already read it. Code checks every item as it checks the clerk's (the quoted
  words are in the text, the title comes from them, dates resolve), and the person approves every card. Without Claude,
  without intake shared, past 100 calls in a day, or when a call fails or runs out of time, the on-device clerk stays.
  The author accepted on 2026-11-06, after being told, that this sends intake text off the Mac as it arrives, uses their
  Claude quota, and makes unattended calls on their claude.ai login, whose subscription terms are still open (D28).
  Not chosen: opening the careful-reading queue to registered MCP brains, which lets other programs read intake.
- **D41 decided (2026-11-06, the author: "2a"; issue #592).** Sprava writes email drafts and never sends them. A draft
  is a card the person approves; only then is it appended to the Drafts folder of the binder's email account, with the
  `\Draft` flag, over the same connection and credentials that import mail, and the person sends it from their own mail
  program. Sprava has no SMTP and no IMAP command beyond what placing a draft needs. A draft on the server counts as data
  leaving the Mac when the person approves it (A7). It may attach the binder's documents, private ones included; the card
  marks each private one. Attachments are at most 18 MiB together, before encoding. The binder's conversation may propose
  a draft, and it still needs the person's approval on a card before anything is appended. Not chosen: a local `.eml`
  opened in Mail, which would not reach the person's other devices.
- **D42 decided (2026-11-16, the author: "go with your picks on all four", which took the lead's pick, sites allowed per binder with a prompt; amends D23).** A binder's Claude
  reaches the web: WebSearch on Anthropic's side, and WebFetch and the commands it runs (curl, scripts) through Sprava's
  proxy. The first time a host is used in a binder the connection is held and the conversation asks: Allow once (this
  turn), Always for this binder, Deny (this turn); no answer in 2 minutes is a Deny, and after three noes a turn stops
  asking. A host allowed when Claude asked to read it is asked about again the first time a command uses it, since a
  command can send it files. The hosts allowed always are listed per binder in the app, each with Remove. Every new host
  asks, before untrusted text as after: Sprava cannot tell when a session has read untrusted text (its binder's own files
  and earlier turns' pages are already in it), and one rule is easier to trust, so D23's "once a turn has read untrusted
  text" is gone. The model's host stays the agent process's alone. The turn's summary lists each host with the bytes
  each way; the proxy passes TLS unread past the server name, so not what was sent. Why: the author asked a binder's Claude to read an
  invoicing service's API documentation and write billing scripts, and it could not reach the web. Not chosen: full
  internet per binder, which asks nothing, so a steered command could send binder files to any host unseen. The cost of
  the pick: a host the person allowed can receive anything a command sends it, documents included. Secrets for scripts
  are designed, not built (conversation.md §18.3.2).
- **D43 decided (2026-11-16, the author: "go with your picks on all four").** The lead's pick, over keeping `AGENTS.md`
  edited by hand: an Instructions editor in the app, intake filing that follows it, and templates carrying a starting
  text, so that several generic binders can each handle intake their own way and keep their work and state where the
  person says. The person writes a binder's mission and basic rules on an Instructions tab of the binder's Project
  surface, and they live in the person's part of the binder's `AGENTS.md`, outside Sprava's marker lines (F14); no new
  file. The runtime saves them atomically, keeps Sprava's section as found, refuses when the file changed since the page
  read it, keeps the replaced file for one Undo, and records the saved text as accepted; a conversation turn's Undo never
  touches `AGENTS.md`. This amends F14: the accepted person's part is the person's filing guidance for the reader of
  intake documents (Claude under D40, or the on-device clerk); text changed outside the app is followed only once the
  person saves or confirms it on the tab. The reader may take from it which folder (one of the binder's own, one the
  text writes out whole, or either plus one new last segment), how to name the file (never as a key file), and what goes
  on the to-do list; never anything that widens what leaves the Mac, names a path outside the binder, runs anything, or
  changes privacy, disclosure or the need for the person's OK on the card. Code checks every proposed op as before.
  Claude gets the instructions only where the binder's connection allows file changes, checked again before the call
  leaves, so it may already read `AGENTS.md`; this amends D40 for the person's own addresses written in them. Sprava's
  section, `CLAUDE.md`, `DASHBOARD.md` and documents stay data. An imported binder's old manuals are brought in only
  by a button that copies them into the editor for the person to review. A template may carry a starting text, written
  at creation and accepted with it. Design: `docs/binder-instructions.md`.
- **D44 decided (2026-11-16, the author: "go with your picks on all four").** Two Macs signed in to one Apple ID, each
  running Sprava with its own binders, never share one backup repository: one Mac's weekly forget and prune could
  remove the other's snapshots. The pick was the lead's: a default folder per Mac, and setup refusing a repository
  another Mac writes to. The default mirror is `iCloud Drive/Sprava Backup/<this Mac's name>/`, chosen at setup and
  kept; renaming the Mac later moves nothing. Each repository holds a small file naming the Mac that writes to it by a
  digest of its device id. Setup refuses a repository that names another Mac; a run that finds one stops before
  anything is backed up or pruned, and the Backup page says so. Retention forgets only this Mac's snapshots (restic's
  `--host`), never another Mac's. Snapshots taken before D44 share one host, so their Mac cannot be told: the Mac that
  first marks a repository set up before D44 adopts those in it, and a takeover hands them on (the lead's follow-up,
  2026-11-16); elsewhere they are never forgotten. Continuing another Mac's backups
  from this one (a new Mac replacing an old one) is a choice the person confirms on the Backup page. Not chosen: leaving
  it to the person to pick separate folders.
- **D45 decided (2026-11-25, the author: "1a").** The binder's Claude keeps the document record for what a drop does
  not cover. Drag and drop stays the way documents arrive ("this should not be a problem at all, as long as we're able
  to drag and drop documents directly into the app"). The conversation gets tools to catalogue a file it wrote in the
  binder, rename or refile a document, correct a record and add a log entry, each an op through the guard, applied in
  the turn as the to-do tools are (D32) and undone with it; this amends D3's classes for these ops. A log
  entry stays when its turn is undone, and the turn's line says so (the author, 2026-11-26: "logs are for traceability"). `catalog.json` stays closed to its file tools. Not chosen: leaving
  every catalog change to a drop or the person's own hand (`docs/plan-2026-11-25.md`, Track D).
  As built (2026-11-26): the file the conversation catalogues is filed where it sits, so its undo is `unfile_document`
  without `to`, which removes the record and leaves the file; binder-v0 6.3 and 6.10 gained that form. Returning a file
  to `intake/`, the undo of a filing by drop, still waits for the intake hold (binder-v0 6.9) and binder admission
  (7.2.2), neither built.
- **D46 decided (2026-11-25, the author: "Why can't we learn? We should be able to learn"; "2a" twice).** A binder
  learns from its work. Its Claude proposes a rule with a tool; the proposal is a card (Accept, Edit, Dismiss), never
  applied in the turn. Accept appends the rule, dated, under a `## Learned rules` heading in the person's part of
  `AGENTS.md`, by D43's save path, where the person can edit it. This amends D11: a rule learned from a correction goes
  to the person's part as plain words, through the same card, where D11 put it in Sprava's section in a fixed grammar.
  Claude still cannot write `AGENTS.md`. Not chosen: Claude editing Instructions itself; a separate list Sprava keeps
  (Track L).
- **D47 decided (2026-11-25, the author: "3a+b as iteration"; "1a" for the export).** Automation grows by iteration.
  A binder automates itself with scripts its Claude writes and runs in a turn (D36). What recurs, or what it cannot
  do, becomes a suggestion: a card the person approves in the source binder, which then lands in a built-in
  Improvements binder. The author: "The Sprava itself could have a binder for its self-improvement features", distinct
  from General, which is the quick list for what belongs to no large binder. Sprava adds candidates from counts alone.
  An Export button writes the approved suggestions to a file for the development loop; development sessions never read
  the Improvements binder. A release then ships the add-on as a built-in importer or exporter (P17). Not chosen:
  per-binder plugins loaded at run time; development sessions reading the binder (Track I).
  As built so far (2026-11-26): the built-in binders are a short list in `Shelf` (`BuiltInBinder.Kind`: General, then
  Improvements), each bound by its own key in the one store and made on first use by `general_binder` or
  `improvements_binder`. Either stays on this Mac's Shelf: it is never removed, transferred or offloaded.
  The suggestion (`SuggestionCard`, `ClaudeSuggestionTool`): the conversation's `suggest_improvement` writes a card
  in its own binder with a title, what was attempted, what stood in the way, and a script's text when one is named.
  A script is read when the card is made: a path inside the binder with no hidden segment and no link on the way,
  under `scripts/` or named as a script, never under `intake/`, never a key file, at most 32 KiB. The card lists as
  kind `suggestion` with the whole text, and warns when the text looks like it holds a key. `send_suggestion` is the
  person's approval: the text, or their edit of it, becomes an open to-do in Improvements (made then, on first use),
  and the source binder keeps a log entry with none of the text. The ordinary approve refuses the card. In the app
  the card shows the title and the whole text in a box that scrolls, with Send to Improvements, Edit and Dismiss;
  Edit makes the text an editor, and an edit left unsent holds quit as other unsaved work does.
  Export (`export_suggestions`): the Improvements row's menu on the Shelf has Export Suggestions, which opens a save
  panel; the runtime writes the suggestions that are open to-dos in Improvements to that one Markdown file, each
  title as a heading and its text, exactly as approved, in a fenced block longer than any run of backticks in it;
  one line break is always added before the closing fence, so whether the text ends in a line break survives. The
  file is written for the person alone (mode 0600), also when it replaces one.
  Only to-dos a suggestion card made are written. The file is never written inside a binder or Sprava's own folder,
  over anything but an ordinary file, or through a link, and nothing in Improvements changes.
  Counts (`ImprovementCounts`, `runtime/improvement-counts.sqlite`): at a turn's end Sprava adds, for that binder,
  the sites refused in the turn and the scripts its commands started. A binder is kept as a hash of its folder's
  path and a script as a hash of its path, so the counts hold no path, host, command or text. A script counts once
  a turn, when a command starts it (the first word of a part of the command, or what an interpreter is given;
  reading it starts nothing) and it is one a card may carry. At a script's 5th counted turn, and once more at its
  25th, Sprava writes a suggestion card of its own for it (`ClaudeScriptRuns`), with the script's text, for the
  person to edit, send or dismiss like any other. Not counted yet: commands the sandbox refused and files held,
  since nothing reports either by code today.
  Closing with a release (`BuiltSuggestions`, `close_built_suggestions`): Export writes a code above each
  suggestion's text, `S-` and ten hex digits from the id of the card that made it, and the issue made from it keeps
  the code. The change that builds a suggestion adds a line to the table in `BuiltSuggestions`: the code and the
  release's note. When the app starts it sends `close_built_suggestions`; for each open to-do in Improvements whose
  code this build lists, the runtime writes a card there, "Built into Sprava: <title>", that closes the to-do as done
  with the note. The person approves it; a card they rejected does not come back. The author chose nothing here
  beyond "closed with the release's note": the card, in place of closing without asking, is this note's choice,
  because only the person's own acts and approved cards change a binder.
- **D48 decided (2026-11-25, the author: "we should be able to read back the draft and figure out what we're sending
  or have sent"; "3a").** The outgoing mail exporter reads a placed draft back and compares it with what was approved;
  finds the sent copy, compares it, and offers to file it, log it and set the to-do waiting; and marks a draft that has
  gone stale. It searches the Sent folder only for drafts it placed; this amends D41, which allowed no IMAP command
  beyond placing. What it does on a match is a card. Sending stays the person's (D13, D41). Not chosen:
  importing all sent mail (Track M).
- **D49 decided (2026-11-26, the author: "go with a", the whole of it; proposed by the lead on 2026-11-25, answering
  "Do you have a specific suggestion to implement this as a feature?").** Reading coverage, the page and legibility part of D17: the OCR step keeps its confidence; code
  grades each page good, poor or unreadable; the filing card, Explore and a per-binder list show what was not fully
  read, and the person can mark a page as read by them or type what it says; every search result names the documents
  it could not read; a folder marked "keep as is" is never carded. Not chosen: leaving out the person's typed
  reading of a page, the largest part (Track E).
- **D50 decided (2026-11-27, the author: "I think we want the lowest friction workflow. Like, this is mostly personal
  use application. We can tighten security later if we have to. But for now, let it just pull in the environment.").**
  A binder's commands run with the person's shell environment: what their login shell exports, read when a
  conversation starts, without the names Sprava sets itself for the session (the path, the home, the proxy, the
  agent's own account) and without what describes the terminal it was read in. Why: the first binder started in Sprava
  needed a transcription service's key for a script, and the session's empty environment blocked it. The person
  installs the programs a binder needs and keeps keys where they already do; Sprava does not stand between a script
  and them. How: the values go in a file in the session's home that the CLI runs before each command, because the
  CLI's own scrub takes key-like names out of what commands inherit; they are in no process's environment or
  arguments, and the agent process itself does not get them. The cost, accepted: the binder's Claude can read every
  value, and a steered command can send one to any site that binder allows for commands. Not chosen now: the
  placeholder of conversation.md §18.3.2, where a value never reaches the session, kept as the way to tighten this;
  naming the variables binder by binder, which asks for setup in every binder.
- **P6, P7, C4** (holos as the capture producer, and its mapping): replaced by P12; holos is one adapter among many.
- **P21** (a manager agent, open): settled by D22 (an agent per binder) and D26 (no agent for the overall view).
- **A6** (encryption through cmirror): replaced by A11 and A12.
- **A8** (hub coexistence: publishing slices and draining the outbox): replaced by A17.
- **A16** (no clerk filing list): reversed by M4 two days later.
- **D10** (earned autonomy of a local front desk reviewed by the back office): replaced by D27.
- **D21** (checking the back office as a reviewer; fast confirmations not counted): replaced by D27, where the
  person's outcome is the reference.
