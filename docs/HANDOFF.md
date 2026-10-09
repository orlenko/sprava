# Sprava: kickoff handoff

> Written 2026-10-06 by the author's hub session ("Osavul") to start Sprava's planning in a fresh
> context. **Read this whole file first**, then `docs/brainstorm/2026-10-06_product-brainstorm.md`.

## ⚠️ This repo is public

`orlenko/sprava` is a **public** GitHub repository (LGPL-2.1). Treat everything you write here as published.

- **No personal data, ever.** No real names, addresses, unit numbers, account or business numbers,
  legal-case details, tax facts, or the contents of any existing life project ("teka"). The author's real
  tekas cover litigation, property, tax and governance matters. They are private and must stay out.
- **Examples must be invented.** Use made-up projects ("Estate of A. Example", "Kitchen renovation")
  instead of anything from the author's life.
- You may **read** the author's local design docs listed under "Reading list" to understand the existing
  system. Do not copy personal or project-specific content from them into this repo.
- The author decides when to commit and push.

## What Sprava is (decisions already made)

1. **A fully local life-project organizer for the Mac.** A person keeps one *binder* (a **teka**) per life
   episode: an estate, a move, a renovation, a tax year, a rental property, a condo-board role. Software
   keeps each binder's **current truth** (what is open, what is due, who we're waiting on, which documents
   exist) up to date, and keeps an append-only log of how it got there.
2. **No AI subscription required.** The baseline runs entirely on the Mac:
   - **Tier 0, no model at all:** the structured organizer (schema, deadlines, waiting/nudge rules,
     recurrence, the cross-binder roll-up, GTD contexts). This alone should be useful.
   - **Tier 1, on-device model (the "clerk"):** Apple Foundation Models (`fm` CLI / Swift / Python SDK on
     macOS 27) plus local open-source models where needed. It cleans up captures, splits them into atomic
     items, extracts dates, amounts and people, files each item to one of the user's binders (or "not
     sure"), and **proposes typed changes for the user to approve**.
   - **Tier 2, optional "strategic brain" add-on:** Claude, Codex or any other agent connects as an
     **MCP client** to the same binders for the hard work: reconciling a 100-item binder, drafting a
     careful letter, cross-referencing documents. Same typed ops, same approval gate. It is never
     required.
3. **Capture comes from holos ("Voice is Local").** holos (`~/code/holos`, public, **GPL-3.0**, Swift 6.4,
   macOS 27) already does on-device dictation, meeting recording with speaker labels, a "people"
   registry, word corrections, and Foundation Models summarization. Sprava should **consume holos output
   through a defined, versioned capture-event format** and **must not link holos code**, because
   GPL-3.0 code linked into an LGPL-2.1 app would force GPL on Sprava. holos keeps working on its own,
   and with Sprava installed a dictated note lands, classified, in the right binder.
4. **We are not competing with the cloud agents.** OpenAI dots and Meta Muse (both launched Sept 2026)
   do cloud-side proactive mining of email and drives. Sprava's position is what they structurally can't
   offer:
   - local-first, nothing leaves the Mac by default;
   - **compartments** (a litigation binder no agent or other device can see into);
   - a structured case file per life episode, not a "memory about you";
   - provenance on every fact;
   - **nothing outbound without the user's approval**.
5. **Naming.** **Sprava** (Ukrainian *справа*: a matter, an affair, a case file; *справи*: one's affairs).
   A single binder is a **teka**, which is also the name of the open on-disk format. The cross-binder
   chief-of-staff view is **Osavul** for power users. Tagline candidate: *"a binder that keeps itself."*
   Trademark and domain checks have not been done.

## The existing system this grows from

The author has run this as a terminal workflow for months. The concepts are proven; the packaging isn't.

- **`lifeproj`** (`~/code/lifeproj`, public, Python CLI) scaffolds and orchestrates tekas. Read
  **`docs/DESIGN.md`**: it is the best description of the model.
- **A teka** is a folder with:
  - an operating manual (`CLAUDE.md`, plus an `AGENTS.md` bridge so any agent CLI works);
  - `catalog.json`: `documents[]`, `open_items[]` and an append-only `processing_log[]`, guarded by a
    validator;
  - a regenerated `DASHBOARD.md` (current truth, not history);
  - a transient `intake/` drop zone;
  - optional `chapters/` (finite episodes inside an ongoing project).

  Item schema rules worth keeping:
  - `due` **XOR** `no_deadline`;
  - `waiting_on` required when an item is waiting or blocked;
  - ids are never reused.

  The digest ritual: drain intake → classify → file → record → reconcile items → regenerate dashboard →
  publish. Storage is local git (no remote) plus an encrypted backup of the whole folder to cloud
  storage.
- **The hub ("Osavul")** reads only a shared **spool**:
  - each teka publishes `inbox/<teka>.agenda.json`, and the file appearing *is* the registration;
  - the hub writes completions to `outbox/<teka>.intake.json`, which the teka applies on its next
    drain, so the hub never edits a teka;
  - a provisional `briefs/` lane lets a teka publish readable documents.

  Teka privacy is protected by **federation** (the hub never reads inside a teka) and **discretion**
  (sanitized or redacted titles, or a teka that never publishes at all). The hub rolls everything into
  urgency buckets and GTD contexts, serves an editable local web app, mirrors dated items to Google Tasks
  with a narrow read-back of phone check-offs, and runs a deterministic sync loop.
- **Working rule: "monitors flag, humans act."** Nothing is sent, signed, paid or committed outbound
  without explicit approval. Drafts wait for review.

## Hard-won lessons (design against these)

These all happened in a two-week window of real use:

- **The process zoo is fragile.** Separate sessions, a watcher daemon, a sync loop in a side pane and a
  web server meant session restarts killed monitors, a temp-file cleaner deleted a monitor script, and
  two copies of the sync loop ran for a week without anyone noticing. → **One supervised runtime** with
  heartbeats and single-instance leases. Silence counts as an alarm.
- **Naive integration polling caused a quota lockout.** The Google Tasks read-back did one GET per item
  ever published (~200 every 5 minutes) and hit the API's daily quota. The dashboard filtered output, so
  the 429 read as "0 done, 0 errors". Separately, a 7-day OAuth token expiry (an app left in "Testing")
  broke sync for a week. → Delta reads (`updatedMin`, `syncToken`), a per-connector quota budget,
  errors as first-class visible state, token expiry surfaced before it bites.
- **A slow hook was misdiagnosed.** A terminal-integration hook hung every prompt for 30 seconds and was
  first blamed on the wrong component. → Time every hook or plugin, add circuit breakers, name the
  culprit.
- **Staleness looked like lateness.** "Waiting on someone" items kept their old due dates and showed up
  as overdue: 17 overdue fell to 4 once they were re-dated. Projects nobody opened for weeks published
  nothing new. → `expected_by` / `follow_up_at` plus a **Nudge** bucket for waiting items; a
  digest-overdue signal per binder; headless digests that produce proposals.
- **Federation costs answerability.** The hub couldn't explain an overdue item beyond its title, and a
  fully redacted project couldn't be triaged at all. → **Ask-through:** the hub sends a scoped question
  to that binder's own agent, under the binder's own policy. Redacted items still publish a
  non-sensitive *kind* (`legal-deadline`, `payment`, `reply-owed`).
- **Docs drifted from code.** The manual said "one-way sync" months after read-back shipped. →
  Generate the mechanical docs from code, and add a `doctor` command that checks docs against reality.
- **Security rough edges.** An unauthenticated local web app, secrets in shell config, and a slow
  reverse-DNS lookup on server start. → Device pairing and passkeys, secrets in the Keychain, no DNS
  lookups on hot paths.

## Constraints to plan around

- **The on-device model is small: about 3B parameters with an ~8k-token context.** The clerk can never
  "read the binder". Every Tier-1 job must work on **one capture at a time plus a few retrieved facts**
  (local index or Spotlight). That rule sets the clerk/brain boundary. Use guided (typed) generation so
  the clerk emits typed ops, not prose.
- **Every write goes through typed ops validated by a transaction guard.** No agent, local or add-on,
  hand-edits state. Strong candidate from the brainstorm: make the op log the source of truth and the
  catalog a materialized view, which gives undo, provenance, "why does this say that?" and later
  multi-device merge.
- **Platform:** macOS 27 and Swift 6.4 (holos is the precedent). Apple Intelligence must be enabled and
  available in the user's region, so keep a local open-model fallback for Tier 1.
- **Capture sync is append-only** (immutable capture events), so it's conflict-free. That's why the
  phone capture app can ship early, before full sync.
- **Existing tekas must be importable.** The author's live tekas should open in Sprava without loss.
  lifeproj becomes the second implementation of the spec; it is not a dependency.

## Reading list

Public, safe to quote:
- `docs/brainstorm/2026-10-06_product-brainstorm.md` in this repo: the full product brainstorm (what to
  keep, what to change, personas, UX, tiers, encryption, competitors with sources, risks, phased plan),
  plus the dots/Muse addendum. **Its competitor section is known to be incomplete** (it missed dots and
  Muse on the first pass). Refresh it with current web research.
- `~/code/lifeproj/docs/DESIGN.md` and the lifeproj README.
- `~/code/holos/README.md` and `~/code/holos/docs/status.md`.

Private, local only (read for understanding; do not copy anything specific): the hub's four documents in
the author's local hub folder: its operating manual (spool contract, guardrails, sync, quota guard), the
editable web lens with its op vocabulary and ownership rule, and the briefs lane with the Google sync seam.
Do not read any other folder there: those are private life projects.

## How the author works (please follow)

- **Design-skeptic pass before any code.** Write the design, then attack it.
- **After building:** a hostile-eyes review, specialist reviewers, a simplification review (report only),
  and a security pass. Re-verify after each fix wave.
- **Monitors flag, humans act.** Propose, don't act, on anything outbound or irreversible.
- **Prefer small, testable increments** and plain files over cleverness. Deterministic code for
  mechanics, models only for judgment.
- **Plain language in docs.** The audience includes non-technical future users.

## Suggested first session (preparatory work, before any app code)

1. Read everything in the reading list, then summarize back to the author what you think Sprava is, in
   one page, and list what you disagree with.
2. **Draft `docs/spec/teka-v0.md`:** the open binder format, extracted from lifeproj's DESIGN.md and the
   hub contracts: folder spine, catalog and op schema (with the Nudge/`expected_by` and redaction-*kind*
   additions), slice/outbox/briefs contracts, and versioning. Include JSON Schemas and a list of
   conformance checks.
3. **Draft `docs/spec/capture-event-v0.md` with holos in mind:** an immutable capture event (device id,
   hybrid logical clock, source, media refs, transcript, language, people hints, sensitivity), and the
   derived-event model for Tier-1/Tier-3 processing (which tier or model, inputs, supersedes). Check it
   against what holos actually produces today.
4. **Draft `docs/architecture.md`:**
   - the single supervised runtime;
   - the op log and transaction guard;
   - the Tier 0/1/2 boundaries under the 8k constraint;
   - the MCP surface for add-on brains;
   - encryption (root key, per-binder keys, ciphertext-only offsite backup);
   - the approval/review queue.

   Then run the **design-skeptic pass** on it.
5. **Draft `docs/mvp.md`:** the smallest Mac-only release that proves "a binder that keeps itself" with
   zero subscriptions. Suggested core: Shelf → Binder "Now" page → review queue with provenance and
   undo → holos capture → on-device filing → one or two templates. Name what is explicitly deferred.
6. **List open questions for the author** (below, plus your own).

## Open questions for the author

- Minimum macOS (27-only like holos?), App Store versus direct notarized DMG, or both?
- Is LGPL-2.1 the intended license for the app *and* the spec? Should the spec be more permissive (MIT,
  CC-BY) to encourage other implementations?
- Multi-device sync in v1, or Mac-only plus an append-only capture inbox from the phone?
- Which life-episode templates first? The brainstorm suggests estate executor, move/renovation, tax year.
- How does Sprava relate to the existing hub? Does it replace Osavul's web lens, or does Osavul become a
  Sprava view?
- Trademark and domain check for "Sprava" before any public announcement.
