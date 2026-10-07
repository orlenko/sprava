# Sprava: what it is, as I read it, and where I'd push back

> Written 2026-10-06 by the planning session that received `HANDOFF.md`, after reading the
> reading list, the lifeproj and holos code, and a verified research sweep (Apple Foundation Models,
> MCP, the platform, licensing, names, competitors). Audience: the author. Examples are invented;
> nothing here comes from a real binder. The decisions this implies are listed one per line in
> `decisions.md`.

## What Sprava is (one page)

Sprava keeps a case file for each episode of a person's life. An estate to settle, a move, a tax
year, a rental property, a seat on a condo board: each gets one binder, a **teka**, and the binder
stays current on its own. At any moment it answers the four questions that matter: what is open,
what is due, who are we waiting on, and which documents exist. It also keeps a record of how it
got there, so every fact can be traced to the capture, document or decision it came from.

It is built in three layers.

**The teka: an open folder format.** A binder is an ordinary folder a person can read without the
app: an operating manual, a catalog of documents and open items, an append-only log, and a
dashboard regenerated from the catalog. This is the format the author has run for months with
lifeproj and terminal agents. Sprava promotes it to a written spec with schemas and conformance
checks, so lifeproj becomes a second implementation of the same thing, not a dependency.

**The runtime: one supervised local process.** It does the mechanical work deterministically and
needs no model for it: deadlines and overdue detection, the nudge bucket for items waiting on
someone else, recurrence, the cross-binder roll-up, GTD contexts, the review queue with undo,
backups, and its own health. Every change to a binder goes through typed operations checked by a
transaction guard. This layer replaces the watcher, the sync loop, the web server and the
monitors that broke in the last two weeks.

**The clerks: two tiers, one gate.** Tier 1 is the on-device model (Apple Foundation Models, with
a local open model as fallback behind the same API). It works on one capture at a time: cleans it
up, splits it into items, pulls out dates, amounts and people, guesses which binder each item
belongs to, and proposes changes. Tier 2 is optional: Claude, Codex or any agent that speaks MCP
connects to the same binders for the hard work, such as reconciling a long binder, drafting a
careful letter or cross-referencing documents. Both tiers propose through the same typed
operations, and nothing is applied until the person approves it. No subscription is needed for
Tier 0 or Tier 1.

**Capture comes from holos.** The dictation app keeps working on its own. With Sprava installed, a
dictated note becomes an immutable capture event in a versioned format, and Sprava files it.
Later a phone app can write the same events into an append-only inbox, which is why capture can
sync before anything else does.

**The product is the discipline, not the model.** Current truth plus provenance; nothing outbound
without approval; compartments (a litigation binder no agent or other device can see into); a
case file per episode rather than a memory profile of the person. The research confirms this is
still the gap, with one narrowing: approval gates are now table stakes in every cloud agent, so the
claim is "approval of typed changes to a case file, with provenance and undo, on your own Mac",
not "approval" alone.

**What is proven and what is not.** Proven, in months of real use: the catalog + log + validator
pattern, the honesty rules (`due` xor `no_deadline`, `waiting_on` when waiting, ids never reused),
federation with discretion, and the deterministic loop with the model used only for judgment. Not
proven: that the system stays correct for months without the author supervising it, and that any
of this can be packaged for someone who will never open a terminal. The runtime's job is to
replace the author as supervisor. The review queue's job is to replace the terminal.

## Where I'd push back

1. **Adopt binders in place; keep the catalog as the truth of state.** The handoff's strong
   candidate is "the op log is the source of truth and the catalog a materialized view". I'd keep
   `catalog.json` as the truth of *state* and make the op log the truth of *history*, with each op
   recording the catalog's content hash before and after. When the chain breaks (someone edited
   the catalog by hand, or a terminal agent ran a digest), the runtime records an `external_edit`
   op holding the diff, so provenance survives instead of the edit being an error. Why: existing
   tekas are plain folders that terminal agents edit today, and the author wants lifeproj to stay
   a valid second implementation; a view-only catalog forbids both. Undo, "why does it say that"
   and later multi-device merge all work on the chained log either way. What it changes: Sprava
   never imports a teka into a store. It opens the folder where it is and adds a `.sprava/`
   directory inside it for the log and the index. "Existing tekas must open without loss" becomes
   nearly free, because nothing is converted. (`decisions.md` F1)

2. **The clerk emits interpretations, not ops.** The handoff asks for guided generation so the
   clerk emits typed ops. I'd have the on-device model emit a small, stable *interpretation* of one
   capture (the items it heard, each with a title, a time expression, people, an amount, a binder
   guess, a confidence, and the span of transcript it came from) and have plain code turn
   interpretations into proposed ops. Why: the op vocabulary will change and must stay validated
   independently of any prompt; a small model is more reliable on one flat schema than on a growing
   union of op types; "Thursday" should be resolved by code from the capture's own timestamp and
   locale, not by the model; and the interpretation is exactly the derived event the capture-event
   spec needs. (C3)

3. **Tier 1 is narrower than the handoff hopes, and the budget is 4k, not 8k.** The handoff pairs
   "about 3B parameters" with "~8k tokens". On macOS 27 the 8,192-token window belongs to the
   20B-sparse "Core Advanced" model on M3-or-later Macs with 12 GB; the 3B "Core" model on M1 and M2
   keeps 4,096. The clerk must be designed for 4,096 and read the size at runtime. With that budget
   it is good at captures and short documents and poor at long ones. I'd scope Tier 1 to: normalize
   a capture, split it, extract fields, pick a binder from a closed list, check for duplicates
   against a handful of retrieved candidates, title and date a short document, draft a one-line
   nudge. Reconciling a binder, cross-referencing documents and drafting letters stay Tier 2. The
   brainstorm's make-or-break moment ("drop your shoebox, see your first Now page in minutes")
   needs Tier 2 or a lot of deterministic scaffolding, and the MVP should not promise it. The
   honest Tier-1 pitch is "the clerk files; the brain thinks". (P2, P5)

4. **Encryption is a property of the container, not of the format, and per-binder keys are not
   MVP.** The handoff lists root key, per-binder keys and ciphertext-only backup under
   architecture. I'd design all three but keep encryption at rest outside the format: binders are
   plain folders (FileVault protects the disk), offsite backup is ciphertext only with one root key
   (the model cmirror already uses), and per-binder keys arrive with sharing and sync in Phase 2.
   Why: an encrypted-at-rest binder can't be read by lifeproj or by a terminal agent, which kills
   the second implementation; key management is the second onboarding cliff the brainstorm itself
   warns about; and compartments against *agents* on a single-user Mac are a policy and MCP-surface
   matter, not a cryptographic one. One detail the research settles: a Keychain or Secure Enclave
   key is device-bound and non-exportable, so it can hold a copy of the root key but never the only
   copy; the portable age identity stays. (A6)

5. **The briefs lane is not a format contract.** The handoff asks for slice, outbox *and briefs*
   contracts in `teka-v0`. The briefs lane is provisional and hub-specific (reading a meeting brief
   on a second screen). In Sprava it is a product feature, documents readable in the app, not a
   format. I'd leave it out of v0, keep the agenda slice and outbox as an optional *federation
   profile* for coexistence with the existing hub and for any future split-process deployment,
   and define the redaction `kind` there. (F8)

6. **The hub becomes a Sprava view, the spool stays as an interop lane, and "Osavul" stays a
   private codename.** Inside one app there is no process boundary to enforce federation, so the
   boundary becomes policy: each binder carries a disclosure setting (full, title only, kind only,
   nothing) that decides what the cross-binder Today page may show. The spool stays so the
   existing hub keeps working while binders move over one at a time, and so a sandboxed terminal
   session can still publish. The web lens retires when Today covers it. On the name: an existing,
   funded AI company called Osavul filed OSAVUL for software and SaaS (classes 9 and 42) in the EU,
   the UK and the US the week of 2026-09-29. The public view needs another name. (A8, P11)

7. **The licence question is really two questions.** You said GPL-3.0 is on the table; I'd take
   it. GPL-3.0 matches holos, protects the runtime from proprietary forks, and the capture-event
   boundary stays the right design for product reasons even where linking would be allowed. The
   App Store is the complication for GPL and LGPL alike; the research confirms the FSF position
   (GNU Go 2010, VLC 2011), that a sole copyright holder is not bound by it, and that the fix is the
   libsignal/Nextcloud pattern: an additional permission for App Store distribution adopted while
   there is one copyright holder, plus a DCO or CLA. MPL-2.0 is the alternative if outside
   contributions come early. Second, the spec, schemas, validator and conformance tests should be
   permissive (CC-BY-4.0 for prose, Apache-2.0 for code) with an explicit no-trademark note. (L1–L3)

8. **holos should produce capture events; Sprava should not read holos's files.** The research
   shows why consumer-side reading is fragile: `dictations.jsonl` has no cursor and is rewritten in
   place, the retention sweep deletes records and audio after 7 or 30 days, a sandboxed reader
   would need a folder grant, and Apple announced tighter Full Disk Access controls on 2026-10-02
   because of AI agents. You own holos; a small "capture folder" feature on the GPL side is
   cleaner than an importer on this side, and it is the same hook a phone app would use. A
   developer-only importer over `voiceislocal … --json` bridges the gap. (P7)

Things I agree with and would only sharpen: the single supervised runtime (as a user LaunchAgent
registered from the app bundle); typed ops behind a transaction guard; the Nudge bucket and
`follow_up_at`; redacted items publishing a kind; a deterministic deadline sentinel that runs
before any model; hybrid logical clocks on capture events (cheap now, needed later); generated
docs plus a `doctor` command; and one bucket taxonomy instead of the two lifeproj carries today.

## What the research changed

- **The model.** Design for 4,096 tokens; 8,192 only on M3-or-later Macs with 12 GB. The `fm` CLI
  needs a one-time `sudo` licence agreement, cannot drive tool calls, and has no Private Cloud
  Compute; Apple's Python SDK needs full Xcode. Both are developer tools. The product uses the
  Swift `FoundationModels` framework, and the open-model fallback is a `LanguageModel` conformer
  behind the same session code (Apple ships `CoreAILanguageModel` and MLX ships
  `MLXLanguageModel`). Custom LoRA adapters are gone on macOS 27. Apple's model supports 24 locales
  and not Ukrainian. Private Cloud Compute is free only for App Store apps in the Small Business
  Program with an entitlement, so it is out unless distribution changes. No rate limit is documented
  on macOS for background processes (an Apple engineer said it "does not apply at all"; unverified
  under load).
- **MCP.** The current revision is 2026-07-28 (stateless, server-initiated requests replaced by
  "input required" round trips). Clients are split across eras: Claude Code, Codex, Cursor and
  VS Code render elicitation; hosted Claude (claude.ai, Desktop chat, Cowork) and Gemini CLI do
  not. There is no "proposal awaiting approval" object in MCP, so approval lives in Sprava's queue;
  proposal tools return a handle and never block. The spec blesses stdio framing over a Unix socket,
  which makes "one daemon, a thin shim per client" the clean design. The official Swift SDK is Tier 3
  and stops at 2025-11-25.
- **holos.** It has never run on this Mac (no data folder exists), so the capture spec is written
  from the code, and there are no fixtures. Every holos record is schema-versioned JSON written
  atomically; meetings carry a summary with plain-string action items, speaker-to-person links, and
  markers; there is no notification mechanism, only files.
- **lifeproj.** The code enforces far less than the prose: strict rules exist only for
  `open_items[]`; `documents[]` and `processing_log[]` have no schema; there is no dashboard
  renderer; nothing migrates `schema_version`; three generations of the copied-in checker exist;
  `done appears once then drops` is a manual rule, not code; and `lifeproj route` hooks stamped into
  every teka send prompt text to TypeSafe when a key is set, with a plaintext request log outside
  the backup. The lifeproj and handoff descriptions also disagree on local git.
- **Competitors.** OpenAI dots, Meta Muse, Gemini Spark, Microsoft Autopilot, Instinct, Grok Bot,
  Manus Cue and Amazon Quick all run on vendor cloud VMs; Claude moved new Cowork tasks to the
  cloud on 2026-10-06. Inbox mining and approval gates are table stakes. The nearest neighbours the
  brainstorm missed are Casefleet (fact-level provenance with approval, cloud) and Prosei (per-case
  deadline extraction, cloud). Local-first, compartments with a redacted roll-up, a horizontal
  per-episode case file, an open agent-neutral format, and region-agnostic availability still hold.
  Muse's launch month confirms the posture (a Mac zero-day, staff VM access by policy, an unshipped
  confidential VM). Apple's Full Disk Access tightening favours user-granted folders and capture
  events over disk-wide reads.
- **Names.** Osavul: taken, actively being registered for software; keep it private. Teka: Teka
  Industrial holds the word for appliances in many countries and ships a "Teka Home" app; its EU
  class-9 mark covers irons and vacuum cleaners, not software, so the risk for a lowercase format
  term is bounded, but not for an app name. Sprava: no live mark in classes 9/42 in the US, Canada
  or EU; npm `sprava` (a Claude Code manager, 2026), sprava.ai (property reports), sprava.dev and
  two iOS apps use the name; sprava.app, sprava.io and sprava.ca were free on 2026-10-06. None of
  this is legal advice; a clearance opinion (including the phonetic "Strava") belongs before any
  announcement.

## Open questions

The handoff's six, with my recommendation where I have one:

- **Minimum macOS.** 27-only, Apple silicon, like holos. Which Macs: M1 and later with a 4k clerk
  budget, or M3-plus-12 GB only? I'd support M1 and design for 4k.
- **App Store or direct DMG.** Direct notarized DMG first (holos already has the release script);
  App Store later, only if the licence route is settled.
- **Licence.** GPL-3.0 for the app with the App Store additional permission adopted now; permissive
  for the spec. Confirm.
- **Multi-device sync in v1.** No. Mac-only, with the capture-event format designed so the phone
  inbox can ship early.
- **First templates.** Pick the ones you live, so they get dogfooded: a rental property with
  tenancies as chapters, a condo-board seat, a tax year. Estate executor is the commercial one,
  but a template nobody uses will be wrong; it should come third, reviewed by someone who has done
  it. v1 templates should carry undated checklists only, no statutory deadline rules.
- **Sprava and the hub.** Answered in push-back 6; the public name of the cross-binder view is
  yours to pick.
- **Trademark and domain.** Findings above. Register sprava.app and sprava.ca now if the name
  stays; get a clearance opinion before announcing.

Mine:

- **Where do you dictate today?** holos has never run on this Mac. Can you produce a few sanitized
  or synthetic holos fixtures (dictation lines, one meeting folder with its exports, a people file
  without voiceprints) for conformance tests, and is adding a capture-folder producer to holos in
  scope?
- **Languages.** English and French in v1, Ukrainian through the open-model fallback later? If
  Ukrainian matters now, the fallback moves into the MVP.
- **A structure-only survey of your live tekas.** I'm not allowed inside `~/tekas/`, and the
  `documents[]` and `processing_log[]` shapes exist only there. I have a script that prints key
  names, types and counts and never a value or a name; running it once would let the spec match
  reality. Your call.
- **Backup.** Should the MVP call cmirror for backups (it exists, and every live teka is registered
  with it) and replace it natively later, or ship its own from day one? There is no mature Swift
  age library, so native means bundling the Go binary or implementing the spec on CryptoKit.
- **lifeproj's future.** Does it keep evolving as the terminal implementation of the spec, or
  freeze? If it evolves, every spec change lands twice.
- **The MCP server's stack.** A hand-rolled dual-era server in Swift, or a bundled Python/Node
  sidecar? I'd go Swift.
- **A minimal MCP surface in the MVP.** Reads and proposals only, because you drive binders with
  Claude Code today. In or out?
- **UI toolkit.** holos is AppKit. Same for Sprava, or SwiftUI with AppKit where needed?
- **Local git in tekas.** The handoff says yes, lifeproj says none by design. Is git history meant
  to be a provenance fallback, or just something v0 tolerates?
- **Dogfooding from day one.** I'm assuming the MVP opens your live tekas in place on the first
  day it can. That decides the priority of the adopt-in-place path over everything else.
- **The hub during the transition.** I'm assuming the existing hub, spool and Google Tasks sync
  keep running until Today covers them.

## What I'm drafting next

`docs/spec/teka-v0.md`, `docs/spec/capture-event-v0.md`, `docs/architecture.md` (with the skeptic
pass), `docs/mvp.md`, and a refreshed competitor section for the brainstorm, all following
`decisions.md` and all as drafts for you to commit or not.
