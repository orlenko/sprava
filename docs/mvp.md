# Sprava MVP

Status: v0 draft of 2026-10-06, revised after two design-skeptic passes (section 9). Written by the planning session for the author to review before any code. It follows `docs/decisions.md` and cites entries like "(decisions.md M1)". Where it asks to change a recommended entry, it says so and lists the change in section 8, question 9. It builds on `docs/architecture.md`, `docs/spec/teka-v0.md` and `docs/spec/capture-event-v0.md` and cites their sections like "(architecture 3.4)" or "(teka-v0 §9.4)". Facts come from the verified research digests of 2026-10-06, named inline (for example "web-apple-fm"). Every example is invented: binders such as `estate-example` ("Estate of A. Example"), `kitchen-reno`, `tax-2026` and `rental-elm-street`, people such as "A. Example", "the notary" and "the property manager".

## 1. The thesis and how we will know

### 1.1 What the MVP must prove

Sprava keeps one binder per episode of a person's life. A binder is an ordinary folder on the Mac. Its format is called a teka. Inside it, `catalog.json` (the catalog) says what is open, what is due, who the person is waiting on, and which documents exist.

The MVP (minimum viable product: the smallest release worth using) must prove one sentence: a binder keeps itself. In plain terms:

- New material reaches the right binder without the person opening a file. A note, however the person produced its text (typed, dictated with any tool, pasted), becomes a proposed change within a minute (decisions.md P12). A file put in a binder's `intake/` folder becomes a card to file it.
- Nothing changes until the person approves it, and every change can be traced and undone.
- Deadlines and follow-ups surface on their own, even when nobody opened the binder for weeks.
- When the background work stops, the person finds out.
- All of this runs on the Mac with no subscription, no account and no network. An outside AI tool can help, and is never needed (decisions.md P1).

Today the author gets most of this from terminal agents, lifeproj (the author's Python tool that creates tekas) and a set of background scripts. That works only while the author supervises it (kickoff summary). The MVP replaces the author as supervisor. The review queue replaces the terminal.

### 1.2 The success criterion

The MVP succeeds when, for 30 counted days, the author's live binders meet all four parts of decisions.md M3 and the four proposed additions below. A developer script computes every measure from Sprava's own records: the op log of each binder (its history of typed changes), the capture journal, the review queue and the MCP log. The app's Health page shows only whether things work right now (feature 9).

Away days. The author may mark a day as away, on the day or before it, never afterwards. An away day pauses the count without resetting it. It pauses only the measures that depend on the person: the volume floor, currency and the self-keeping share. The machine measures keep running on away days and keep counting: the minute, deadlines and runtime visibility.

The four parts of M3:

| Part of M3 | How it is measured |
|---|---|
| The binders stay current with no hand edit of `catalog.json` | The op log of every adopted binder holds no `external_edit` op (a change made outside Sprava and detected afterwards; architecture 4.5) in the window. Every external edit counts, including one the author makes on purpose. The miss report names its likely cause: the author in an editor, a terminal agent, lifeproj, or unknown |
| Every capture becomes a proposal within a minute | Measured from the end of the capture to its first proposal. The end is the event's `ended_at` (capture-event-v0 §4.3). For an event without it, the end is `captured_at`; no producer's private extensions are read (decisions.md P12). `captured_at` alone is the start of the capture, so a 90-second dictation would start its minute 90 seconds late. Measuring from the moment the file lands would let a dictation imported three days late count as on time. Producer lag, from the end of the capture to the time the producer wrote the file (`hlc.wall_ms`), is reported on its own line, so a late file shows up. Misses are reported by cause: runtime down, a planned restart after an update, producer lag, found only by the sweep, or seen in time and not finished. Every miss counts. Only history imported before the importer first ran is excluded |
| No deadline is missed that the catalog knew about | The daily summary job logs, with its counts, the exact time it read the binders. For each binder and each day, the script replays the op log to that logged time, recomputes the Today bucket, and compares it with the logged count, binder by binder, under opaque binder ids. The failures it looks for: a summary that was not posted, a deadline sentinel stale for more than a day, and alerts switched off (architecture 3.7). The logs hold counts and opaque ids only, never titles |
| A stopped runtime is visible in the app within five minutes | A weekly fault drill, in two parts. First, freeze the runtime by sending SIGSTOP to its pid: the Health page must show red "runtime not answering" within five minutes. Second, a hidden developer setting in the installed app makes the runtime exit at start before it takes its lease, so launchd keeps restarting it and the heartbeat goes stale: the Health page must show red "runtime stopped" with a rising restart count within five minutes. The drill runs on the same install the window measures. Switching the login item off is not a drill, because by design that shows the neutral "Background work is off (your choice)" (architecture 3.1) |

These four can all pass while the thesis stays untested. The author could make every change by hand in the app, which records ops and no external edit. A code-built "not sure" card meets the minute with the clerk switched off (architecture 5.2). A month with almost no captures passes trivially. And nothing in M3 measures whether material reaches the right binder. So this draft proposes four additions to M3, each with a proposed pass bar. They need the author's acceptance (question 9).

| Proposed addition | How it is measured | Pass bar (proposed) |
|---|---|---|
| Volume floor | Captures over the counted days, and captures per 7-day stretch outside away days. How the text was produced is not counted (decisions.md P12) | At least 40 captures in the 30 counted days. No 7-day stretch of counted days below 5 captures |
| Self-keeping share | Ops that change items in adopted binders, split by source: Tier 0 and Tier 1 cards (capture cards and nudge cards), Tier 2 proposals (a brain's), hand changes in the app, and check-offs on the hub | Tier 0 and Tier 1 ops are at least half of Tier 0, Tier 1 and hand changes together. Tier 2 and hub check-offs are reported for information and sit outside both sides of the share |
| Filing quality | The base is every item the clerk read whose final binder is on the clerk's filing list (feature 1), plus every item on a card the person rejected. Each falls in one share: filed and correct (the clerk's binder kept), filed and wrong (binder changed), rejected, or "not sure". Also: the share approved with no edit, and, from the edit records, the share where the person added an item or a date the clerk missed. Items for binders off the filing list are counted on their own line, outside the bar | Filed and correct on at least 65%. "Not sure" on at most 25%. No edit on at least 60%. A missed item or date on at most 20% |
| Currency | Counted days only: no capture or proposal pending for more than 7 days, no file waiting in a binder's `intake/` for more than 7 days, and no binder flagged "digest overdue" for more than 7 days (architecture 3.6) | Never, during the window |

The filing bars are honest about where the clerk stands. The one measured binder run gave 7 right, 1 wrong and 8 "not sure" out of 16 items (capture-event-v0 §10.5). That run picked binders in the same call as the split, a design since replaced by a separate binder call. That is 44% correct and 50% "not sure", which fails both bars. Increment 6 must improve on it. The bars are set from the fixtures before the window starts, with the author's acceptance, and never changed during it.

Three more conditions apply to all of the above:

- Days with no brain. At least 10 of the 30 counted days have no MCP call at all, by the MCP log. On those days alone, the minute, currency and the self-keeping share must also hold. That is what "zero subscriptions" means here.
- The clerk must be on. A month run with the clerk off can pass M3 and still has not proven the thesis (section 7, item 3).
- The evidence covers the larger "Core Advanced" model only. The author's Mac reports a context of 8,192 tokens and the Core Advanced model (web-apple-fm). The 3B Core model that decisions.md P2 designs for is not exercised by this dogfooding (section 6).

Two operability additions are also recommended and need the author's acceptance (architecture 13, item 30). The runtime restarts without a person after every crash, and no paused job stays unnoticed for more than a day. Beside the one-minute measure, the script reports the share of captures that got the clerk's reading within five minutes, so the code-built fallback cannot hide a slow clerk.

## 2. Who uses it first

### 2.1 The author, on live binders, adopted in place

The first and only user of the MVP is the author, on one Apple silicon Mac with macOS 27, using the binders the author already keeps. Sprava adopts each binder in place: it opens the folder where it is and converts nothing (decisions.md F1; teka-v0 §9). lifeproj and terminal agents can still read the folder.

What Sprava writes inside an adopted binder, in the MVP (architecture 13, item 36; teka-v0 §9.7):

- the hidden `.sprava/` folder, for its op log, proposals, index, cursors and owner record;
- `catalog.json`, only through approved ops;
- `DASHBOARD.md`, only after the person accepts a one-time switch card, with the old dashboard kept;
- `.teka.lock`, an empty lock file created once;
- a document folder, when the person approves a `file_document` op: a file moved out of `intake/`, or a new file a brain proposed.

It writes nothing else. Filed captures stay in Sprava's own capture store, and each op's provenance names the capture's event id (section 4). With document drop and meetings left out of the MVP, `intake/_converted/` is never written. Two of these writes go beyond decisions.md F1: `.teka.lock` and filing into document folders. That is why the F1 write list is in question 9. The binder's description for the clerk is kept in Sprava's own state, never in the binder (feature 1).

Two surveys appear in this plan, and they are different things:

- The field survey is decisions.md F11: the author's offline script, run once over all live binders. It records keys, types and counts, never values. Its job is to make the spec match reality: the shapes of `documents[]` and `processing_log[]`, the checker generations and the id forms. `documents[]` has no field schema anywhere in lifeproj's code (lifeproj-schema), and lossless adoption cannot be specified or tested without the survey (critique). So it is a gate before increment 1's format reader is frozen, and in any case before increment 3's code starts. Its results feed teka-v0 §4.3, §4.5 and the legacy mapping table of §9.5.
- The adoption check is the read-only survey Sprava runs on one binder when it adopts it (teka-v0 §9.2, which that spec calls "the survey").

This choice sets the priorities. Adopting existing binders without loss comes before anything a new user would need first, such as templates. A second person, who never opens a terminal, is the goal of the release after this one.

One fact limits dogfooding today: the shapes of `documents[]` and `processing_log[]` in the live binders are unknown until the field survey runs, because nobody but the author may look inside them (decisions.md F11).

### 2.2 What day one looks like

1. The author drags Sprava from the disk image into Applications and opens it. Sprava refuses to register its background work from the disk image or from a quarantined copy in Downloads (architecture 3.1). It asks to register its background work, and the Health page turns green.
2. Captures land in Sprava's capture folder as small files, one per capture. The person types or dictates into Sprava's note field with whatever tool they like; Sprava receives text and makes no assumption about how it was produced (decisions.md P12). Any other program may write captures there through an adapter that speaks the capture-event format.
3. The author has run the field survey over all live binders and installed the changed lifeproj (section 5, increment 3). Then the author adopts one binder, for example `~/binders/rental-elm-street`.
   - Sprava runs the adoption check without writing, keeps a byte copy of the catalog and the dashboard as found, and shows one undoable card of lossless fixes, such as a derived follow-up date on each waiting item.
   - Anything that changes meaning arrives in the review queue as its own card: closing items left with `status: done`, items that break a rule, the dashboard switch and the stamp (teka-v0 §9.4, §7.1).
   - The author writes or confirms a one-line description of the binder, such as "Rental unit on Elm Street: tenants, repairs, rent", and says whether the binder is on the clerk's filing list. Sprava offers the summary line of the binder's `README.md` as the default and never edits that file. The description lives in Sprava's own state.
   - The author pastes the addendum into the binder's manual (feature 10).
   - From this moment Sprava publishes and drains the binder for the hub, and lifeproj leaves it alone.
4. The binder's Now page shows its items in eight buckets: Overdue, Today, Next 7 days, Later, No deadline, Nudge, Waiting, Recently closed (decisions.md F4).
5. The author connects Claude Code. It reads files with its own tools, as it does today, and now proposes changes through Sprava, including filing a document. Its proposals wait in the same queue.
6. The author enters, by keyboard or by any dictation tool, "The property manager says the plumber comes Thursday. If the plumber's invoice is not in by Monday, chase the plumber." Within a minute the review queue shows a card with the words as entered, the change it proposes ("Add to rental-elm-street: Check the plumber's invoice, waiting on the plumber, follow up Monday 2026-10-12"), and Approve, Edit and Reject.
7. The author approves. The item appears on the Now page, with Undo for seven days and a history that says where it came from.
8. The existing hub (the author's current cross-binder to-do view) still shows the binder, because Sprava publishes its summary file the way lifeproj does.

The second and later binders are adopted the same way, one at a time.

## 3. In scope

Each feature names the decision it rests on and what the person sees. Terms: an op is one typed change, such as "add item" or "complete item". A proposal is a batch of ops waiting for approval. The runtime is the one background program that does Sprava's work. The clerk is Apple's on-device language model. A brain is an optional outside AI tool.

1. The Shelf. Rests on decisions.md F1, F6 and A1. The person sees every binder with its state (not yet adopted, ready, needs migration, needs attention, busy), the time since its last change, counts of overdue and Nudge items, and pending proposals. A badge shows the runtime's health. Before adoption, the list of folders comes from a read-only reading of lifeproj's registry or from folders the person picks, kept in Sprava's own state, never in a binder. "Adopt a folder" runs the adoption check of teka-v0 §9.2 and refuses folders inside iCloud Drive or another synced location, saying why (architecture 2.3). Adoption ends with the binder's one-line description and the choice of whether it is on the clerk's filing list (section 2.2, step 3). The clerk picks only among binders on that list, each offered with its description (architecture 5.3, call 2). A binder at disclosure `none` stays off the list unless the person opts it in and writes a neutral description (architecture 5.4; 13, item 16). In the MVP that case arises only for a binder created in Sprava, because a binder lifeproj can still reach stays at "full" (architecture 11). The description can be changed at any time from the binder's settings. "New binder" starts from the template (feature 6).

   A runtime instance owns the binders it adopts. Adoption writes a small owner record, `.sprava/owner.json`, naming the runtime instance (architecture 2.3). Any other instance, such as a development build, shows that binder read-only and never publishes, drains or writes it. There is no takeover flow in the MVP. A development build also refuses to adopt any folder listed in lifeproj's registry, so it works only on invented copies.

2. The Binder Now page. Rests on decisions.md F2 to F5 and Tier 0 (architecture 5.2). The eight buckets come from plain code and today's date, with no model, and still work while the runtime is stopped. The person can add, edit, complete and drop items, set an item to waiting with a follow-up date, and see each item's history and sources. `DASHBOARD.md` is regenerated only after the person accepts a one-time switch card, and the old dashboard is kept (teka-v0 §7.1). One rule for repeats and dismissals in the MVP: `recurrence` and `dismiss` are refused on every binder. An item that already carries `recurrence` is shown read-only, with the note "repeats; the hub manages it for now" (architecture 11; 13, item 34).

3. The review queue with provenance and undo. Rests on decisions.md A2 and A5. Each card shows the source first, then the change in plain words, the binder guess with the checks behind it, who proposed it, and any flags such as "date taken from the sentence" (architecture 6.1). Approve, Edit and Reject. Every approved change can be undone, for seven days from the card and at any time from the item's history. Undo appends a reversing op and never deletes history. No automatic approval. "Approve all from this capture" exists only for additive changes whose checks all passed (architecture 6.2). The nudge job adds at most one follow-up card per waiting item, such as "follow up with the property manager; they said by 10 October, 4 days ago" (architecture 3.4). Sprava sends nothing. The queue is built with adoption (increment 3), because adoption itself produces cards.

4. The capture inbox and the intake cards. Rests on decisions.md P12, C1 and C2.
   - Captures. The capture folder holds one immutable file per capture (capture-event-v0 §5). Sprava receives text; how the person produced it (keyboard, built-in dictation, a commercial tool, holos) is not its concern (decisions.md P12). Producers: the app itself, for notes entered in it (architecture 8), and any adapter that writes the capture-event format. No producer is privileged; the developer importer of capture-event-v0 §7.8 is one example adapter, not part of the plan. The person sees each capture turn into a card. When the clerk cannot run, the card is built by code with the binder set to "not sure" and says "filed by code, no model" (architecture 5.2). Meetings and documents dropped into the app are left for later (section 4).
   - Files in `intake/`. The runtime watches each adopted binder's `intake/` folder, top level only. It skips names that start with a dot, `_converted/`, `mail/`, and a file whose size is still changing. For each new file, code builds a Tier 0 card that proposes `file_document` in its intake form, which names a file already in the binder's `intake/` that the guard moves on approval (feature 10; architecture 4.3). The card shows the file name, the file's date, its size and its SHA-256. It reads no text, runs no helper and uses no model. The person picks or confirms the document folder and approves. On approval the guard checks the digest again and refuses a file that changed or is gone. If Claude Code proposes the same file, the person sees one card, with both sources named.

5. Tier 1 filing by the clerk. Rests on decisions.md P2, P3, P5, A3 and C3. The clerk reads one capture in small windows of about 100 to 150 words, lists the items it hears, picks a binder from the filing list or "not sure", and checks for duplicates against a few items from that binder's search index. Plain code resolves dates and amounts and builds the proposal. The person sees better cards: split into items, dated, filed. The Health page shows whether the model is available and, if not, why in plain words ("Apple Intelligence is off in System Settings").

6. One template. Rests on decisions.md P9 (open). A template is a starter catalog: a one-line description the clerk uses when it picks a binder, suggested document folders, and an undated checklist whose items carry `no_deadline: true`. No template carries a statutory deadline rule (decisions.md P9). Recommendation: a tax year, because it needs no chapters. A rental property with tenancies as chapters must wait, because `chapters/` is a folder convention left opaque in v0 (decisions.md F7; teka-v0 §12 question 16). The person picks the template, names the binder, for example `tax-2026`, and gets a ready v0 binder whose checklist arrives as one card to approve. A binder created in Sprava is in no cmirror configuration. So it has no backup, and `lifeproj brief` never shows its slice, until the person registers it with cmirror by hand (architecture 11). Once the lifeproj change has shipped, that registration no longer adds the binder to lifeproj's drain.

7. Slice publish and outbox drain. Rests on decisions.md A8 and F8. The hub reads a shared folder called the spool. Each binder publishes a slice there, a summary of its open items, and the hub leaves the person's check-offs in an outbox file for the binder to apply (architecture 11). Sprava publishes and drains with lifeproj's semantics. Three refinements need the author's acceptance:
   - acknowledge a completion for an item already closed (architecture 13, item 33);
   - keep the new slice fields off and publish a closed item once with `status: done` (item 35);
   - re-read the outbox just before rewriting it, and retry when its hash changed (item 43). This narrows the window in which a check-off the hub adds meanwhile is erased. It does not close it, because a plain file has no compare-and-swap without a lock both sides honour. lifeproj's own unlink of an empty outbox has the same gap (lifeproj `osavul.py`). The hub gate of increment 3 checks how the hub writes the file. If the hub recreates a missing file, the drain instead claims the file first by an atomic rename to a private name, then processes and acknowledges from that copy.

   The alarm for a slice overwritten by another program is in the MVP. Before each publish, and in the doctor, the runtime compares the slice in the spool with the hash of the slice it last wrote and alarms on a mismatch (architecture 11). It is a hash comparison, and it catches an old lifeproj, a second install or a hand copy. Holding unusual drains as cards (item 44) is left for later, because it adds new behaviour to a lane meant only for coexistence. The person sees the hub keep working as before and a "closed from the hub" list with Undo. The Google Tasks mirror stays with the hub.

8. Backup status from cmirror. Rests on decisions.md A6, narrowed for the MVP (question 9). cmirror is the author's existing tool that mirrors a folder to a cloud folder as encrypted files only, using the age encryption format. Every live binder is already registered with it, and whatever runs it today keeps running it (kickoff summary). Sprava starts no backup run in the MVP.
   - What the Health page shows for sure: for each binder, whether it is registered with cmirror, read from cmirror's configuration file (plain TOML; web-localfirst-platform), and a plain warning for a binder that is not.
   - What it shows only if spike (l) finds a reliable source: when cmirror last completed a run for that binder. cmirror keeps no plaintext state: its manifest, with its `updated_utc` time, exists only encrypted in the cloud folder (web-localfirst-platform). Spike (l) checks whether cmirror offers a read-only status command, what it prints, and what counts as a completed run when nothing changed. If such a command exists, Sprava may run it read-only, with absolute paths, and A6 is amended to say so. The warning age is then set from the author's real cmirror schedule. If no reliable source exists, the line says "last backup: unknown".
   - The author registers the capture folder and Sprava's own state folder by hand, in a separate cmirror configuration (architecture 9.3). Scheduled runs, the weekly verify, the recovery copy of the key and the restore drill move to native backup, the first feature after the MVP (architecture 13, item 13).

9. The Health page. Rests on decisions.md A1, A7 and A9. One screen, each line with a colour and the time since it last worked: runtime, jobs, clerk, captures, queue, binders, hub lane, backup status, connected brains, what left the Mac today, and the doctor's findings (architecture 3.6). The doctor's binder, catalog and runtime checks are in the MVP; the generated docs are not (section 4). A small second background job notices a crash loop while the app is closed and posts one notification (architecture 3.3). A daily notification carries counts only, such as "2 due today, 1 overdue, 3 to follow up" (architecture 3.7). With nothing configured, the outbound line reads "Outbound today: 0 bytes". The page carries operability lines only. The success measures of section 1.2 come from a developer script over Sprava's records, run from increment 5 on as a shadow run (section 5).

10. A minimal MCP surface for proposing. Rests on decisions.md M1 (open), A4 and A10 (open). MCP (Model Context Protocol) is the open standard through which AI tools such as Claude Code connect to data. Recommendation: include it, keep it to proposing, and build it right after adoption (increment 4).
    - Why: the author drives binders with Claude Code today. Its manual tells it to edit `catalog.json` directly (lifeproj-schema), and every such edit breaks the first part of M3. The author's digest also files documents: it records them in `documents[]` and appends notes to `processing_log[]` (HANDOFF, the digest ritual; critique). If Claude Code could propose only item changes, every filed document would still be a hand edit. The MVP no longer depends on it for documents: the intake cards of feature 4 file them with no brain.
    - What: a stdio shim and a Unix socket, as architecture 7.1 and 7.2 describe; the 2026-07-28 protocol era only, which Claude Code negotiates on stdio by default since version 2.1.292 (web-mcp-agents); Claude Code as the one supported client, registered at user scope by the app itself; a per-client token, per-binder scope, and one-click revoke (architecture 7.5). A conformance test runs the hand-written server against the official Python SDK v2 client, which speaks the 2026-07-28 revision (web-mcp-agents), so the server does not depend on one Claude Code version.
    - Tools: `propose_ops`, plus `list_binders` and `get_proposal`, so a proposal can name its binder and check its own status. `propose_ops` accepts item ops (add, update, set status, complete, drop), `file_document` and `add_log_entry`, and returns a handle at once. `file_document` comes in two forms: it names a file already in the binder's `intake/`, which the guard moves on approval, or it carries a new document, whose body stays inside the proposal until approval (architecture 4.6, 7.3). Approval happens only in the app.
    - Left for later: the other read tools (`get_now`, `list_items`, `get_item`, `search`, `list_proposals`, `list_documents`, `read_document`), per-client budgets and the audit log of result sizes. Claude Code already reads every binder file with its own tools, and Sprava cannot limit those (architecture 1.3, boundary 5; 7.5). Read tools matter for a client that cannot read files, and none is supported yet. Also left for later: `withdraw_proposal`, resources, prompts, elicitation, the 2025-11-25 era, and other clients. The tool list in a build stays the same for every connection (decisions.md A4).
    - Other agent tools. Every teka carries an `AGENTS.md` bridge so that any agent CLI works (HANDOFF). Only Claude Code is supported here. Codex's negotiated MCP revision is unverified (critique), so another CLI cannot simply be added. During the window, other agent CLIs are used read-only in adopted binders (section 5).
    - The manual. The paste-in addendum of teka-v0 §9.8 still lets an agent close an item by editing `catalog.json` by hand. For a managed binder this MVP asks the addendum to forbid every hand edit of `catalog.json`: propose through Sprava instead. The addendum also carries a marker line, and its text overrides the older lifeproj instructions in the same manual (question 13).
    - What the person sees: a "Connect a brain" screen that says plainly what leaves the Mac, and suggests Claude Code permission rules that deny Edit and Write on each binder's `catalog.json` and `.sprava/` and on the capture folder. Sprava cannot verify those rules, and a shell command can still write; a write that slips through shows up as an external edit. Claude Code's proposals appear in the same queue as the clerk's, marked "Claude Code".

## 4. Explicitly deferred

From decisions.md M2:

- Phone capture: the capture format is ready for it (decisions.md C2), and a phone app is a separate product.
- Sync between devices: one Mac keeps the MVP's ownership and locking simple (architecture 2.3).
- Sharing a binder with another person: it needs per-binder keys and a reason to trust another device.
- Per-binder encryption keys: designed and not needed while binders stay on one FileVault disk (decisions.md A6).
- Google Tasks export: the hub already mirrors to Google Tasks during the transition (decisions.md A7).
- Email intake: it brings credentials, other people's text and injection risk into the first release.
- Document OCR beyond short scans: in this draft, all reading of document text waits (below).
- The open-model fallback: its quality is unknown until it passes the same fixtures (architecture 5.6). If Ukrainian matters for v1, it moves in (decisions.md P8).
- Private Cloud Compute: available only to App Store apps with an entitlement (decisions.md P1).

Also deferred, as recommendations of this draft:

- Meetings, documents, images and videos as captures. They arrive through the adaptation layer of decisions.md P12, which establishes the ingestion protocol for each type of input. Its design is open; the thesis needs only text.
- Documents dragged into the app, with the extraction helper and OCR. They bring a sandboxed helper (architecture 2.1) and reading other people's text. Files in a binder's `intake/` are filed in the MVP by the code-built intake cards of feature 4, which read no text.
- The per-binder copy of each filed capture in the binder's visible `captures/` folder (architecture 8, step 5; 13, item 8; capture-event-v0 §9). It would add a file and a `documents[]` entry for every approved capture, dozens a month, to catalogs that lifeproj, terminal agents and the hub all read. The thesis does not need it: each op's provenance names the capture's event id, and the capture store is backed up in its own cmirror configuration (feature 8). It can return when sync or sharing needs a binder to carry its own captures. Needs acceptance (question 9).
- Ownership takeover after a move or a restore (architecture 13, item 45). The MVP keeps only the owner record of feature 1.
- The cross-binder Today page: the hub's roll-up keeps working through the slices, and Today replaces it after the MVP (decisions.md A8).
- Recurring items and dismissals managed by Sprava: refused on every binder in the MVP (feature 2). The hub keeps recurring items until its handling of repeated completions is checked (architecture 13, item 34).
- Backup driven by Sprava: scheduled cmirror runs, verify, the recovery-copy gate and the restore drill. They move to native backup, the first feature after the MVP (architecture 13, item 13).
- A second template, and the estate template, the commercial one, which should come third and be reviewed by someone who has settled an estate (decisions.md P9).
- MCP read tools, budgets, size audits, the legacy protocol era and elicitation (feature 10).
- Holding unusual hub drains as cards (feature 7).
- Generated docs from a capability manifest: they guard public readers against drift, and the MVP has one reader. They move to the first public build (decisions.md A9).
- "Drop your shoebox" onboarding: reading a pile of old documents needs a brain or much more code (kickoff summary, point 3).
- Automatic approval of any kind: the queue must earn trust first (architecture 13, item 26).
- The Mac App Store: it waits for the licence route (decisions.md P4, L1).

Which architecture parts the MVP builds. The architecture lists its moving parts in a complexity ledger (architecture 2.4). The table sorts each one, plus a few the ledger leaves out. "Needs acceptance" marks a deferral that changes a recommendation of the architecture, which the author must accept (question 9). Section 5 says which "In" parts shrink first when an increment runs over.

| Part (architecture 2.4) | In the MVP? | Reason |
|---|---|---|
| A separate runtime process | In | Deadlines and captures must be noticed while the app is closed |
| The single-instance lease | In | The "two sync loops" lesson |
| The heartbeat file and the watchdog | In | Part 4 of M3 |
| The outside watcher | In | A crash loop must be noticed while the app is closed; it is small |
| Persisted breaker state | In | Without it a wedging job restarts the runtime forever |
| Per-job staleness and the "wedged" mark | In | A stuck job must not show green |
| The poison-input rule | In | One bad capture must not crash-loop the runtime |
| The named jobs with budgets and breakers | In, fewer jobs, plus the intake watcher | No backup runs, no recurrence, no meeting reading |
| The transaction guard | In | The only writer |
| The op log with per-op hashes | In | Undo, provenance and part 1 of M3 |
| Keyed hashes (seals) on log lines, and rekey | Deferred, needs acceptance | With one author on one Mac, the plain hash chain still catches accidents and outside edits. Seals guard against forged history by other programs, which matters once others use Sprava |
| The binder lock | In | Needed with lifeproj and terminal agents |
| Sealed settings and the privacy high-water mark | Deferred, needs acceptance | Settings stay plain files in Sprava's state folder. The privacy ratchet stays, with the confirmed values kept unsealed |
| Proposals as files, with `expect` and a recorded digest | In | Claude Code can write files, so a rewritten proposal must be caught. The digest is kept in the runtime's own state |
| The extraction helper | Deferred | No document text is read in the MVP |
| The slice projection module | In | The hub slice must apply disclosure in one place |
| The slice-overwrite alarm | In | A hash comparison before each publish; it catches a second publisher |
| The per-binder index | In | The clerk's duplicate check |
| The clerk's call plan and the Tier 0 capture path | In | Tier 1 filing and the minute; the English and French date grammar of architecture 5.3 comes with it |
| The MCP shim and socket | In | Feature 10 |
| Per-client tokens, scope and budgets | Tokens, scope and revoke in; budgets and size audits deferred | One supported client, which only proposes |
| Dual-era MCP | Deferred, needs acceptance | Claude Code speaks the 2026-07-28 era; the legacy era waits for a client that needs it |
| XPC between app and runtime, with the code-signing check | In | Approvals must reach the only writer |
| Slice publish and outbox drain | In | The hub keeps working |
| The planning annotations store | Deferred | It holds Today-page metadata, and the Today page is deferred |
| The capability manifest and generated docs | Deferred, needs acceptance | Moved to the first public build (decisions.md A9) |
| The doctor | In, binder, catalog, runtime and hub checks | It finds what the Health page needs |
| cmirror for backup | Observe only, needs acceptance | Feature 8 |
| One publisher and one drainer per binder | In | Increment 3 |
| The heartbeat schema | In | The app trusts only well-formed health data |
| Owner records and takeover (architecture 2.3) | Owner record in, minimal; takeover deferred, needs acceptance | A development build and the installed app share the binders, so one runtime instance must own each binder. Takeover protects a binder moved to a second Mac, and the MVP has one |
| Touch ID for widening changes and client registration (architecture 2.1) | Deferred, needs acceptance | The rule that these commands are reachable only from the app's window stays |

## 5. Increments

Each increment ships on its own and is useful on its own. Each runs the spikes it depends on first (architecture 13, item 39); a spike is a short experiment for a question the research did not cover. Sizes are rough guesses for one developer, to be corrected after increment 1. With one developer every increment is serial, the holos work included.

The order follows two rules. The author's live workflow must be safe from the first adopted binder, so Claude Code over MCP comes right after adoption. And the clerk, the part that carries the thesis and the largest unmeasured risk, comes before the holos work, with its spikes at the start of increment 5.

Gate before increment 1's format reader is frozen, and in any case before increment 3's code starts: the field survey of decisions.md F11 has run over all live binders, and its results are in teka-v0 §4.3, §4.5 and §9.5 (section 2.1).

The spikes by increment:

- Run spike (a), the code-signing check on the app's connection to the runtime, first, before increment 2's watcher machinery. A failure blocks the write path. Spike (g), the runtime key in the Keychain, belongs here too unless the author accepts deferring seals (section 4).
- Increment 2 needs (b) restart, (c) bundle location, (d) the privacy permission a background agent needs to read binders in Documents or Desktop (the night sentinel reads binders), (h) notifications and (i) wake and clock changes.
- Increment 3 needs (a), (e) detecting sync locations for the adopt refusal, (g) as above, and (k) that no automation path reaches Approve.
- Increment 5 starts with (f) and (j), so the clerk's risk is known before increment 6 starts. For the MVP, (f) is restated as: on the author's Mac, with the runtime classified Background, on battery, measure approval latency, the clerk's time per window and the beat's jitter. Architecture 13, item 39 defines it on a Mac that reports the Core model, which the author lacks (question 7). (j) is what guided generation does at the answer cap.
- Increment 8 needs (l), new in this plan: whether cmirror offers a read-only status, what it prints, and what counts as a completed run when nothing changed (feature 8).

1. Read-only Shelf and Now pages. About 2 weeks.
   - Useful alone: the author sees every binder's buckets in one window, computed from today's date, without opening files.
   - Writes nothing inside any binder. The folder list comes from a read-only reading of lifeproj's registry, or from folders the author picks, kept in Sprava's own state.
   - Proves: the format reader, the eight buckets and the state table match the real binders (teka-v0 §5.2, §9.6). The conformance checks run against invented samples.
   - Main risk: the live binders hold shapes nobody has seen (decisions.md F11). The field survey, run before this increment's reader is frozen, answers it.
   - Drops first if it runs over: polish of rare states, which show a generic "needs attention" with the reason in words.

2. The runtime and the Health page. About 3 weeks.
   - Useful alone: deadlines are checked at night, a morning summary arrives, and a dead or stuck runtime shows up on the Health page and in one notification.
   - Writes nothing inside any binder. The sentinel computes buckets and writes only to Sprava's own state, since no binder has accepted the dashboard switch yet.
   - Proves: "silence is an alarm" and the five-minute part of M3, by the fault drills of section 1.2, run on the installed app with its hidden developer setting.
   - Main risk: platform behaviour the research did not cover (spikes b, c, d, h, i).
   - Drops first if it runs over: the outside watcher becomes an alarm the app shows when it opens; the Health page ships with the runtime, jobs, binders and captures lines first.

3. Adopt one binder: the guard, the review queue and the hub lane. About 6 weeks, plus about 1 week in the lifeproj repository.
   - Step one is the lifeproj change of teka-v0 §9.8, with the two refinements of architecture 13, item 31: lifeproj refuses `publish` and `drain` on any binder that has `.sprava/ops.ndjson`, and the refusal is one line and exit 0. lifeproj's own tests must pass after it.
   - Gate: the author checks against the hub that it tolerates the slice Sprava publishes and the "done once" closures of architecture 11 (architecture 13, item 35; critique), and how the hub writes the outbox file (feature 7). Until that check, how the hub treats an item that vanishes from a slice is unknown.
   - Then, together: the adoption check, the owner record, the guard, the op log, edits and undo, a minimal review queue (proposal files, Approve, Edit, Reject and Undo, with no capture source yet), the binder's description and filing-list choice, and the publish and drain of feature 7 with the slice-overwrite alarm. They must ship together. Adoption itself produces cards: one `complete` per item left at `status: done`, one card per item that breaks a rule, the dashboard switch and the stamp (teka-v0 §9.4, §7.1). Without the queue an adopted binder would stay "needs migration" with nowhere to approve anything. Once a binder is adopted, the changed lifeproj stops publishing and draining it, and with no Sprava publisher the hub would go stale for that binder. Today's lifeproj, on the other hand, drains every registered binder on the hub's schedule with no lock, and a lost update inside one of Sprava's writes cannot be detected (architecture 4.5, 11).
   - Before this increment ships, adoption is allowed only on copies kept outside cmirror's registry, and the app says so plainly. Afterwards, the author adopts one binder at a time and pastes the addendum into its manual.
   - Useful alone: the author completes, edits and adds items in the app, with history and undo, approves the adoption cards, and the hub keeps working.
   - Proves: adoption without loss, the review queue as the only door into a binder, the op log, detection of outside edits, and one publisher and one drainer per binder (decisions.md F1, A2, A5, A8, F8).
   - Main risk: the hub's code is unverified (critique), and terminal agents keep editing catalogs by hand until increment 4, which follows directly. Those edits are recorded as external edits; the window has not started.
   - Drops first if it runs over: the "closed from the hub" list ships as plain history entries; the dashboard switch card waits, and `DASHBOARD.md` stays as found.

4. Claude Code over MCP. About 2 weeks.
   - Useful alone: the author's terminal agent proposes item changes and document filings, so it can stop editing `catalog.json`. The app offers the stricter addendum for each binder's manual (feature 10; architecture 12).
   - Increments 3 and 4 together are the first release the author can use every day on live binders. From here, part 1 of M3 can be measured in the shadow run.
   - Proves: Tier 2 through the same gate (decisions.md A4, A5), and the first part of M3 becomes reachable.
   - Main risk: the token identifies a client and does not authenticate it against other programs running as the person (architecture 7.2). Claude Code's own file tools can still read and write binder folders unless its permission rules deny them (architecture 7.5).
   - Drops first if it runs over: `get_proposal`; a proposal's status is then seen only in the app.

5. The capture inbox and the intake cards. About 3 weeks.
   - Starts with spikes (f) and (j), as listed above.
   - Useful alone: every note, whatever produced its text, becomes a card within a minute, with no model, and every file put in a binder's `intake/` becomes a card to file it (feature 4).
   - Proves: the capture format, the minute, and document filing with no brain (decisions.md C1, C2, P1).
   - The shadow run starts here. A developer script computes the measures of section 1.2 that do not need the clerk: the minute, deadlines, runtime visibility, currency and, from increment 4's MCP log, part 1 and the days with no brain. This gives early evidence for the thesis long before the window.
   - Drops first if it runs over: the intake card's suggested folder; the person then picks the folder on every card.

6. The clerk. About 4 weeks.
   - Built in two steps: first the extraction and binder calls, then the duplicate check.
   - Useful alone: cards arrive split into items, dated and filed to a binder from the filing list.
   - Proves: every call fits a 4,096-token budget as Core Advanced counts tokens, on one capture at a time (decisions.md P2, P5). The 3B model's quality is untested. It also gives the filing-quality measure its data.
   - Main risk: recall and speed in the background, which spikes (f) and (j) measured at the start of increment 5 (architecture 5.3). The 3B Core model is not exercised on the author's Mac (section 6).
   - Drops first if it runs over: the French date grammar, so English ships first; then the duplicate check, so every item is proposed as new.

7. Removed (2026-10-07, decisions.md P12). It was "holos writes dictation capture events". Sprava receives text and does not depend on any producer, so no producer work is part of the MVP.

8. One template, and the backup line. About 1 week.
   - Useful alone: a new `tax-2026` binder starts in Sprava, ready and stamped v0. The Health page shows which binders cmirror backs up, and when it last did so if spike (l) finds a way to read it.
   - Proves: Sprava works for a binder it created, the path a second user will take.
   - Main risk: teka-v0 has only partial rules for creating a teka (question 3), and the choice of template is open (decisions.md P9).
   - It may ship during the window or after it, because it touches nothing the measures read.

Time. The sizes add up to 2 + 3 + 7 + 2 + 3 + 4 + 1 = 22 weeks of serial work (increment 7 removed). The twelve spikes add about 3 weeks and the review passes of section 7, item 5, about 2 more. That is about 30 weeks, or 7 months, before the window starts, then 30 counted days, so about 8 months to "done" if nothing runs over.

The 30-day window starts when all of these hold:

- increments 1 to 6 have shipped;
- every binder the author uses daily has been surveyed and adopted;
- only Claude Code acts on adopted binders; other agent CLIs are used read-only there.

During the window the build is frozen except for fixes and increment 8. A planned restart after a fix is reported as its own cause in the miss report. It costs the count only when it causes a miss that the measure counts anyway, such as a capture past its minute.

Two floors, if time runs out:

- The early floor is increments 1 to 4, about 14 weeks plus spikes. The author's live binders keep their state with provenance and undo, the hub keeps working, and Claude Code proposes through the queue. It does not test the thesis.
- The thesis floor is increments 1 to 6, about 21 weeks plus spikes, which is now also the full set the window needs.

If MCP has to be cut for time, the author runs Claude Code under the deny rules of feature 10 and accepts that its edits are recorded as external edits, which fail part 1 of M3.

## 6. Dependencies and risks

| Dependency or risk | What could go wrong | Mitigation |
|---|---|---|
| Two runtimes on one binder | A development build has its own Application Support folder and socket (architecture 3.2), so its own lease and capture journal, while the binders are shared. Two runtimes adopting one binder would mean two publishers, two drainers and duplicate cards | The owner record of feature 1: one runtime instance owns each binder, and others show it read-only. A development build refuses folders in lifeproj's registry. The drill switch lives in the installed app behind a hidden developer setting, so dogfooding and measuring use one install. The slice-overwrite alarm catches what slips through |
| cmirror | When another run holds its lock, cmirror exits 0 with a skip message. A LaunchAgent cannot find a Homebrew `age` because it does not get the shell's `PATH`. Registering a binder in cmirror's default config also enrols it in lifeproj's fleet drain (architecture 3.5, 9.3). cmirror keeps no plaintext record of its last run (web-localfirst-platform) | The MVP starts no cmirror run, so a second scheduler of the same tool never starts. It reads registration from the configuration file and reads the last run only if spike (l) finds a read-only way. The capture folder and Sprava's state go in a separate cmirror configuration. Native backup comes next |
| The 4,096-token budget and the 3B model | The 8,192-token window belongs to the larger Core Advanced model on M3 or later Macs with at least 12 GB. The 3B Core model keeps 4,096, a figure from Apple staff that nobody has measured on hardware (web-apple-fm). The author's Mac runs Core Advanced, so the clerk's release gate of architecture 13, item 23 needs a Mac that reports the Core model (an M1 or M2, or an M3 or later with 8 GB; architecture 5.1), which the plan does not otherwise have. On the M5, a 750-word note with 20 items would take about 65 to 70 seconds, estimated from measured call times (architecture 5.3) | Every call fits 4,096 tokens with over 2,400 to spare, so recall and time are the real limits. Spike (f), restated for the author's Mac, runs at the start of increment 5. A code-built card meets the minute and the clerk's reading follows. Recommendation: the MVP gates the clerk on the author's model variant and turns it off, leaving Tier 0 cards, on any Mac that reports another. The 3B release gate moves to the release that adds a second user, unless the author has such a Mac sooner (question 7) |
| MCP eras | Clients sit on two protocol eras, the stateless 2026-07-28 revision and the older `initialize` revisions (2025-11-25, and 2025-06-18 for Gemini CLI; architecture 7.8), and a server built for one fails with the other. The official Swift SDK is Tier 3 at 0.12.1 and covers 2025-11-25 only (web-mcp-agents) | The MVP supports Claude Code alone, on the modern era, with a hand-written Swift server, as recommended pending decisions.md A10, tested against the official Python SDK v2 client as well. The legacy era comes before any release that names Claude Desktop or Gemini CLI (architecture 13, item 3) |
| Names | An AI company filed "Osavul" for software in the EU, the UK and the US the week of 2026-09-29. Teka Industrial holds "Teka" for appliances and ships a "Teka Home" app. "Sprava" has no live mark in classes 9 and 42 in the US, Canada or the EU, but an npm package, sprava.ai, sprava.dev and two iOS apps use it, and nobody has searched for confusion with "Strava" (decisions.md P11; web-license-name) | The MVP is private to the author, so no name is announced. "Osavul" stays a private codename and "teka" a lowercase format term. A clearance opinion comes before any public build. Registering sprava.app and sprava.ca is the author's call |
| The licence | The repository says LGPL-2.1 today. The author leans to GPL-3.0 (decisions.md L1). The App Store conflicts with GPL and LGPL alike | The MVP ships as a notarized disk image to one person, so nothing blocks it. Settle L1 and L2 before the first public build, and adopt the App Store additional permission while there is one copyright holder (decisions.md L1) |
| lifeproj as a second writer | Today's lifeproj drains and publishes every registered binder on the hub's schedule, with no lock, and ignores privacy settings (architecture 11). Every live binder is registered with cmirror, whose configuration is lifeproj's registry (kickoff summary) | The lifeproj change is step one of increment 3, and no live binder is adopted before it ships. Until then adoption runs only on copies outside cmirror's registry. Disclosure stays "full" on any binder lifeproj can still reach, and the doctor flags it |
| The unseen hub | The hub's code was not researched, so its tolerance of the slice, of "done once" closures, of an id that vanishes, and how it writes the outbox are unknown (critique) | The author checks it before increment 3 ships. Keep the new slice fields off and publish lifeproj's exact projection until then (architecture 13, item 35) |
| Schedule | About 8 months to "done" for one developer, and the MVP keeps most architecture parts "In" | Each increment names what drops first if it runs over. The early floor and the thesis floor of section 5 say what still has value |
| Platform gaps | Eleven questions the research did not cover, such as how the app proves its identity to the runtime, Keychain behaviour while the screen is locked, and how to restart a stuck agent (architecture 13, item 39), plus spike (l) on cmirror | Run each spike before the increment that needs it, as listed at the top of section 5, and record the result in the architecture. Spike (a) runs first |

## 7. What "done" means

The MVP is done when all of these hold:

1. All eight increments have shipped and every binder the author uses daily is adopted.
2. The success criterion of section 1.2 held for 30 counted days, with the misses, drills, away days and outbound counters kept as evidence.
3. The clerk was on for the whole window and passed its gate on the author's model variant (section 6). An MVP run with the clerk off, or shipped with it off, has not proven the thesis, whatever M3 says.
4. The conformance checks of teka-v0 §11 and capture-event-v0 §11 pass for Sprava, and lifeproj's own test suite passes after its change.
5. The author ran the design-skeptic pass on this plan before code, and after building ran a hostile-eyes review, specialist reviews, a simplification review and a security pass, re-verified after each fix wave (HANDOFF, "How the author works").
6. The doctor reports no "fix" findings, and the author restored one binder from cmirror into a temporary folder by hand. In the MVP these are "fix", and each is a setup task in the increment named: a managed binder still drained or published by lifeproj (increment 3), and a managed binder whose manual lacks the addendum's marker line (increments 3 and 4). A manual that holds the marker line passes, because the addendum overrides the older lifeproj text about `lifeproj drain`, `lifeproj publish` and hand edits of `catalog.json` that stays in the same file. These are "note": a cmirror `encrypted_dir` that contains the binder's name (architecture 9.1), a missing `index.sqlite*` exclude in a cmirror project (the index can be rebuilt; architecture 9.3), and binders that Spotlight indexes (architecture 10).
7. The app is a notarized disk image that installs on a clean Mac and adopts an invented binder such as `kitchen-reno` without help from a terminal.
8. A privacy scan of the repository finds no personal data. Generated docs wait for the first public build (section 4).

## 8. Open questions

1. Minimal MCP in the MVP (decisions.md M1). Recommendation: yes, as feature 10 describes, cut to `propose_ops`, `list_binders` and `get_proposal`, with `file_document` and `add_log_entry` accepted alongside item ops, built right after adoption. Without it the author's terminal agents keep editing catalogs by hand, and the first part of M3 cannot be met. Documents no longer depend on it: the intake cards file them with no brain.
2. The template (decisions.md P9). Recommendation: one, a tax year, because it needs no chapters. The handoff asks for one or two. A second one, such as a rental property or a condo-board seat, comes after the MVP.
3. Creating a binder. teka-v0 has only partial rules for it: a created teka's name matches `^[a-z0-9][a-z0-9-]*$` (§3.1), its disclosure starts at `none` (§4.2), and its op log starts with an `import_snapshot` of the freshly scaffolded catalog (§6.9). Recommendation: the app writes an empty stamped v0 catalog, records it with that `import_snapshot` as the first op, and offers the checklist as one proposal. Accept, and add the rest to teka-v0?
4. Closed (2026-10-07). The holos hook is out of scope: Sprava receives text and does not care how it was produced (decisions.md P12).
5. The field survey of the live binders (decisions.md F11). Recommendation: run it once over all live binders before increment 1's reader is frozen, and feed its results into teka-v0 §4.3, §4.5 and §9.5. Adoption without loss cannot be specified or tested until it runs, and no `documents[]` write happens in a live binder before it.
6. Ukrainian (decisions.md P8). If it matters for v1, the open-model fallback moves into the MVP and its quality is unknown.
7. Minimum hardware and the clerk's gate (decisions.md P2; architecture 13, item 23). Recommendation: every Apple silicon Mac that runs Apple Intelligence, with the clerk gated by model variant. For the MVP, gate on the author's variant only. Does the author have access to a Mac that reports the Core model?
8. The lifeproj change (architecture 13, item 31). It is step one of increment 3. Will the author make it in lifeproj, and check the hub, including how it writes the outbox, before it ships?
9. Refinements this plan relies on, each needing the author's acceptance:
   - decisions.md M3: the four additions of section 1.2 (volume floor over the window, self-keeping share on Tier 0 and Tier 1 alone, filing quality with a ceiling on "not sure", currency including `intake/`); away days; at least 10 counted days with no MCP call; measuring the minute from the end of the capture (`ended_at`, else `captured_at`), where M3 says "of landing"; producer lag reported apart; the narrower backfill rule; the operability additions of architecture 13, item 30; measures computed by a developer script.
   - decisions.md M1: one template instead of two; text captures from any source and code-built intake cards only, with meetings, documents, images and videos deferred to the adaptation layer (P12); backup observed instead of driven; MCP limited to proposing, with `list_binders` and `get_proposal` and no read tools, where M1's open item says "reads and proposals".
   - Adoption adds a step: the person writes or confirms a one-line description of each binder and decides whether it is on the clerk's filing list. It is kept in Sprava's own state, and `README.md` is never edited.
   - decisions.md A6: the MVP starts no cmirror run. It reads registration from cmirror's configuration file, and the last run only through a read-only status call if spike (l) finds one.
   - decisions.md A4: the 2026-07-28 era only; no read tools beyond `list_binders` and `get_proposal`; no `read_document`; no elicitation; no `withdraw_proposal`; no budgets.
   - decisions.md P7: the developer importer runs every minute inside the installed app's runtime, behind a hidden developer setting, with an absolute path to `voiceislocal`. capture-event-v0 §7.8 describes a developer build with `voiceislocal` on the `PATH`, and architecture 8 says the importer is run by hand and not supervised by the runtime. Architecture 13, item 46 lists this and the other changes this plan asks of the architecture.
   - decisions.md A9: generated docs move to the first public build; the doctor stays.
   - decisions.md F1: the write list of section 2.1 (architecture 13, item 36), now without the visible `captures/` folder. Deferring the per-binder capture copy changes architecture 13, item 8 and capture-event-v0 §9.
   - decisions.md F5 and F8, for the hub lane: architecture 13, items 33, 35 and 43, with item 43 described as narrowing the window in which a check-off can be lost. It does not close it. Item 44 is deferred.
   - The architecture deferrals marked "needs acceptance" in section 4: seals and rekey, sealed settings, ownership takeover (with a minimal owner record kept), Touch ID gating, dual-era MCP, generated docs.
   - Architecture 13, item 23: the clerk's gate on the author's variant for the MVP, and spike (f) restated for the author's Mac.
10. UI toolkit (decisions.md P10) and the MCP server stack (decisions.md A10). Both shape the first increment's code.
11. The update channel for a disk-image app (architecture 13, item 29). Decide before any build leaves the author's Mac.
12. A second user. Should "done" include one non-technical person running Sprava on invented binders for a week?
13. Spec request for teka-v0 §9.8. The addendum agents paste into a managed binder's manual should forbid every hand edit of `catalog.json`, including closing an item by moving it into `processing_log[]`, and tell the agent to propose through Sprava instead. It should open with a marker line and say that it overrides older instructions in the same manual, so the doctor can check for it. Accept, and change the spec?
14. Spec change made for this plan: capture-event-v0 now has an optional `ended_at` field (capture-event-v0 §3, §4.3; `docs/spec/schemas/capture-event.schema.json` and its reader schema). It lets the minute be measured from the end of a capture without reading holos's extension. It is optional, so `format_version` stays `0`. Accept it, and add it to decisions.md C1?

## 9. Design-skeptic pass

### 9.1 First pass

Lenses used: does the success criterion test the thesis; is the build order safe for live binders next to lifeproj and the hub; is the scope the smallest that proves the thesis; which dependencies sit outside the plan (holos, hardware, spikes); does the plan agree with decisions.md and architecture.md.

Serious findings, and what changed:

- M3 could pass with the clerk off, with everything done by hand in the app, or with almost no captures. Section 1.2 now proposes a volume floor, a self-keeping share, filing quality and currency, and section 7 says a clerk-off MVP has not proven the thesis.
- Increment 3 adopted live binders while today's lifeproj still drained them without a lock, and doing the lifeproj change first would have left adopted binders with no publisher. Adoption and the hub lane are now one increment, with the lifeproj change as its first step and the hub check as a gate.
- Claude Code could propose item changes only, so every document filed in a digest would have been an external edit. `propose_ops` now accepts `file_document` and `add_log_entry`, and the addendum is asked to forbid hand edits.
- No increment built the holos feature, the importer ran by hand, and latency was counted from the file landing. An increment now builds the dictation part of holos's feature, the importer runs every minute, and holos on the same Mac is a precondition for the window.
- Scope was wider than the thesis: meetings, document drop, a full MCP read surface, a cmirror scheduler, two templates, generated docs. Each was cut or moved, and section 4 sorts every architecture part into "in" or "deferred".
- The 3B release gate needed hardware the plan never listed. The MVP gates on the author's model and says its evidence covers Core Advanced only.

### 9.2 Second pass

Lenses used: can each measure pass while its claim is false; is each fact traced to its source (holos's `date`, lifeproj's `meta`, cmirror's state); do the increments respect their real dependencies; is the schedule honest for one developer; does the MVP depend on a brain anywhere.

Serious findings, and what changed:

- The minute was measured from `captured_at`, which is the start of a capture (capture-event-v0 §4.3; holos's `date` is the draft's start). Almost every dictation would have missed. It is now measured from the end of the capture, with an optional `ended_at` added to the capture format, and producer lag reported apart.
- Filing quality left "not sure" and rejected cards out of its base, so a clerk that rarely commits would pass. The base now holds every item the clerk read, with a ceiling on "not sure". The one measured run would fail the new bars, and the plan says so.
- The self-keeping share counted a brain's proposals and hub check-offs. Its bar now rests on Tier 0 and Tier 1 alone, and "no outside AI tool" became a count of days with no MCP call.
- Documents could reach a binder only through Claude Code, so the MVP needed a brain. Code-built intake cards now file files from `intake/` with no model, and currency watches `intake/`.
- The clerk had no binder descriptions to choose from, because adopted binders carry none Sprava can read. Adoption now asks for one, kept in Sprava's own state.
- Adoption produces cards, but the queue came two increments later; Claude Code over MCP came after holos; the clerk came last. The queue now ships with adoption, MCP follows it directly, and the clerk comes before holos with its spikes earlier.
- A development build and the installed app could both adopt one binder. A minimal owner record, a refusal of lifeproj's binders in development builds, and one install for dogfooding and drills now prevent it. The slice-overwrite alarm is back in the MVP.
- The field survey of F11 and the adoption check were confused, which placed F11 too late. F11 is now a gate before increment 1's reader is frozen.
- The schedule claimed parallel work with one developer. Section 5 now gives the serial total, about 8 months to "done", what drops first in each increment, and two floors.
- The backup line read a time cmirror does not keep in plain form. It now shows registration for sure, and the last run only if a spike finds a read-only source.
- Smaller fixes: one rule for recurrence; the per-binder `captures/` copy deferred; the window no longer waits for the template; measures computed by a developer script; away days; the deadline replay keyed to the summary's own time; the outbox refinement described as narrowing the window; the doctor accepting the addendum's marker line; other agent CLIs read-only during the window, with an MCP test against a second client; spike (f) restated for the author's Mac.
