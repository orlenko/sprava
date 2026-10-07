# Sprava: what it is, as I read it, and where I'd push back

> Written 2026-10-06 by the planning session that received `HANDOFF.md`, after reading the
> reading list and the lifeproj and holos code. Audience: the author. Examples are invented;
> nothing here comes from a real binder. Draft: a few facts marked *(to confirm)* are being
> checked against current sources.

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
a local open model as fallback). It works on one capture at a time: cleans it up, splits it into
items, pulls out dates, amounts and people, guesses which binder each item belongs to, and
proposes changes. Tier 2 is optional: Claude, Codex or any agent that speaks MCP connects to the
same binders for the hard work, such as reconciling a long binder, drafting a careful letter or
cross-referencing documents. Both tiers propose through the same typed operations, and nothing is
applied until the person approves it. No subscription is needed for Tier 0 or Tier 1.

**Capture comes from holos.** The dictation app keeps working on its own. With Sprava installed, a
dictated note becomes an immutable capture event in a versioned format, and Sprava files it.
Later a phone app can write the same events into an append-only inbox, which is why capture can
sync before anything else does.

**The product is the discipline, not the model.** Current truth plus provenance; nothing outbound
without approval; compartments (a litigation binder no agent or other device can see into); a
case file per episode rather than a memory profile of the person. That is what the cloud agents
launched this September cannot offer, and it is the whole positioning.

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
   nearly free, because nothing is converted.

2. **The clerk emits interpretations, not ops.** The handoff asks for guided generation so the
   clerk emits typed ops. I'd have the on-device model emit a small, stable *interpretation* of one
   capture (the items it heard, each with a title, a time expression, people, an amount, a binder
   guess, a confidence, and the span of transcript it came from) and have plain code turn
   interpretations into proposed ops. Why: the op vocabulary will change and must stay validated
   independently of any prompt; a 3B model is more reliable on one flat schema than on a growing
   union of op types; "Thursday" should be resolved by code from the capture's own timestamp and
   locale, not by the model; and the interpretation is exactly the derived event the capture-event
   spec needs. What it changes: a deterministic proposal builder in the runtime, and a derived-event
   model in the capture spec defined around interpretations.

3. **Tier 1 is narrower than the brainstorm hopes, and the MVP should say so.** With about 8k
   tokens *(to confirm)* and a 3B model, the clerk is good at captures and short documents and poor
   at long ones. I'd scope Tier 1 to: normalize a capture, split it, extract fields, pick a binder
   from a closed list, check for duplicates against a handful of retrieved candidates, title and
   date a short document, and draft a one-line nudge for a waiting item. Reconciling a binder,
   cross-referencing documents and drafting letters stay Tier 2. The brainstorm's make-or-break
   moment ("drop your shoebox, see your first Now page in minutes") needs Tier 2 or a lot of
   deterministic scaffolding, and the MVP should not promise it. The honest Tier-1 pitch is "the
   clerk files; the brain thinks".

4. **Encryption is a property of the container, not of the format, and per-binder keys are not
   MVP.** The handoff lists root key, per-binder keys and ciphertext-only backup under
   architecture. I'd design all three but keep encryption at rest outside the format: binders are
   plain folders (FileVault protects the disk), offsite backup is ciphertext only with one root key
   in the Keychain (the model cmirror already uses), and per-binder keys arrive with sharing and
   sync in Phase 2. Why: an encrypted-at-rest binder can't be read by lifeproj or by a terminal
   agent, which kills the second implementation; key management is the second onboarding cliff the
   brainstorm itself warns about; and compartments against *agents* on a single-user Mac are a
   policy and MCP-surface matter, not a cryptographic one. What it changes: the MVP has one secret
   to guard, as today.

5. **The briefs lane is not a format contract.** The handoff asks for slice, outbox *and briefs*
   contracts in `teka-v0`. The briefs lane is provisional and hub-specific (reading a meeting brief
   on a second screen). In Sprava it is a product feature, documents readable in the app, not a
   format. I'd leave it out of v0, keep the agenda slice and outbox as an optional *federation
   profile* for coexistence with the existing hub and for any future split-process deployment,
   and define the redaction `kind` there.

6. **Osavul becomes a Sprava view; the spool stays as an interop lane.** (This answers one of the
   open questions.) Inside one app there is no process boundary to enforce federation, so the
   boundary becomes policy: each binder carries a disclosure setting (full, title only, kind only,
   nothing) that decides what the cross-binder Today page may show. The spool stays so the
   existing hub keeps working while binders move over one at a time, and so a sandboxed terminal
   session can still publish. The web lens retires when Today covers it.

7. **The license question is really two questions.** (You said GPL-3.0 is on the table; I'd take
   it.) First, the app: GPL-3.0 matches holos, protects the runtime from proprietary forks, and the
   capture-event boundary stays the right design for product reasons even if linking were
   allowed. The App Store is the complication for GPL and LGPL alike; the sole copyright holder
   isn't bound by the conflict, outside contributors would need a CLA or an explicit exception, and
   holos already uses the model that works: GPL code with a trademarked name and icon *(App Store
   facts to confirm)*. Second, the spec, schemas, validator and conformance tests should be
   permissive (MIT or Apache-2.0 for code, CC-BY-4.0 for prose) so other implementations can exist
   without a second thought.

Things I agree with and would only sharpen: the single supervised runtime; typed ops behind a
transaction guard; the Nudge bucket and `expected_by`; redacted items publishing a kind; a
deterministic deadline sentinel that runs before any model; hybrid logical clocks on capture
events (cheap now, needed later); generated docs plus a `doctor` command.

## Open questions

The handoff's six, with my recommendation where I have one:

- **Minimum macOS.** 27-only, like holos: the larger context, the `fm` tools and image input are
  macOS 27 features *(to confirm)*. The open-model fallback covers Macs where Apple Intelligence is
  unavailable in the region, not older systems.
- **App Store or direct DMG.** Direct notarized DMG first (holos already has the release script);
  App Store later, only if the license route is settled.
- **License.** GPL-3.0 for the app, permissive for the spec (above). Confirm.
- **Multi-device sync in v1.** No. Mac-only, with the capture-event format designed so the phone
  inbox can ship early.
- **First templates.** Pick the ones you live, so they get dogfooded: a rental property with
  tenancies as chapters, a condo-board seat, a tax year. Estate executor is the commercial one,
  but a template nobody uses will be wrong; it should come third, reviewed by someone who has done
  it.
- **Sprava and Osavul.** Answered in push-back 6.
- **Trademark and domain.** Web check in progress; findings go at the end of this file.

Mine:

- **Backup.** Should the MVP call cmirror for backups (it exists, and every live teka is registered
  with it) and replace it natively later, or ship its own from day one?
- **lifeproj's future.** Does it keep evolving as the terminal implementation of the spec, or
  freeze? If it evolves, every spec change lands twice.
- **The local open-model fallback.** Not in MVP, only the seam? Your Mac has Apple Intelligence;
  the fallback matters for other regions.
- **UI toolkit.** holos is AppKit. Same for Sprava, or SwiftUI with AppKit where needed?
- **Dogfooding from day one.** I'm assuming the MVP opens your live tekas in place on the first
  day it can. That decides the priority of the adopt-in-place path over everything else.
- **The hub during the transition.** I'm assuming the existing hub, spool and Google Tasks sync
  keep running until Today covers them.

## What I'm drafting next

`docs/spec/teka-v0.md`, `docs/spec/capture-event-v0.md`, `docs/architecture.md` (with the skeptic
pass), `docs/mvp.md`, and a refreshed competitor section for the brainstorm. All as drafts for
you to commit or not.
