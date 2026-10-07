# Life Projects as a Product: Brainstorm

> **Provenance.** Written 2026-10-06 in the author's hub ("Osavul") session as the kickoff brainstorm for
> Sprava, from lifeproj's design docs, two weeks of operating the existing system, and web research.
> Personal and project-specific details have been removed for this public repo.
>
> **Decisions made after this was written** (they override the text below):
> - **Name:** the product is **Sprava** (Ukrainian *справа*: a matter, an affair, a case file).
>   "Teka" stays the name of a single binder / the open file format; "Osavul" stays the cross-binder hub.
> - **Positioning:** do **not** compete with OpenAI dots / Meta Muse on cloud proactivity. Sprava is
>   **fully local on the Mac, usable with no AI subscription**; Claude/Codex/etc. are an optional
>   "strategic brain" add-on (see `docs/HANDOFF.md`).


**Strongest recommendation:** Sell "a binder that keeps itself". Open up the *format* (the teka spine, catalog schema, slice and outbox contracts) and charge for **one supervised local runtime** with a GUI. Inside it, the agent is a clerk that proposes typed changes and the human approves them. The product is the discipline (current truth, provenance, nothing outbound without approval). The model is not the product.

**Riskiest assumption:** that agent-maintained state can stay correct for months with no technical operator watching it. Today it works because the author is the supervisor (re-dating waiting items, notices dead monitors, reads raw 429s). A product has to replace him with machinery, or the trust story falls apart.

*Legend: **[web]** = verified in current sources (links at the end). Everything else is my own reasoning from lifeproj's `docs/DESIGN.md` (github.com/orlenko/lifeproj), the hub's operating manual, and the failure modes you gave me. Many market sources are 2026 review and SEO blogs. Treat feature claims as indicative, not audited.*

---

## 1. Keep exactly as-is

- **Current truth plus an append-only log** (`catalog.json` + `processing_log[]`, a dashboard regenerated from it, a validator guarding it). This is the core of the whole thing. A session never re-reads the whole project to know where things stand, which is the main time-saver and the main defence against drift.
- **The task schema's honesty rules.** `due` XOR `no_deadline` ("nothing silently dateless"), `waiting_on` required when waiting/blocked, ids never reused. These are small rules with a large effect, and most task apps lack them.
- **"Monitors flag, humans act."** Never send, sign, pay or commit anything outbound without approval; drafts wait for review. In a legal/financial product this is the liability posture and the trust UX, not just a guardrail.
- **Federation with an ownership rule.** The hub reads published slices only. It closes items by *writing a completion the project drains*, never by editing the project. Self-registration means the file appearing *is* the registration. The round trip (hub done → project drains → Google closed) worked cleanly. Keep both the contract and the direction of writes.
- **Discretion by design.** `slice_title`, `redact: true`, and "never publishing is legal". For divorce, litigation or estate disputes this is a differentiator no competitor has. One project can be invisible to the household view, to a shared spouse, or to the cloud tier.
- **Plain files, user-held keys, ciphertext-only offsite.** "One secret to guard; everything else self-restoring" (DESIGN §7) is the right recovery model. Keep that shape even when the storage changes.
- **Two axes, not one "kind"** (intake × artifact + lifecycle), plus **chapters** for finite episodes inside ongoing projects. This maps directly onto real life: a property is ongoing, each tenancy is a chapter.
- **Deterministic loop, LLM for judgment only.** `drain --all` → roll-up → sync are plain CLIs, and the model classifies, extracts, drafts and reconciles. This is what makes the system affordable and debuggable.
- **The agent-agnostic manual.** `AGENTS.md` is now an open standard under the Linux Foundation's Agentic AI Foundation, alongside MCP, and Agent Skills is a companion open standard **[web: Linux Foundation, TechCrunch]**. Your bet was right, and the industry has formalized it.
- **The small UX wins.** GTD physical contexts ("what can I do right here?"), recurrence semantics (done advances the date, dismiss ends the cycle), and phone-readable briefs during a live meeting.

## 2. Do better / approach differently

**a. One supervised runtime instead of a process zoo.** Ship a single daemon (`tekad`) as an OS service (launchd / systemd / Windows service, installed by the app). It owns every recurring job: intake watch, roll-up, sync, server, scheduled digests. Each job has a heartbeat, a single-instance lease (generalize the watcher's flock) and a liveness target that shows in the UI ("Google sync: last success 3 min ago"). **Silence is itself an alarm.** Agent sessions become *clients* of the runtime and never host a monitor. That one rule removes the whole class of problems seen in the last two weeks: a session-wrapper restart killing monitors, a temp-file cleaner deleting a monitor script, two sync loops running for a week unnoticed.

**b. Make the op log the source of truth and the catalog a materialized view.** Today `state/app/ops.ndjson` is an audit log that is "never replayed". Flip it: every change, whether from the agent, the user, a sync or a drain, is a typed, validated op with provenance (who, which tier/model, which source document). `catalog_check.py` turns from an after-the-fact lint into a **transaction guard**: invalid ops are rejected. This one change gives undo, multi-device merge, "why does this say that?", and a clean answer to "the agent did something wrong".

**c. Agents call typed ops; they never hand-edit `catalog.json`.** Expose the project to agents as an MCP server: `add_item`, `set_status`, `file_document`, `propose_draft`, `publish`. Agent independence then moves from "every CLI reads CLAUDE.md" to "every agent speaks MCP to the runtime". That is sturdier and works the same for a GUI agent.

**d. Integrations push and fetch only changes; they don't poll per item.** Google Tasks `tasks.list` takes `updatedMin` (plus `showCompleted`/`showHidden`), so the read-back can be **one list call per tasklist per cycle** instead of one GET per item ever published **[web: Google Tasks API reference]**. Calendar has `syncToken` incremental sync plus `watch` push channels. Those channels expire within days and must be renewed, and an expired token returns 410, which means do a full resync **[web: Google Calendar push docs, Nango]**. Product rules that follow:
- every connector has a **quota budget** it enforces itself;
- errors are first-class state and are never regex-filtered out of the dashboard (the invisible 429);
- OAuth runs in production mode, with token expiry surfaced *before* it bites (the 7-day "Testing" expiry);
- longer term, **own the phone surface**, so Google Tasks becomes a one-way export rather than the control loop.

**e. Staleness as a typed concept.**
- `waiting` items get `expected_by` / `follow_up_at` instead of `due`. "Overdue" applies only to *your* moves. Waiting items age into a **Nudge** bucket with a pre-drafted follow-up. That alone turns 17 "overdue" into 4.
- A project that hasn't been digested in N days generates its *own* item ("the kitchen-reno binder needs a digest, 6 new intake files"). The runtime can also run a **headless digest** on new intake, which produces proposals for review and does not wait for you to open a session.
- Redacted items still publish a non-sensitive **kind** (`legal-deadline`, `payment`, `reply-owed`), so the hub can triage what it can't read (a real case: a fully redacted project whose items the hub could not triage at all).

**f. Answer questions about a project without breaking federation ("ask-through").** Keep the hub blind. When you ask "what is this overdue item about?", the hub sends a scoped question to *that project's* agent. It runs under the project's own policy and replies with what the project allows to be disclosed. Add an optional publish-time `context` field with three disclosure tiers: title → blurb → full. The boundary becomes **policy, not process isolation**, so privacy stays the same and answerability improves. (This is a2a for asks, exactly as your guardrail intends, made a first-class feature.)

**g. Real security.** Pair devices with per-device keys or passkeys instead of relying on the bind address. Keep secrets in the OS keychain, never in shell rc files. Reach the app from the phone through the E2E sync relay, not an open port. Also: no reverse DNS lookups on the request path (the 35-second hostname lookup).

**h. Hooks and plugins get budgets and circuit breakers.** The runtime times every hook, trips a breaker on repeat offenders, and *names* the culprit. The 30-second iTerm hook would have shown up as "hook X: p50 30s, disabled".

**i. Generate the docs from the code.** The mechanical sections of the manual (sync direction, routes, capabilities) are rendered from a capabilities manifest. Only policy stays hand-written. That fixes "the manual said one-way months after read-back shipped". Add a `doctor` command that checks manual against reality.

## 3. The product

**Who it's for**
- **The Operator** (you): terminal, multiple agents, wants files. A small group, but they are the evangelists and template authors. Served by the open format + CLI + MCP.
- **The person in an episode (the core market):** executor of a parent's estate, someone going through a divorce, a renovation or move, an immigration case, a complicated tax year, an aging parent's care, a small landlord, a condo/HOA board member. They have a shoebox of paper, deadlines, several other parties, high stress, and no system. They are graphical users.
- **The household CFO / sandwich generation:** ongoing, several projects at once, needs to *share* one binder with a sibling or spouse without sharing the others (your redaction model, applied to people).
- **Channel personas:** estate lawyers, accountants, care managers, insurers. Empathy, for example, is distributed through life insurers and employers **[web]**.

**Positioning:** *Case management for your life.* It isn't a second brain (notes), a task app (lists), a concierge (humans doing things for you) or a document vault (static storage). It does what a good paralegal or case manager does: files everything, always knows the next move, drafts, never acts without you. Private by construction.

**Names.** "Book of Life Projects" is too long, and "Book of Life" carries strong religious and film associations. My pick: **Teka** as the brand and format name. It's short, ownable and has a real meaning (a curated folder on one subject). Tagline: *"a binder that keeps itself."* Alternatives: **Casebook**, **Dossier**, **Folio**. Name the hub **Steward** or **Chief** in the consumer product and keep "Osavul" as a nod for the power users. (I did not run trademark searches. Do that before committing.)

**Core UX metaphor: a shelf of binders and a clerk.**
- **Desktop (three panes):** Shelf (binders, each with freshness and a count of next moves) | Binder (tabs: **Now**, Inbox, Documents, People, Timeline/Ledger, Drafts) | Clerk panel.
- **Now** is the dashboard: current truth in plain sentences plus "your next 3 moves".
- **Today**, across all binders, uses your existing WHEN-spine / WHERE-filter design.
- **The main interaction is the review queue, not chat.** "While you were away I filed 4 documents, added 2 deadlines, drafted 1 reply. Review." Every card shows its source (document page, email) and has approve, edit or undo. Chat is secondary.
- **Mobile:** capture (dictation, camera scan, share sheet, forward-to-binder email address), Today, approvals, briefs reader, "I'm at X, what's quick?".
- **Onboarding from a trigger:** "I'm settling a parent's estate" → a binder with modules switched on and a seeded checklist. Then "drop your pile here" bulk import, after which the clerk builds the binder and shows its first Now page within minutes. That first Now page is the moment that makes or loses the sale.
- **What a non-technical person sees:** never `catalog.json`. They see "Tidied 2h ago · 3 changes waiting for your OK · every fact links to where it came from."

## 4. Agent strategy

Resolve the tension in three layers:
1. **Open format** (the teka spec: spine, catalog/op schema, slice/outbox/briefs contracts, `AGENTS.md` + Skills). Agent-neutral by standard, not by convention.
2. **The runtime as an MCP server.** Any agent that speaks MCP can maintain a binder, but only through validated ops. The runtime does scheduling, sync, reminders and deadline monitoring deterministically.
3. **One default experience.** Ordinary users get a bundled clerk and never choose a model. "Bring your own agent" (Claude Code, Codex, multi-CLI wrappers, local models) is an advanced setting for the Operator persona.

**[web]** Apple's WWDC26 Foundation Models update shows the same pattern at OS level: a `LanguageModel` protocol lets one app call the on-device model, Private Cloud Compute, or third-party models (Anthropic and Google are confirmed) through one API, and the framework is being open-sourced. So "pluggable agent runtime under one default" is where the platforms are heading, and you can build on it on Apple devices. Also: ordinary users won't juggle model accounts or quotas the way a power user does. The default tier must be **metered by you** (or use the user's one subscription), with batch processing to keep costs predictable.

## 5. Offline-first + on-device models

**Tiers.** Each item is routed by sensitivity × difficulty × connectivity. This is your typed-judgment routing, done locally.

| Tier | Where | Jobs | Writes |
|---|---|---|---|
| **T0 capture** | any device, no model | dictation (your local product), photos/scans, share sheet, quick text, email forwards | immutable capture events into an encrypted per-device queue |
| **T1 quick** | on-device, offline | clean up transcript, split into atomic items, extract dates/amounts/people, classify to a binder from a **closed list** (+ "not sure"), flag sensitivity, OCR, local embeddings for offline search | *proposals with confidence*, never direct state changes |
| **T2 private-cloud** | Apple PCC, online | longer reasoning on sensitive material | proposals |
| **T3 deep digest** | frontier model, batched, online + permitted | reconcile against the catalog, cross-reference documents, draft replies, re-date waiting items, regenerate Now | validated ops awaiting approval |

**What on-device can do today [web]:**
- **Apple:** Foundation Models runs a ~3B on-device model with an 8,192-token context, guided (typed) generation and tool calling. At WWDC26 it gained image input, a built-in OCR tool and Spotlight-backed local search. PCC gives developers 32K context with reasoning, free under 2M first-time downloads. macOS 27 adds an `fm` CLI and a Python SDK, which means your Python stack can call the on-device model directly.
- **Android:** Gemini Nano via the ML Kit GenAI Prompt API (alpha; text+image input, structured output).
- **Windows:** Phi Silica via Windows AI APIs on Copilot+ PCs.
- **Caveat:** Apple Intelligence must be enabled and available in the user's region. Keep an MLX/llama.cpp fallback.

**A durable queue, not a lossy one.** Captures are immutable events (device id + hybrid logical clock). Every processing result is a derived event that points at its inputs and records which tier/model produced it. A later deep pass can *supersede* a quick pass's proposal (reclassify), and nothing is lost, because nothing was applied without approval or ops are reversible. Capture-only sync is append-only and therefore conflict-free. That lets the MVP put off the hard sync problem.

**Encryption.**
- One user root key (the age-identity idea) with device keys enrolled by QR pairing.
- **Per-binder keys** wrapped by the root key. This lets you share one binder with a sibling or lawyer, keep a litigation binder "local-only / T1–T2 only", and crypto-shred on archive.
- The server is a **blind relay + blob store**. Optionally the user's own Drive/iCloud is a dumb ciphertext carrier, which is cmirror's model, kept.
- Recovery kit (printed code) plus optional trusted-contact recovery. Be blunt in onboarding that losing every key means losing the data.

**Conflicts across devices.**
- Field-level ops on stable ids, merged last-writer-wins per field by HLC, plus semantic rules (done beats a concurrent edit; dismiss ends a recurrence).
- Append-only collections (log, documents) are unions; documents are content-addressed immutable blobs.
- Free text (manual, notes) uses a CRDT. Automerge 3 cut memory use about 10x, and Jazz/Loro have E2E-friendly relays **[web]**. A genuine same-field conflict becomes a review card.
- **One digest lease per binder** (an expiring lock through the relay), so two devices never run a deep digest at once. That is the "two sync loops" lesson, applied across machines.

## 6. Integrations: what's worth it

- **Must-have:**
  - Email intake: a per-binder forwarding address plus label watch.
  - Calendar, two-way, for *your* dated moves only (syncToken + watch **[web]**).
  - On-device scan/OCR.
  - The share sheet.
  - Your own mobile Today/approvals, which replaces Google Tasks as the loop.
- **Should-have:**
  - One-way export to Google Tasks / Apple Reminders using delta reads (`updatedMin` **[web]**) for people who live there.
  - Contacts.
  - Bulk import from cloud drives.
  - A **professional handoff bundle**: export a binder as an indexed PDF + documents for a lawyer or accountant. Cheap to build, and it's what wins referrals.
- **Not now:**
  - **Live bank links.** Canada still has no implemented open banking, so aggregators rely on screen-scraping, and per-account fees add up **[web: Plaid pricing / open-banking trackers]**. Ingesting statements (PDF/CSV) gives most of the value with none of the credential liability.
  - **Never:** payments or auto-send. Drafts go to the user's own mail client's drafts folder.

## 7. Existing / similar solutions [all web; links below]

**AI notes / PKM**
- **Notion AI:** Custom Agents (GA May 2026) run multi-step work autonomously, ~20-min jobs. Cloud workspace, team-oriented, no lifecycle/state discipline, no privacy federation.
- **Obsidian + agent plugins** (Copilot runs Claude Code/Codex/OpenCode in a vault; Vault Operator; Local LLM Hub with Ollama): *closest in spirit to your setup*, with plain files and pluggable agents. No task schema, no digest, no hub; every user assembles it themselves.
- **Mem 2.0:** agentic chat edits notes and sends proactive reminders. Notes-first; no obligations model.
- **Reflect:** E2E-encrypted notes with built-in AI. Shows that encryption and AI can coexist in a consumer product; it is a notes app, not case management.
- **Tana:** supertags turn an outliner into typed data with built-in frontier models. Cloud-first.
- **Capacities:** light AI. **Logseq:** local plain-text, AI only via plugins, development reportedly stalled.
- **Anytype:** local-first, E2E, P2P/self-hostable sync, typed objects. *Essentially no AI.* The right substrate philosophy, nothing on top.

**Life admin / household**
- **Duckbill:** AI intake plus human "copilots" who do the tasks. $99–$350/month for roughly 4–20 tasks. Proves willingness to pay; you hand your life to strangers.
- **Ohai.ai:** household manager (calendars, emails, to-dos), AI with human backup.
- **Maple, Nori:** family assistants that turn email into calendar items and to-dos.
- **Trustworthy ("Family OS"):** document vault with an AI Inbox/"Autopilot" that reads, summarizes and files documents (Azure private AI). *The nearest commercial neighbour.* It files documents but does not run the case: no open-items reconciliation, no drafts, not local-first.
- **Quicken LifeHub, Everplans, Family Folder:** information vaults and estate readiness.
- **Empathy** (bereavement, AI assistant "Lila", sold through insurers), **EstateExec, Atticus** and others: vertical estate tools. These are your vertical competitors *and* show the B2B2C channel.
- **My Personal Admin:** announced, roadmap only, aiming at a 2026 v1.

**AI planners**
- **Motion, Reclaim, Sunsama, Todoist:** they schedule time, but none of them knows the case behind a task.

**Assistants with memory / source-grounded tools**
- **Claude Projects** (isolated memory per project) and **ChatGPT memory**.
- **ChatGPT Pulse:** reportedly retired in June 2026, with its role moved into scheduled tasks (secondary sources only).
- **NotebookLM, renamed Gemini Notebook in July 2026:** source-grounded Q&A, now with a cloud computer per notebook. Good at answering from documents; holds no state and no lifecycle.
- **Claude Cowork:** Claude Code's agent architecture in the desktop app for non-developers. Local files in a sandboxed VM, scheduled tasks, mobile dispatch; GA April 2026. **This is the most dangerous adjacent product**: it is the substrate you run on, made friendly for non-developers. What it lacks is the format, the current-truth discipline, the hub and federation.
- **OpenClaw:** open-source, always-on local agent driven from WhatsApp/Discord; 100k+ GitHub stars in its first week. Plenty of power, no structure, and a real security surface.

**Memory / hardware**
- **Limitless** was acquired by Meta (Dec 2025; pendant pulled from sale). **Granola** covers meetings. **Mem0** is developer memory infrastructure. Lesson: capture hardware gets bought out. Your dictation-on-the-laptop route avoids that dependency.

**Local-first stacks:** Automerge 3, Jazz (E2E built in), Loro, NextGraph; FOSDEM 2026 ran a full track on this.

**Where the white space is.** No product combines:
1. agent-maintained, *structured current truth* per life episode, with lifecycle and chapters;
2. a cross-project chief of staff with **privacy-preserving federation and redaction**;
3. local-first, E2E encryption and on-device capture/triage;
4. strict human approval with provenance.

Vaults store documents but don't run the case. Concierges run the case with humans and full access. PKM tools hold notes, not obligations. General agents (Cowork, OpenClaw) have power but no schema. **The gap is real but narrow and closing.** Cowork + Projects + a template gallery could get to roughly 60% of this within a year. The defensible part is the methodology (digest ritual, schema, ownership rule, redaction), the review-queue trust UX, and vetted vertical templates. The technology alone is not a moat.

## 8. Risks and hard parts

- **Liability.** Position it as an *organizer and drafter, never an advisor*. AI-extracted deadlines always show source + confidence. Statutory deadlines only come from vetted, versioned rules packs per jurisdiction, never improvised. Disclaimers won't save you; the approval gate and provenance will. Carry E&O insurance.
- **Silent wrongness beats loud wrongness.** A missed deadline is far worse than a bad draft. Run a **deterministic deadline sentinel** independent of the LLM, and a periodic **reconciliation audit** where the agent re-reads sources against the catalog and flags drift.
- **State correctness over months.** Schema migrations across versions are already a problem today: you need `equip` to retrofit old tekas. Version the op schema from day one and make migrations ops too.
- **Privacy and residency.** The deep tier sends content to model providers: require zero-retention terms, per-binder "never leaves device" mode, and on-device fallback. Apple Intelligence isn't available in every region **[web]**. E2E also means you can't debug users' data, so build privacy-safe telemetry (the watcher's "hash + count, never titles" rule is the template).
- **Litigation discoverability.** The product creates records: logs, drafts, AI summaries. It needs retention controls *and* legal-hold awareness. Never build anything that looks like evidence destruction.
- **Onboarding cost.** People arrive in chaos. If the "dump the shoebox" import doesn't produce a correct Now page in the first session, they leave. Key management is the second onboarding cliff.
- **Monetization.** Demand is episodic (an estate or divorce runs 1–2 years), so churn is built in, and acquisition cost is high because you can't predict when someone enters an episode. Willingness to pay is high *during* the episode (Duckbill's pricing shows it). Fixes: an ongoing household plan for retention, and B2B2C channels (estate lawyers, accountants, insurers, employers). On-device triage plus batched deep digests keep gross margin sane.
- **Platform absorption** by Apple, Google or Anthropic (Cowork). Mitigation: be the open format they integrate with, plus the vertical depth they won't build.

## 9. Path from today's system to a product

**Phase 0: harden and extract (about 4–6 weeks; pays off for you immediately)**
1. Write **Teka Spec v1**: spine, catalog/op schema, slice/outbox/briefs contracts, JSON Schemas, a conformance test suite. Promote the provisional briefs lane deliberately or drop it.
2. Ship **`teka-mcp`**: typed ops for agents, with the validator as the transaction guard. Claude Code and Codex both switch to it.
3. Ship **`tekad`**: one supervised service replacing watcher + sync loop + server + monitors, with heartbeats and a health page.
4. Fix the Tasks read-back with `updatedMin` delta reads, a quota budget, and visible errors.
5. Add the `expected_by` / Nudge bucket for waiting items, and a "kind" field for redacted items.

**Phase 1: MVP, "Teka for Mac", single user**
- Native or Tauri app over `tekad`: Shelf, Binder Now, review queue with provenance and undo, documents with on-device OCR, Today hub.
- **Capture from your dictation product** → T1 on-device triage (Foundation Models, `fm`/Python SDK) → durable encrypted queue → T3 deep digest through one provider, batched.
- Backup via the cmirror model (ciphertext to the user's Drive/iCloud).
- An **iPhone capture-and-approve app** syncing through append-only encrypted blobs (conflict-free, so it ships early).
- Three templates: **estate executor, move/renovation, tax year**.

**Phase 2:** full E2E sync on the field-level op log; share one binder with one person; two-way Calendar; per-binder email forwarding; ask-through answers.

**Phase 3:** Windows/Android (Phi Silica, Gemini Nano), template marketplace, professional plans and handoff bundles, channel partnerships.

**Defer:** bank links, any outbound automation, multi-agent orchestration UI, team features, the GitHub deputy (developer-only).

**Open-source:** the spec, `lifeproj` (CLI), `teka-mcp`, the capture-queue event format, the reference templates and the validator. Reasons: trust ("your binder outlives us"), adoption by every agent through AAIF standards, and the Operator persona as evangelists.

**Paid:** the desktop and mobile apps, the E2E sync relay + backup, the managed model tier (zero-retention deep digests), vetted vertical template packs, sharing, and professional plans.

**The dictation product is the natural front door.** Define the **capture-event format** now, so the dictation app works on its own and gains superpowers when Teka is installed (dictate "call the notary about the estate Thursday" offline, and it lands, classified, in the right binder). That makes the dictation app both the acquisition funnel and Teka's T0 tier.

---

### Sources (web research; generic category queries only)
- Google Tasks API `tasks.list` (`updatedMin`, `showCompleted`): https://developers.google.com/workspace/tasks/reference/rest/v1/tasks/list
- Google Calendar push / incremental sync: https://developers.google.com/workspace/calendar/api/guides/push · https://nango.dev/blog/how-to-build-a-real-time-google-calendar-api-integration/
- Apple WWDC26 Foundation Models (what's new; LLM providers): https://developer.apple.com/videos/play/wwdc2026/241/ · https://developer.apple.com/videos/play/wwdc2026/339/ · WWDC25 intro: https://developer.apple.com/videos/play/wwdc2025/286/
- Gemini Nano Prompt API: https://developers.google.com/ml-kit/genai/prompt/android · Phi Silica: https://learn.microsoft.com/en-us/windows/ai/apis/
- AAIF / AGENTS.md / MCP: https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation · https://techcrunch.com/2025/12/09/openai-anthropic-and-block-join-new-linux-foundation-effort-to-standardize-the-ai-agent-era/
- Notion agents: https://techjacksolutions.com/ai-tools/notion-ai/what-is-notion-ai/ · Mem 2.0: https://get.mem.ai/blog/introducing-mem-2-0 · Reflect: https://www.buildfastwithai.com/ai-tools/reflect · Tana/Capacities/Logseq: https://www.asianefficiency.com/technology/tana-vs-capacities-vs-logseq/ · Anytype: https://privacytools.io/app/anytype · Obsidian agents: https://community.obsidian.md/plugins/copilot · https://community.obsidian.md/plugins/vault-operator · https://community.obsidian.md/plugins/local-llm-hub
- Duckbill: https://www.bustle.com/life/duckbill-ai-personal-assistant-app-review-price-features · https://lp.getduckbill.com/pricing · Ohai: https://www.ohai.ai/ · household apps roundup: https://www.quicken.com/blog/best-family-information-and-asset-management-platforms-for-2026/ · https://www.hellobabs.ai/blog/household-management-app · Trustworthy AI: https://www.prnewswire.com/news-releases/trustworthy-sets-the-new-standard-in-family-digital-transformation-through-its-revolutionary-new-ai-features-302131556.html · My Personal Admin: https://www.mypersonaladmin.com/ · estate tools: https://www.swiftprobate.com/blog/best-ai-tools-estate-executors · https://www.meetalix.com/resources/alix-vs-empathy-estate-settlement
- Planners: https://thebusinessdive.com/sunsama-vs-motion · https://blog.rivva.app/p/reclaim-ai-vs-sunsama
- NotebookLM → Gemini Notebook: https://glasp.co/articles/notebooklm-2026 · https://www.jeffsu.org/notebooklm-changed-completely-heres-what-matters-in-2026/
- Claude/ChatGPT memory: https://memx.app/blog/claude-memory-vs-projects-one-brain/ · Pulse retirement (secondary): https://prowlo.com/blog/chatgpt-pulse-shut-down · Claude Cowork: https://felloai.com/claude-cowork-guide/ · OpenClaw: https://www.digitalocean.com/resources/articles/what-is-openclaw
- Limitless/Meta: https://www.usecarly.com/blog/limitless-ai-alternatives/ · Mem0: https://www.sentra.app/articles/mem0-alternatives
- Local-first: https://fosdem.org/2026/schedule/track/local-first/ · https://loro.dev/blog/crdt-is-not-enough · https://www.codeline.co/thoughts/repo-review/2025/classic-jazz-local-first-crdt-database
- Plaid / Canada open banking: https://plaid.com/pricing/ · https://www.richify.ai/ca/best-budgeting-apps-canada


---

## Addendum (2026-10-06): OpenAI dots and Meta Muse, both missed by the research above

Both launched in September 2026 (Muse on Sept 8, dots on Sept 29). The section 7 research ran on Oct 6 and still didn't find them. Treat section 7 as incomplete, and redo it in the lifeproj session.

**What they are (from launch coverage, not tested hands-on):**
- **OpenAI dots:**
  - Always-on ChatGPT agents, each with its own cloud computer and browser, connecting to 4,000+ apps.
  - When idle, they scan connected accounts in read-only mode looking for work. Example: a dot drafted an invoice it found owed in an email thread.
  - Approvals: custom rules allow, block, or require approval for actions; approving one message gives no standing permission.
  - Availability: Pro, Business Premium, Enterprise beta; not in the EU or UK.
- **Meta Muse:**
  - A long-running personal agent on a cloud VM, used through an app or WhatsApp. Free tier plus $20 and $100 tiers; US-only.
  - Connects to email, calendar, payments, health, shopping and smart home.
  - Approvals: comes back for sign-off before it sends or buys.
  - Memory: a persistent "memory about you" profile.
  - Launch incidents: a Mac zero-day, disk permissions bypassed, iCloud photos exposed, a home address leaked on a marketplace, root access via agent impersonation.
  - Staff can access the VM; that's restricted by policy, not cryptography (confidential VM is only on the roadmap). Browsing is attributed to the user, which feeds ad targeting.

**What changes:**
1. **Proactive inbox mining is now table stakes.** Don't compete on it.
2. **The gap moves to structure and privacy:**
   - a per-episode current-truth case file (their memory is a profile of the person, not a case);
   - compartments and redaction;
   - local-first, end-to-end encrypted storage with user-held keys and no vendor staff access;
   - provenance and vetted deadlines;
   - an approval queue.
3. **Their incidents validate "monitors flag, humans act" and per-domain discretion.** Dots' "one approval is no standing permission" rule matches our model.
4. **Positioning: the record any assistant writes into.** `teka-mcp` lets dots, Muse, Claude or Codex act as clerks that propose typed ops into your binder. The binder keeps the truth, approvals and compartments. Agent-neutrality becomes a consumer feature: "use whichever assistant you like; your binder stays yours."
5. **The legal and B2B2C angle strengthens.** Cloud-agent records sit in vendor clouds and may be discoverable; a local, compartmented binder is lawyer-recommendable. This matters more now that Muse is free.

Sources: thenextweb.com/news/openai-dots-always-on-ai-agents-cloud-computers-devday · techcrunch.com/2026/09/29/openai-launches-dots-its-bubbly-agentic-avatar/ · dragapp.com/blog/openai-dots/ · about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/ · forbes.com (Sept 9, staff flag security flaws) · tech-insider.org/meta-muse-personal-ai-agent-launch-2026/ · techdirt.com/2026/10/06/metas-muse-is-an-adorable-privacy-and-security-dumpster-fire/ · superpowerdaily.com (staff access review) · oodaloop.com (Muse backlash brief) · epic.org/metas-mass-data-collection-is-not-a-muse-ing/

## Addendum (2026-10-06, planning session): competitor refresh

The refreshed landscape, checked against vendor pages where possible, is in `docs/research/competitors-2026-10.md`. Headline corrections to section 7 and the addendum above:
- Claude Cowork merged into Claude on 2026-09-16; new Pro and Max tasks run in the cloud since 2026-10-06, with local files and local MCP servers reachable only while the desktop app is open. Claude memory now spans chat and Cowork, for cloud sessions only.
- Muse: Meta publishes the quotas (Power $20 a month for 500M tokens a week; Maximum $100 for 3B); the Mac app needs Full Disk Access for file work; deletions go to the Trash without approval; computer use across apps arrived 2026-09-23; the dictation zero-day was disclosed 2026-09-21 and hotfixed 2026-09-22. "iCloud photos exposed" has no source; "root access via impersonation" is unresolved. Muse has no MCP path, so it cannot act as a clerk through teka-mcp.
- dots: proactive research is read-only; password changes and money transfers are hand-offs to the user; deletion and installs "may" need approval; Pro users in the EEA, Switzerland and the UK are excluded. The dots path to a local MCP server is inferred from documentation and was never tested.
- Missed entirely: Gemini Spark (AI Pro in 160+ countries since 2026-07-30, with the EEA, UK, Switzerland and Nigeria excluded), Microsoft Autopilot and consumer Cowork, Instinct ($1B at $10B on 2026-09-28), Grok Bot, Manus Cue and Amazon Quick. Missed near-neighbours: Casefleet (fact-level provenance with approval) and Prosei (per-case deadline extraction), both cloud.
- Anytype has an AI Ally alpha (cloud, through Anthropic's API) plus an Agents skill over its Local API, so "essentially no AI" is stale. Obsidian's Vault Operator now has fail-closed approvals, shadow-git undo and sensitive-folder gating. OpenClaw 2.0 (2026-08-30) still lacks encryption at rest.
- Estate vertical: EverSettled is $1,999 total; Atticus pricing and Empathy's "Lila" are unverified; Empathy's July 2026 AI push is confirmed.
- Apple: Siri AI is available on the Mac in the EU (blocked only on iOS, iPadOS and watchOS); Apple announced tighter Full Disk Access controls on 2026-10-02. Section 5's "3B model with 8,192 tokens" pairing is superseded; see `docs/decisions.md` P2.
- The white space now: approval gates and inbox mining are table stakes; local-first, compartments, a per-episode case file, provenance plus undo, the open format (with a desktop-bridge constraint) and region-agnostic availability (narrowed to the EEA and UK gaps) hold.
