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
- **P9 open.** First templates. Recommended: a rental property with tenancies as chapters, a
  condo-board seat, a tax year (the ones the author lives), estate executor third. v1 templates carry
  undated checklists only; no statutory deadline rules.
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
- **F10 recommended.** JSON conventions: UTF-8 unescaped, two-space indent, trailing newline, key
  order preserved on rewrite, canonical form (RFC 8785) only for hashing; JSON Schema 2020-12.
- **F11 open.** A structure-only survey of the author's live binders (keys, types, counts; never
  values) would confirm the `documents[]` and `processing_log[]` shapes and the checker generation
  per binder. A script is ready; only the author should run it.
- **F12 open.** The handoff says binders use local git; lifeproj scaffolds none by design. v0 tolerates
  and ignores `.git/`. Whether git history should count as a provenance fallback is the author's call.

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
- **A5 recommended.** The review queue: a proposal is an op batch with provenance, confidence and
  source spans; cards offer approve, edit, reject; applied ops carry `approved_by`; undo is a
  compensating op. Tier 1 and Tier 2 proposals look identical in the queue.
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
  requires a second, independent backup.
- **A7 recommended.** An explicit inventory of what leaves the Mac, kept in the docs and the app:
  nothing by default; backup ciphertext; Tier 2 MCP clients, per binder and opt-in; the existing hub's
  Google Tasks mirror during the transition. Sprava ignores `.claude/settings.json` and the lifeproj
  routing hooks (terminal-agent configuration, not format) and never calls TypeSafe itself.
- **A8 recommended.** Hub coexistence: for binders it manages, Sprava publishes agenda slices to
  the spool and drains the outbox with lifeproj's exact semantics; the cross-binder Today page
  replaces the hub's web lens over time; `disclosure` is enforced at the roll-up.
- **A9 recommended.** Mechanical docs are generated from a capability manifest; a `doctor` command
  checks binders and docs against reality; every hook and job is timed with a circuit breaker.
- **A10 open.** The MCP server's implementation: a hand-rolled dual-era JSON-RPC server in Swift
  (the official Swift SDK is Tier 3 and covers 2025-11-25 only) is recommended over bundling a
  Python or Node sidecar.

## MVP (`docs/mvp.md`)

- **M1 recommended.** The smallest release that proves "a binder that keeps itself": Shelf (adopt
  existing binder folders in place, create one from a template) → Binder Now page, deterministic →
  review queue with provenance and undo → capture inbox (text from any source; P12)
  → Tier-1 filing → two templates → slice publish and outbox drain for hub coexistence → backup via
  cmirror → health page. **Open:** include a minimal MCP surface (reads and proposals only) in the
  MVP because the author drives binders with Claude Code today.
- **M2 recommended.** Deferred: phone capture, sync, sharing, per-binder keys, Google Tasks export,
  email intake, document OCR beyond short scans, the open-model fallback, PCC.
- **M3 recommended.** A measurable success criterion: for 30 days the author's live binders stay
  current with no hand edit of `catalog.json`; every capture becomes a proposal within a minute of
  landing; no deadline is missed that the catalog knew about; a stopped runtime is visible in the
  app within five minutes.
