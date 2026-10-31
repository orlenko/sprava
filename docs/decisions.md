# Decisions log

> Started 2026-10-06. One line per decision, newest additions at the end of each section. Status:
> **decided** (in the handoff or by the author) · **recommended** (by the planning session; it stands
> until the author overrides it) · **open** (needs the author). Drafts in `docs/spec/`,
> `docs/architecture.md` and `docs/mvp.md` follow this log and cite entries by number.

## Product and scope

- **P1 decided.** A fully local Mac app. No subscription required. Three tiers: Tier 0 the structured
  organizer with no model; Tier 1 the on-device clerk; Tier 2 an optional "brain" that connects over
  MCP. Apple's Private Cloud Compute is not a tier: it is only available to App Store apps enrolled in
  the Small Business Program with a managed entitlement, so it stays out unless distribution changes.
- **P2 recommended.** macOS 27 only, Apple silicon only. The clerk is designed for a **4,096-token**
  budget and reads `SystemLanguageModel.contextSize` at runtime (8,192 on M3-or-later Macs with 12 GB,
  which run the 20B-sparse "Core Advanced" model; 4,096 on M1/M2, which run the 3B "Core" model).
- **P3 recommended.** The product uses the Swift `FoundationModels` framework directly. The `fm` CLI
  and Apple's Python SDK are developer tools only (`fm` needs a one-time `sudo fm license`, cannot
  drive tool calls through `fm serve`, and its legal notice forbids programmatic use beyond what is
  expressly permitted; the Python SDK needs full Xcode at install time). The local open-model fallback
  is a `LanguageModel` conformer (`CoreAILanguageModel` or `MLXLanguageModel`) behind the same
  `LanguageModelSession` code, so the seam costs nothing; shipping a fallback model is deferred.
  **Revised by D5 (2026-10-14):** a local open model is the binder conversation's front desk.
- **P4 recommended.** Distribution: a Developer ID notarized DMG first (hardened runtime, not
  sandboxed, the holos precedent). The Mac App Store later, only once the licence route is settled.
- **P5 recommended.** Tier 1 scope: one capture or one short document at a time. Normalize, split
  into items, extract dates/amounts/people, pick a binder from a closed list (or "not sure"), check
  duplicates against a handful of retrieved candidates, title and date a short document, draft a
  one-line nudge for a waiting item. Not Tier 1: reconciling a binder, cross-referencing documents,
  drafting letters. The honest pitch is "the clerk files; the brain thinks".
- **P12 decided (2026-10-07, by the author).** Sprava is input-agnostic. How a person turns thoughts into
  text is not Sprava's concern: built-in accessibility dictation, the keyboard, a commercial tool such as
  WisprFlow, holos, anything. Sprava receives text. It will also receive documents, images and videos,
  through an adaptation layer that quickly establishes the ingestion protocol for each type of input.
  No producer is privileged and none is a dependency: the capture-event format is Sprava's own inbound
  contract, which any adapter may write, and holos is at most one adapter among many. Supersedes P6, P7
  and C4 as dependencies; the adaptation layer is drafted in `docs/adaptation-layer.md` (open).
- **P13 decided (2026-10-07, by the author).** Intake is per binder: each binder's own `intake/` folder,
  where files arrive from downloads, from an email monitor, or because the person dropped them. A file there
  is processed right away, and processing means reading it in full: OCR the whole thing, run the
  deterministic steps that simplify classification, then the local model classifies and understands it (a
  new governing document, something that needs an action such as a reply, reference material, or something
  else). A smarter model follows up when that is warranted. A file that is very unusual, or that looks like an
  error, is held for the person instead. Supersedes the MVP's code-only intake cards that read no text.
  **Revised by D2 (2026-10-14):** what is read is filed at once with Undo, not offered as a card.
- **P14 decided (2026-10-07, by the author).** Input types are text, images, office documents and PDFs. Audio
  and video are not part of Sprava.
- **P15 decided (2026-10-07, by the author).** Intake accepts files, not only text, from the person and from
  outside programs alike.
- **P16 decided (2026-10-07, by the author).** Sprava always records how a piece of information was
  obtained: it came by email, the person scanned a paper letter, it was downloaded, the person told Sprava in
  a note. The person usually says so, and Sprava keeps what they say. This is the channel the information
  came through; it is not the tool the person used to produce text, which P12 leaves out.
- **P17 decided as a direction (2026-10-07, by the author).** Integrations are formalized as plugins attached
  to a binder: **importers** bring material in from an outside system (mail from one label, updates from a
  work-tracking account) into the binder's `intake/`; **exporters** act on approved instructions in the
  binder's `outgoing/` (first: create an email draft the person reviews and sends; P18 renamed the
  folder from `outbox/`). Built-in plugins first: IMAP with a filter (reusing `imap-extract`),
  monday.com, and an IMAP draft exporter. Drafted in `docs/integrations.md`; scope (MVP or after) open.
- **P18 decided (2026-10-07, by the author).** One term: "binder" replaces "teka" as the name of the
  thing, one folder per life project, in product language and in the format alike. The format is
  "binder v0" (`docs/spec/binder-v0.md`). lifeproj and earlier drafts said "teka"; on-disk names that
  carry the old word stay as they are for compatibility (`meta.format: "teka"`, `.teka.lock`, the
  `rename_teka` op, the `teka-year-seq` id scheme, the `teka-dashboard` marker, the `teka` field of
  slices and outboxes, the `urn:sprava:teka:v0:` schema ids). The binder folder for exporter
  instructions is `outgoing/`, so it does not collide with the hub spool's `outbox/`, which keeps its
  name. Supersedes the format-term part of P11.
- **P19 decided (2026-10-08, by the author).** The online surface for to-dos is Sprava's own companion: an
  installable web app (it must work on Android; the author's phone is not an iPhone) backed by a relay that
  stores only end-to-end encrypted data. Not Google Tasks, not Apple Reminders. The Mac stays the source of
  truth and the only place changes are approved; the phone views, checks off, snoozes and captures. The relay
  is portable (one small service plus an S3-compatible bucket) and becomes the foundation for sharing a binder
  and a second Mac. It comes right after the MVP. Designed in `docs/companion.md`.
- **P6 superseded by P12.** Capture comes from holos through a versioned capture-event format. Sprava never
  links holos code and never reads holos's private file layout as its contract.
- **P7 superseded by P12.** holos is the **producer**: it writes one immutable capture-event file per
  finished dictation (and per saved meeting) into a capture folder the user chooses. Why not read
  holos's files: `dictations.jsonl` has no cursor and is rewritten in place, the retention sweep
  deletes records and audio after 7 or 30 days, a sandboxed reader would need a folder grant, and Apple
  announced tighter Full Disk Access controls on 2026-10-02. Until holos ships the hook, a
  developer-only importer may read `voiceislocal history list --json` and `session export --format json`.
- **P8 recommended.** Languages in v1: English and French (Apple's on-device model supports 24
  locales including en-CA and fr-CA). Ukrainian is not supported by Apple's model; it needs the
  open-model fallback. **Open:** does Ukrainian matter for v1?
- **P9 decided (2026-10-31, by the author).** Sprava supports any personal project. Templates are editable files
  outside source code, containing folder structure, an undated checklist and a project guide for filing, search
  and preparation. The app discovers and previews them; each created binder retains its own copy. Shipped
  examples do not define a fixed set of project types. No inferred statutory deadline rules.
- **P10 decided (2026-10-07, at implementation).** SwiftUI with AppKit where needed, using
  `ObservableObject` rather than the `@Observable` and `@State` macros: the Command Line Tools ship no
  SwiftUI macro plugin, so macro-based SwiftUI does not compile here. A hidden `--snapshot` option
  renders the window offscreen with invented binders for layout checks.
- **P11 recommended.** Names. "Osavul" stays a private codename: an existing AI company filed
  OSAVUL in classes 9 and 42 in the EU, the UK and the US the week of 2026-09-29. The cross-binder
  view needs another public name. "teka" is no longer a term (P18 replaced it with "binder"), and it
  was never to be an app name (Teka Industrial holds the word for appliances in many countries and
  ships a "Teka Home" app; its EU class-9 mark covers irons and vacuum cleaners, not software).
  "Sprava" has no live mark in classes 9/42 in the US, Canada or EU, but npm `sprava`, sprava.ai,
  sprava.dev and two iOS apps use the name; sprava.app, sprava.io and sprava.ca were free on
  2026-10-06. Get a clearance opinion before announcing. Not legal advice.
- **P20 decided (2026-10-13, by the author).** Sprava owns its binders and shares them with no other program.
  They live in `~/Sprava`, a visible folder in the home folder (not `~/Documents`, which iCloud often syncs;
  Sprava refuses synced locations, architecture 2.3). New Binder creates the binder there and no longer asks
  where. A binder made with lifeproj is imported: Sprava copies it into `~/Sprava/<name>` and processes the
  copy on its own (F13). Importing happens once. The original is left untouched as a fallback, and Sprava never
  writes into it or offers to remove it.
  A binder stays an ordinary folder the person can open and browse, but its management goes through Sprava.
  Supersedes adoption in place (F1, M1, `docs/mvp.md` §2.1 and feature 1's "Adopt a folder", binder-v0 §9.1)
  and lifeproj coexistence for the binders Sprava owns: lifeproj as a second writer (mvp.md §6), the lifeproj
  change of binder-v0 §9.8 and architecture 13 item 31, "an implementation never edits the manual" and the
  dashboard switch card (both now F14). The owner record (`.sprava/owner.json`) stays for what it still
  guards: another Mac after a restore, and a development build beside the installed app. Recommended with it:
  a development build keeps its binders in a folder of its own and refuses `~/Sprava`, in place of today's
  refusal of folders in lifeproj's registry; a binder already adopted in place is imported like any other,
  its `.sprava/` history coming with the copy. The hub lane, cmirror registration and the lifeproj side of
  the format are open (A17, A18, F15).
- **P21 open (2026-10-13).** A manager agent. In lifeproj, Osavul (P11) was the top-level agent session that
  managed all binders. Sprava has no equivalent: the clerk only files notes, and brains only propose. The
  author has floated a per-binder agent that keeps its binder's `AGENTS.md` (F14), with hints from a top-level
  manager. Not decided: whether Sprava has such agents, what they may change (Sprava's section of `AGENTS.md`
  only, or proposals too), and how they relate to the review queue (A5) and to brains (A4).

## Licence

- **L1 open, leaning GPL-3.0.** The author has said GPL-3.0 is acceptable. GPL-3.0 matches holos and
  gives the strongest protection against proprietary forks of the runtime; the App Store conflict is
  real for GPL and LGPL alike, is moot while there is one copyright holder, and is handled by the
  libsignal/Nextcloud pattern (a section-7 additional permission for App Store distribution) adopted
  before the first outside contribution, plus a DCO or CLA. MPL-2.0 is the alternative if outside
  contributions are expected soon (file-level copyleft, App Store-clean executables, no CLA needed).
- **L2 recommended.** The spec is permissive: CC-BY-4.0 for prose, Apache-2.0 for JSON Schemas,
  validators and conformance tests (express patent grant, trademark exclusion; what MCP, OpenAPI and
  CloudEvents use), with an explicit note that no trademark rights in "Sprava" are granted.
- **L3 recommended.** Under GPL-3.0 the "must not link holos" rationale disappears, but the
  capture-event boundary stays for product reasons: holos works alone, the two ship on their own
  cycles, and a phone app or an email intake can speak the same format.

## The binder format (`docs/spec/binder-v0.md`)

- **F1 recommended (replaces the handoff's candidate).** `catalog.json` is the truth of **state**; the
  op log is the truth of **history**. Every op records the catalog's content hash before and after
  (RFC 8785 canonical form). A broken chain means someone else edited the catalog; the runtime then
  records an `external_edit` op holding the diff. Sprava **adopts a binder in place**: it never imports
  into a store, converts nothing, and owns only `.sprava/` (the op log, index, cursors), `catalog.json`
  (through ops) and the regenerated `DASHBOARD.md`. Everything else in the folder is left alone.
  **Superseded in part by P20 and F13 (2026-10-13):** Sprava imports a binder into `~/Sprava` instead of
  adopting it in place, and F13 replaces the write list. The rest of F1 stands.
- **F2 recommended.** v0 keeps lifeproj's enforced rules as the core: `id`, `title`, `status`,
  `priority` required; `status` in open|waiting|blocked|done; `priority` in high|normal|low; `due`
  XOR `no_deadline: true`, `due` matching `^\d{4}-\d{2}-\d{2}$` strictly; `waiting_on` required when
  waiting or blocked; ids unique and never reused (an id in `processing_log[]` is closed); `tags` a
  list; `redact` a boolean; `slice_title` a non-empty string. Every implementation **must preserve
  unknown fields and unknown arrays** on rewrite (schemas use `additionalProperties: true`).
- **F3 recommended.** v0 additions to items: `follow_up_at` (date; required when waiting or blocked;
  on import of an existing binder a missing value is derived and marked as derived), `expected_by`
  (optional date the other party gave), `kind` (closed list; required when `redact` is true; optional
  otherwise), `recurrence` ({freq: monthly|yearly, day, month?}; `due` holds the next occurrence;
  completing advances it, dismissing ends it, as the hub does today), `created_at` and `updated_at`
  (optional), `provenance` (optional: source event ids, who or which tier proposed it, who approved).
  `due` **survives** on a waiting item (the handoff's "plus", not the brainstorm's "instead of");
  "overdue" applies only when `status` is open.
- **F4 recommended.** One bucket taxonomy for the Now page, the roll-up and the brief: Overdue ·
  Today · Next 7 days · Later · No deadline · Nudge (waiting or blocked with `follow_up_at` today or
  earlier) · Waiting · Recently closed (7 days). It replaces the dashboard's four and the brief's six.
- **F5 recommended.** Closing is mechanical: a `complete` or `drop` op moves the item from
  `open_items[]` to `processing_log[]` with `closed_at`, `action`, `source`. The slice carries items
  closed in the last 7 days in a separate `closed[]` array so the hub learns of closures. A
  Sprava-managed catalog never holds `status: done` in `open_items[]`; a lifeproj binder may, and import
  tolerates it.
- **F6 recommended.** `meta` additions: `format: "teka"`, `format_version: "0"` (keep
  `schema_version: 2` for lifeproj), `modules[]`, `disclosure` (full|title|kind|none; what the
  cross-binder view may show), `id_scheme`. Ids: `<binder>-<year>-<NNN>` recommended; bare ids accepted
  and prefixed at the slice boundary exactly as lifeproj does. Conformance: `meta.name` equals the
  folder basename.
- **F7 recommended.** `documents[]` minimal schema: `id`, `title`, `path` (relative, inside the
  binder), optional `date`, `kind`, `source`, `sha256`, `provenance`. `processing_log[]` entries: `at`
  (or `closed_at`) and `action`, everything else open. `entities[]`: `id`, `status`, open attributes.
  `ledger/`, `timeline.md` and `chapters/` are folder conventions in v0, described and left opaque
  (import without loss means not touching them).
- **F8 recommended.** The federation profile is optional: agenda slice v1 = lifeproj's nine item
  fields unchanged plus additional fields (`format_version`, `closed[]`, `kind`, `follow_up_at`) that
  a hub may ignore; outbox v1 keeps lifeproj's completion semantics exactly (raw or prefixed id match,
  `done|dropped`, catalog written before the ACK, unknown completions linger). The briefs lane is an
  informative annex, not a contract.
- **F9 recommended.** Not part of the format: `AGENTS.md` and `CLAUDE.md` (operating manuals,
  informative), `.claude/`, `.agents/`, `catalog_check.py`, `scripts/`, `.git/`. An implementation
  must never execute hooks or scripts found inside a binder, and must tolerate and ignore all of these.
  **Revised by F14 (2026-10-13):** in a binder Sprava owns, `AGENTS.md` and `CLAUDE.md` are Sprava's own
  files. They are still not part of the format, and nothing in them is executed.
- **F10 recommended.** JSON conventions: UTF-8 unescaped, two-space indent, trailing newline, key
  order preserved on rewrite, canonical form (RFC 8785) only for hashing; JSON Schema 2020-12.
- **F11 open.** A structure-only survey of the author's live binders (keys, types, counts; never
  values) would confirm the `documents[]` and `processing_log[]` shapes and the checker generation
  per binder. A script is ready; only the author should run it.
- **F12 open.** The handoff says binders use local git; lifeproj scaffolds none by design. v0 tolerates
  and ignores `.git/`. Whether git history should count as a provenance fallback is the author's call.
- **F13 decided (2026-10-13, by the author; revises F1).** An import does its processing on its own. What the
  adoption check and its cards did (the survey, lossless fixes, repairs, the dashboard switch, the stamp;
  binder-v0 §9.4) runs as part of the import: ops with actor `import`, listed in an import report, not cards the
  person works through. An import has no Undo: some of these ops (`migrate`, `complete`) cannot be undone one
  by one, and discarding the copy is safe only while the whole original is intact, which Sprava cannot keep
  checking. To start over, the person removes the imported binder and imports the original again.
  The copy is made in a hidden staging folder by a background job and renamed into place only when complete,
  so a cancelled or crashed import leaves no partial binder; an unfinished staging folder is deleted for good,
  not moved to the Trash, and a binder that would not fit is refused before the copy starts. Only a change
  that needs the person's judgement becomes a card: an item that breaks a rule because a value is missing (a due date or `no_deadline`, a party
  for a waiting item, a kind for a redacted item, an entity row's `status`, the v0 value of a `meta` field whose
  found value the v0 types reject), since an import cannot invent one; an open item whose id
  already closes a processing log entry, which may be a duplicate or an item reopened by hand; and a name the
  binder cannot have in `~/Sprava` (not of the recommended shape, or taken by another binder), which the person
  picks before the copy is made; and an item left at `status: done`, whose closing date lifeproj never
  recorded, so the person gives it before the item is closed. The `migrate`s that add v0 keys beside
  legacy ones, `set_meta` for `modules` and `id_scheme`, the starting disclosure (`full` when the binder published slices before, else
  `none`) and the stamp are automatic; the stamp waits until the cards are settled. The write list for a
  binder Sprava owns replaces F1's: `.sprava/`, `catalog.json` through ops, `DASHBOARD.md` and `AGENTS.md`
  with its one-line `CLAUDE.md` (F14), `.teka.lock`, `intake/_converted/`, and new files filed into document
  folders. Beyond these it never deletes or overwrites a file. Settles binder-v0 §12 questions 7 and 16 (its
  first part) and architecture 13 item 36.
- **F14 decided (2026-10-13, by the author; revises F9 for the binders Sprava owns).** `AGENTS.md`, with a
  one-line `CLAUDE.md` that points at it, and `DASHBOARD.md` are Sprava's own files in every binder it owns,
  written at creation or import with no prompt. Sprava keeps its own section of `AGENTS.md` between two marker
  lines and rewrites only that section; the rest of the file is free for the person or an agent. `DASHBOARD.md`
  is rendered as binder-v0 §7.1 says from the start, and an imported binder's hand-kept dashboard text moves
  into its Notes section, as §7.1 describes for the switch. The app no longer shows the "Dashboard and manual"
  rows (Preview, Let Sprava Keep It, Copy Addendum). Supersedes the dashboard switch card (binder-v0 §7.1,
  §9.4 step 2), the paste-in addendum and "an implementation never edits the manual" (binder-v0 §9.8; mvp.md
  feature 10 and question 13). The files are still not part of the format; nothing in them is executed, and
  their text is data, never instructions, for the clerk (binder-v0 §3.4). Recommended with it: Sprava's section
  carries what the addendum said (propose through Sprava, never edit `catalog.json` by hand, write
  `DASHBOARD.md` only below `## Notes`, run no lifeproj command); an imported binder's old `CLAUDE.md` and
  `AGENTS.md` are saved byte for byte in `.sprava/adopted/` and not carried into the new files, because a
  lifeproj manual tells agents to run `lifeproj publish` and to edit `catalog.json` by hand (the original
  folder keeps them too).
- **F15 open (2026-10-13).** The format's promise to lifeproj readers. binder-v0 keeps lifeproj's enforced rules
  as its core (F2), names lifeproj as its second implementation (binder-v0 §1.1), and keeps lifeproj's slice and
  outbox shapes (F8); A13 and A14 keep binders readable by lifeproj. After an import lifeproj no longer touches
  a binder Sprava owns (P20). Open: whether v0 keeps that promise (so a binder can go back to lifeproj, and the
  hub can read its slices) or drops it; and what the import's copy leaves behind. Recommended for the second:
  leave out `catalog_check.py`, and `.claude/settings.json` when it declares hooks, which binder-v0 §8.1 and
  §9.2 step 12 treat as marks of a lifeproj binder and as a channel off the Mac; copy everything else. Until
  this is decided the format does not change. Decided now, because it is a privacy floor: every hidden file or folder at the
  binder's top level (`.claude/`, `.codex/`, `.mcp.json` and the like) is set aside under
  `.sprava/adopted/top-level/` instead of copied into place, and every agent manual of binder-v0 §4.3's list,
  at any depth, under `.sprava/adopted/manuals/` (binder-v0 §9.4 step 2).

## Capture events (`docs/spec/capture-event-v0.md`)

- **C1 recommended.** The envelope: `id` (UUID; v7 recommended), `hlc` ({wall_ms, counter, node}),
  `device` ({id, name}), `source` ({app, kind: dictation|meeting|text|document|share|email,
  version}), `captured_at` (ISO 8601 with offset), `locale`, `text`, optional `alt_text` (what was
  heard before fixes), `media[]` ({kind, path or hash, bytes, seconds}), `people_hints[]` ({name,
  external_id}), `app_context` ({app}), `sensitivity` (unmarked|private), optional `binder_hint`,
  optional `supersedes`. Events are immutable; a later change in the source produces a new event
  that `supersedes` the old one.
- **C2 recommended.** Transport: one JSON file per event, `<capture-root>/<device-id>/<id>.json`
  with media beside it, written atomically (temp + rename), never modified, never deleted by the
  producer. The consumer keeps its own cursor. Append-only, so a phone inbox syncs without conflicts.
- **C3 recommended.** Derived events: `{id, kind: interpretation|proposal|filing, inputs[],
  producer: {tier, model, variant, os_build, prompt_version}, outcome, content, supersedes?}`. The
  clerk's typed **interpretation** of a capture is the Tier-1 derived event; proposals (op batches)
  are built by code from interpretations and point back at them. Outcomes include
  `context_exceeded`, `guardrail`, `unsupported_language`, `refused`, `rate_limited`.
- **C4 superseded by P12** (kept as one possible adapter's mapping, not a commitment). holos mapping: a dictation becomes one event (`text` as written, `alt_text` as
  heard, app name, locale, duration, audio copied before the retention sweep); a meeting becomes one
  event whose text is the labelled transcript from `exports/transcript.json`, with the summary, key
  points and action items as derived events (`producer: holos`, `model: apple-on-device`), speakers
  as `people_hints` with holos profile ids, markers and gaps kept; a meeting's version is
  (transcriptID, runID, edits generation, names digest), and a later change supersedes.

## Architecture (`docs/architecture.md`)

- **A1 recommended.** One supervised runtime: a user LaunchAgent registered with `SMAppService`
  from the app bundle, a `flock` single-instance lease, a heartbeat file, a health page in the app.
  Its jobs: capture watcher, deadline sentinel, nudge and recurrence, roll-up, backup, index
  maintenance, headless Tier-1 digest, the MCP daemon. Silence is an alarm: the app shows the age of
  the last heartbeat. Scheduling by launchd intervals or `NSBackgroundActivityScheduler`
  (`BGTaskScheduler` does not exist on macOS). Foundation Models from a root daemon is unknown, so
  the runtime is a user agent.
- **A2 recommended.** The op log and transaction guard live in the runtime; every op is validated
  against the spec before it is applied; undo appends a compensating op; external edits are detected
  on every read of the catalog.
- **A3 recommended.** The clerk is Swift on the `FoundationModels` framework: one small task per
  call, guided generation into the interpretation schema, greedy sampling for classification,
  relative dates resolved by code from the capture's own timestamp. Retrieval for "a few facts" comes
  from a per-binder, rebuildable SQLite FTS5 index in `.sprava/index.sqlite`; embeddings
  (`NLContextualEmbedding`) later. Never CoreSpotlight for binder content: donated items appear in
  the system Spotlight UI, which breaks compartments.
- **A4 recommended.** The MCP surface: a small stdio shim per client (registered with a per-client
  token in its environment) forwarding to the daemon over a Unix domain socket; dual-era (the
  2025-11-25 handshake for hosted Claude, Gemini CLI and the Swift SDK era; 2026-07-28 stateless for
  Claude Code, Codex, Cursor, VS Code). Tools: reads annotated `readOnlyHint` (list binders, Now,
  search, read document, list and get items, list proposals); proposals annotated additive
  (`destructiveHint: false`) that return a handle at once and never block. Nothing is applied or
  approved over MCP; approval happens only in the app, with optional in-conversation confirmation
  through elicitation where a client renders it. Tool lists never vary per connection; per-binder
  `disclosure` and per-client scope decide what a call may return. Binder reads paginate.
  **Revised by D4 (2026-10-14)** for the binder's back-office client only.
- **A5 recommended.** The review queue: a proposal is an op batch with provenance, confidence and
  source spans; cards offer approve, edit, reject; applied ops carry `approved_by`; undo is a
  compensating op. Tier 1 and Tier 2 proposals look identical in the queue.
  **Revised by D2 and D3 (2026-10-14):** filing and additions in a binder's conversation apply with Undo.
- **A6 superseded by A11 and A12** (see `docs/backup.md`). Encryption: binders are plain folders on a FileVault disk; the offsite backup
  is ciphertext only in the cmirror model (path-addressed age blobs, encrypted manifest, archive of
  replaced blobs); the MVP calls cmirror where it is installed and a native implementation comes
  later; the root key stays the age identity file (a Keychain or Secure Enclave copy is device-bound
  and cannot be the only copy); per-binder keys are designed (binder key wrapped by the root key,
  crypto-shredding on archive) and deferred to sharing and sync.
- **A11 decided (2026-10-07, by the author; revises A6).** Backup is a setting, not a plugin. Binders always
  live in a local folder; a live binder inside a synced folder is not supported (architecture 2.3). Backup
  keeps a mirror in a folder the person chooses, usually one their cloud app syncs, plain or encrypted. The
  engine is restic, bundled with the app; existing cmirror copies are migrated by decrypting with cmirror and
  backing up again. Where the key is kept is the person's choice (a key file the person stores, for example
  in a password manager). Designed in `docs/backup.md`.
- **A12 decided (2026-10-07, by the author).** The mirror lives in iCloud Drive (Mac-only tool; other
  destinations later). No git as a versioning mechanism: restic snapshots are the versions. A live binder stays
  entirely local; a finished binder is offloaded whole and restored with one click when needed. Offloading
  requires a second, independent backup: another cloud service's folder or an external disk, whatever the
  person has. Open items in a binder being offloaded produce a warning the person may confirm. The MVP builds
  backup and offload (2026-10-08).
- **A7 recommended.** An explicit inventory of what leaves the Mac, kept in the docs and the app:
  nothing by default; backup ciphertext; Tier 2 MCP clients, per binder and opt-in; the existing hub's
  Google Tasks mirror during the transition. Sprava ignores `.claude/settings.json` and the lifeproj
  routing hooks (terminal-agent configuration, not format) and never calls TypeSafe itself.
- **A8 recommended.** Hub coexistence: for binders it manages, Sprava publishes agenda slices to
  the spool and drains the outbox with lifeproj's exact semantics; the cross-binder Today page
  replaces the hub's web lens over time; `disclosure` is enforced at the roll-up. **Open again for imported
  binders (2026-10-13): A17.**
- **A9 recommended.** Mechanical docs are generated from a capability manifest; a `doctor` command
  checks binders and docs against reality; every hook and job is timed with a circuit breaker.
- **A10 open.** The MCP server's implementation: a hand-rolled dual-era JSON-RPC server in Swift
  (the official Swift SDK is Tier 3 and covers 2025-11-25 only) is recommended over bundling a
  Python or Node sidecar.
- **A13 decided (2026-10-12, by the author).** Sprava's own state lives in SQLite (the system
  `libsqlite3`, no new dependency), not in hand-written JSON files: one database per owning target in
  the support folder, opened without following links, in WAL mode, every read-change-write in one
  `BEGIN IMMEDIATE` transaction (cross-process locking, atomic, durable, crash-safe by construction).
  `SpravaKit.StateStore` is the one door. Binders stay plain files (binder-v0; lifeproj reads them, open as F15);
  append-only logs (`jobs.log`, the capture journal) stay files. There is no installed base before
  the MVP, so nothing is migrated: a state file moves to the store when its code is next changed, and
  the developer deletes old test state. Where `docs/architecture.md` names a JSON state file in the
  support folder, this entry governs its storage.
- **A14 decided (2026-10-12, by the author).** No backward compatibility for Sprava's own state before
  the MVP ships: no readers for older formats, no migrations. Binders keep theirs (binder-v0, lifeproj; the
  lifeproj part is open, F15).
- **A15 decided (2026-10-12, by the author).** Binders are ordinary local folders. A binder not in use is
  offloaded (a finished tax year, say) and restored when needed (an audit), so while it is in use it is
  fully local. Sprava does not defend against slow, stalled, network or removable volumes: a read that waits
  on one is not a defect, and reviews do not report it.
- **A16 decided (2026-10-13, by the author).** No clerk filing list. Every binder receives notes, and the clerk
  may file into any of them. The one-line description stays as an optional hint the clerk reads in the binder
  call, pre-filled from the template and editable in the binder's settings. The clerk is Apple's on-device
  model, so a binder's name never leaves the Mac: every binder is offered by name, and the opaque labels go.
  Supersedes the rule that a binder at disclosure `none` is kept from the Tier 1 model unless the person opts
  it in with a neutral description (architecture 5.4, 5.5 and 13 item 16; mvp.md feature 1, feature 5 and the
  filing-quality measure; capture-event-v0 §6.4 step 2). Unchanged, because none of it reads the filing list:
  a brain (Tier 2) reaches a binder only through its client's scope and the binder's disclosure
  (architecture 7.5, 7.6); the hub's slice, the Today page and every cross-binder view apply disclosure as
  before (binder-v0 §5.5); and a capture's `binder_hint` still never routes an item into a binder at `none`
  without the person picking it on the card (architecture 8 step 4).
- **A17 open (2026-10-13).** The hub lane once binders are imported. Today lifeproj publishes and drains
  binders through the spool, and the hub mirrors them to Google Tasks (A7, A8, F8; architecture 11). After an
  import the original folder stays in lifeproj's registry, so `lifeproj drain --all` would go on draining the
  outbox under the binder's name into the original while Sprava drained the same file into the copy. Open:
  whether Sprava publishes and drains imported binders at all; whether the hub and its Google Tasks mirror
  retire in favour of the Today page and the companion (P19); and what happens to the original's registry
  entry. Recommended until it is settled: Sprava neither publishes nor drains an imported binder whose original
  is still in lifeproj's registry.
- **A18 open (2026-10-13).** cmirror registration. Backup is Sprava's restic mirror (A11, A12; `docs/backup.md`),
  so cmirror no longer backs up a binder Sprava owns. cmirror's configuration is also lifeproj's registry,
  which `lifeproj brief` and `drain --all` read (architecture 11). Open: whether Sprava says anything about
  cmirror for an imported binder (mvp.md feature 6 and architecture 9 and 11 still describe registering one by
  hand), and whether the original's cmirror entry is archived once the import is checked. Recommended: Sprava
  neither registers nor checks cmirror, and cmirror's part ends with the hub lane (A17).
- **A19 decided (2026-10-14, by the author).** Background work is not optional. When the app starts, it checks
  that the runtime is running and starts it without asking if it is not; an action that finds it not running
  does the same and goes on. There is no Turn Off; the `runtime/background-off` marker of earlier builds is
  removed when the app starts the runtime. Only the Login Items approval is left to the person, shown as one line
  with a button, never opened by itself. Each start is bounded (architecture 3.1).

- **A20 decided (2026-10-27).** Subscription tokens and email passwords survive background restarts in
  Sprava's own non-synchronized Keychain items. A provisioned runtime uses the data-protection Keychain;
  only a missing-entitlement refusal selects the Mac login Keychain for an ad-hoc build (Apple TN3137).
  Locked or damaged Keychains fail visibly. Only an explicit credential save may ask macOS to authorize
  access. No plaintext file or memory-only success substitutes for a credential that could not be saved.
  The backup key follows the same rule for its local items (2026-10-28): the login Keychain does not enforce
  ThisDeviceOnly; an ad-hoc runtime cannot reach iCloud Keychain, so opting in is refused and, with opt-out, "not
  checked" is recorded in the backup settings and shown until a store reaches it; a key re-entered after an update
  must open the mirror before it is saved (docs/backup.md §4).

## MVP (`docs/mvp.md`)

- **M1 recommended.** The smallest release that proves "a binder that keeps itself": Shelf (adopt
  existing binder folders in place, create one from a template) → Binder Now page, deterministic →
  review queue with provenance and undo → capture inbox (text from any source; P12)
  → Tier-1 filing → two templates → slice publish and outbox drain for hub coexistence → backup via
  cmirror → health page. **Open:** include a minimal MCP surface (reads and proposals only) in the
  MVP because the author drives binders with Claude Code today. **Shelf part superseded by P20
  (2026-10-13):** binders are imported into `~/Sprava`, not adopted in place.
- **M2 recommended.** Deferred: phone capture, sync, sharing, per-binder keys, Google Tasks export,
  email intake, document OCR beyond short scans, the open-model fallback, PCC.
- **M3 recommended.** A measurable success criterion: for 30 days the author's live binders stay
  current with no hand edit of `catalog.json`; every capture becomes a proposal within a minute of
  landing; no deadline is missed that the catalog knew about; a stopped runtime is visible in the
  app within five minutes.
- **M4 decided (2026-10-15).** An adopted binder is on the clerk's filing list until the person takes it
  off ("Suggest this binder for notes from the Inbox and the phone", under "About this binder" on its
  page); one with no line about it is offered by its name. A binder at disclosure `none` stays off until
  the person opts it in with a line they wrote (architecture 5.4). A note typed in the box at the top of
  a binder's page names that binder, and the clerk keeps it there whether or not the binder is on the
  list (capture-event-v0 §6.4 step 2, §8.1). Why: the list's only effect is routing notes written
  elsewhere, and a person cannot be expected to opt each binder into it.

## The binder conversation (`docs/conversation.md`)

D1 to D14 were decided by the author on 2026-10-14 ("go ahead with the plan"); numbers marked "proposed" in
`docs/conversation.md` stay design values.

- **D1 decided.** A binder's main screen is a conversation with that binder, privately to it ("I want to come
  to the right specialist's office", conversation.md §1), with a richer UI: smooth drag and drop, import by path
  or description, questions, and tasks beside the chat. The top-level Inbox stays only for captures whose
  binder is unknown. Supersedes "the review queue is the main interaction, ahead of any chat" (architecture 6;
  brainstorm of 2026-10-06) and the Inbox as the only place to type.
- **D2 decided.** Documents dropped, imported, or arriving in a binder's `intake/` on their own are read and
  filed at once, reported in the conversation with Undo, with no approval card; instructions before or after
  steer or redo the filing; a question comes only for reasons code finds (conversation.md §5). Revises A5,
  P13's card and mvp.md 1.1 for these changes.
- **D3 decided.** The rule that replaces "nothing is applied until the person approves it" in a binder's
  conversation: class A (additions, filings from the binder's `intake/`, drafts in `drafts/`, corrections to
  what the conversation created) applies at once with Undo; class B (changing, completing, dropping or
  reopening anything else, moving a document to another binder, more than 20 additions in a turn) takes one tap
  in the conversation; class C (disclosure, privacy markers, names, expunge, engine and backup settings,
  anything outward, deleting files, manuals and dot folders) stays in the app's own controls. Code decides the
  class from the op and its target, never a model. Document text is data, never instructions: an obligation
  read from a document is a one-tap suggestion unless the person's turn asked for it, and no log entry is
  written from a document's text. Adds
  `move_document`, `unfile_document` and `transfer_document` to binder-v0 (conversation.md §6).
- **D4 decided.** Two roles in every binder. The front desk, a local model with code, is always present and
  makes the simple decisions (file, search and quote, add a to-do, route). The back office, Claude Code or,
  second, Codex, when the person connects one for the binder, is a long-lived per-binder session driven over
  the agent's structured protocol (Claude Code `-p` with stream-json input and output, resumed by session id,
  fixed allow and deny rules and no prompts; Codex's `app-server` JSON-RPC), each in an agent home of Sprava's
  own per binder, so the person's own setup is never loaded and clearing deletes the whole home; never a
  scripted terminal. Its
  reach: Sprava's MCP tools only, reading through Sprava's one safe reader (no file tools, no shell, no web;
  narrowed from read-only file tools after review, to keep binder-v0 §3.4's allowlist); Sprava passes the
  binder's manual, brief and rules itself. One process per session, under a lock. "Open in Terminal" resumes
  the binder's own session in a real terminal (`claude --resume <id>`) after Sprava ends its own process on it,
  until the person presses Resume; the terminal can only propose, and its turns are imported into the
  transcript before any session file is deleted. The session history it keeps outside the binder is listed and cleaned up
  (conversation.md §11.1, §12). Turning a
  back office on is a widening change made in the app's window and is the consent for the binder's documents,
  private and intake ones included. Revises A4 for the back-office client only: it may apply what the person's
  turn authorizes by class (D3); registered clients keep A4 (conversation.md §4, §11.1).
- **D5 decided.** The front desk's model is the most capable local model the Mac can run, not Apple's
  on-device model, which stays the clerk and is the "basic" front desk only on a Mac too small for a better
  one. The runtime is a pinned llama.cpp build bundled as `llama-server`, run as the sandboxed helper
  `sprava-llm` on a Unix socket, with schema-constrained `/completion` calls. The model is chosen by memory
  from a pinned list of Apache-2.0 models (Gemma 4 E4B at 16 GB, tested; Gemma 4 12B or 26B-A4B, and
  Qwen3.6-35B-A3B or 27B, above that, as of 2026-10-14), downloaded once with consent and checked by SHA-256.
  MLX is out: the Command Line Tools have no `metal` compiler (spikes S4, S5). Supersedes the deferral of the
  open-model fallback (P3, M2) for the front desk; the clerk's seam is unchanged (conversation.md §11.2).
- **D6 decided.** The transcript lives in the binder, `.sprava/conversation/<YYYY-MM>.ndjson`, append-only,
  written by the runtime, listed in binder-v0 §7.2 as history. Never on the hub, the Today page, the
  companion, registered MCP clients, logs or notifications (conversation.md §3).
- **D7 decided (revises A3's reach).** The per-binder index covers documents' full text in passages with page
  numbers, translations, items, log entries and the person's own lines. A local answer is quoted passages with
  document and page plus at most one sentence pointing at them; the router picks from a fixed menu of intents
  with grammar-constrained output. A request beyond that gets "this needs thinking", with the back office
  taking it when connected, else two ways on: connect an AI brain, or think it through with the passages the
  front desk gathers (conversation.md §4.1, §9).
- **D8 decided.** A document not in the person's language is translated at filing with Apple's on-device
  Translation framework where the pair is installed, else by the engine; the original is the document of
  record (conversation.md §9.4).
- **D9 decided.** The Inbox keeps its note field for notes whose binder is unknown; in a binder the person
  types in its conversation.
- **D10 decided.** Earned autonomy, measured. The front desk acts at once within D3; the back office reviews
  its work afterwards in batches, and a disagreement becomes one card ("Claude would have filed this under
  X"). Per binder and job kind (filing destination, document type, dates found, to-dos found), only explicit
  signals count: the person's Undo or fix is a miss, the person's explicit confirmation is human-checked, and
  a back-office verdict is reviewer agreement, shown apart. Everything else is unreviewed and never counts.
  Graduation needs both numbers (proposed: 30 reviewed cases at 95%, 10 human-checked at 95%; then 1 in 10
  sampled forever), all to be set from measured fixtures. It only reduces how much the back office reviews,
  and never widens D3. The person sees the scores (conversation.md §7). Revised 2026-10-14 after a review of
  the author's old binders: silence is not agreement.
- **D11 decided.** Every back-office correction the person accepts and every Undo followed by the person's fix
  becomes a written filing rule in a rules part of Sprava's section of the binder's `AGENTS.md` (F14 in PR
  #347), which the front desk reads on every job. Rules follow a fixed grammar and steer only filing within
  the binder (conversation.md §8.1).
- **D12 decided; place recommended.** Sprava keeps a one-page brief per binder (parties, pending, key dates,
  key facts), read first by the front desk and the back office. Code writes the parts that come from the
  catalog; the front desk adds key facts as it files, each a document's own sentence stored verbatim with its
  citation and checked by code, never a model's words; the back office, when connected, may only choose,
  order and group those lines. Models read the brief as data, never as instructions. Recommended place: a visible `BRIEF.md`, Sprava's own file (conversation.md §8.2).
- **D13 decided.** Big requests become task cards with progress, Stop and a draft at the end, each in its own
  back-office session, so the conversation goes on meanwhile. Sprava never does an outward action (sending
  email, filing with a court or tax office, paying); results land as drafts in the binder's `drafts/` for the
  person to send (conversation.md §10).
- **D14 decided.** Import by path or description ("include the March statement from Downloads"): the app
  window does it, as the person's direct command with the person's file permissions, leaves the original, and
  asks only when more than one file matches. A per-binder email intake replacing the author's mail-fetching
  script is future work (conversation.md §5.2, §5.3).
- **D15 recommended (2026-10-14, from a review of the author's old binders).** The record decides what
  happened: the catalog, the op log and the runtime's request and task receipts, never a resumed session or
  the brief. Every back-office or task change goes through the guard, bound to a stable id, the revision it
  was based on and its exact effect; a retry returns the earlier outcome; a changed revision is a conflict.
  Brief lines record their sources and are marked stale before any job reads them. Originals keep their bytes
  and id and can be corrected at any time; a late Undo applies only to fields unchanged since; a repeated
  arrival is recorded on the existing document. Evidence that text exists is not an unconditional duty, and an
  empty search is "no relevant passage was found" (conversation.md §17.1, §17.2, §17.6, §17.7).
- **D16 recommended (same review).** A binder with mixed information scopes, detected at import or declared,
  gets no model at all, back office or front desk, until the person splits it. Surfaces keep their own policies, and encryption is not
  disclosure. Open, for the author: access control within one binder, and a cross-binder manager (P21 in PR
  #347); a per-binder session never gets cross-binder access (conversation.md §17.4).
- **D17 recommended (same review).** Sprava's tools and services offer named contracts for the old workflows
  (attachments with their message, arrival provenance, page and legibility coverage, page images, original
  beside translation, validation and replay, correction history, drafts, freshness), with no shell or web; a
  missing capability is named, never invented (conversation.md §17.5).
- **D18 recommended (2026-10-27, from a reading of Steve Yegge's essay "The Counting House", which ladders
  model autonomy per intent by measured evals).** A job kind's scores belong to the engine that earned them:
  the front desk's model, variant and prompt version, as C3's `producer` records them. When any of these
  changes, every kind goes back on probation, its old scores kept beside the new ones. Before a model change
  the person did not ask for (a new pinned list, a larger Mac, D5), the new model may first run in shadow: it
  decides the same jobs as the current one, nothing it decides is applied or shown in the conversation, and
  its decisions are scored against the same explicit signals (conversation.md §7.2) and shown in the engine
  settings. Why: today scores earned by one model carry over silently to another.
- **D19 recommended (same reading).** Job kinds differ in what a miss costs and in whether it is seen. A
  misfiling is seen and undone; a date or to-do the front desk did not find produces no signal, since nobody
  undoes what never appeared. Kinds whose miss is unseen (dates found, to-dos found; proposed list) are also
  measured by recall: a miss is a back-office verdict that read every page (conversation.md §17.6) and found
  one more, or the person adding a date or to-do that cites a document the front desk filed. These kinds
  never graduate: the back office reviews every case. D10's graduation applies to kinds whose miss is seen.
- **D20 recommended (same reading).** D10's counts cannot show 95%: 30 right of 30 still allows a true error
  rate near 10% (rule of three), and one binder rarely gives more cases of a kind. Graduation counts the
  person's cases of a kind across all their binders for the same engine (D18), as counts only, never content,
  in Sprava's state on the Mac (A13); probation stays per binder. The thresholds are still set from measured
  fixtures.
- **D21 recommended (same reading).** The reviewer is checked before its verdicts count. Back-office verdicts
  count toward graduation only once the person has chosen the back office's version on enough of the
  disagreement cards they answered (proposed: 15 of the last 20); until then they are shown apart and nothing
  graduates. A confirmation given faster than the card can be read (proposed: under 2 seconds) is not counted
  as human-checked, so tapping through does not raise the score meant to measure it.
