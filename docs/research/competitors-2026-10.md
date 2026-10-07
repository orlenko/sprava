# Competitor landscape, October 2026

Status: v0 draft of 2026-10-06. Written by the planning session from the verified research digest on competitors; nothing here was searched again. It replaces section 7 and the addendum of `docs/brainstorm/2026-10-06_product-brainstorm.md` as the current picture. Prices and dates are as read on the dates given in section 10. This is not legal advice.

How to read this file. A binder is one case file for one episode of a person's life; Sprava calls its on-disk form a teka. "Verified" means the research verifier confirmed the claim on the vendor's own page. "Secondary" means press or blog coverage only. "Unresolved" means the sources conflict or no primary source could be read. Claims the verifier refuted were removed; where the brainstorm stated one, this file says so. Bracketed numbers such as [12] point to the sources in section 10. References such as "(decisions.md A4)" point to the decisions log, which this file follows.

## 1. Summary: what changed since the brainstorm

The brainstorm's section 7 was written before the September launches. Its addendum covered OpenAI dots and Meta Muse from launch coverage only. The research sweep then read vendor pages where it could and had a verifier check every load-bearing claim. The picture as of 2026-10-06:

The category is crowded, and every entrant keeps the brain in the vendor's cloud. OpenAI dots, Meta Muse, Google Gemini Spark, Microsoft Autopilot, Instinct, Grok Bot, Manus Cue and Amazon Quick each run on a virtual machine (a rented computer in a data centre) that the vendor owns [1, 16, 37, 44, 52, 59, 60, 62]. Claude moved new Cowork tasks on Pro and Max plans to the cloud on 2026-10-06, with no local option [68]. Muse for Mac reaches local files from a cloud VM [18, 16].

Two things the brainstorm counted as white space are now table stakes. Every cloud agent asks before it sends or spends (dots, Muse, Claude Cowork, Microsoft's consumer Cowork, Spark), and the one that does not (Instinct) has logged incidents [3, 16, 71, 46, 35, 52]. Every one of them also mines the inbox and calendar while idle [3, 36, 107, 62]. The approval gate alone no longer sets Sprava apart. What nobody sells is approval of typed changes to a case file, with provenance (a record of where each fact came from) and undo, on the user's own Mac.

Two more have eroded in the verticals. Casefleet sells fact-level provenance to individuals: every fact links to the document that proves it, and an AI drafts facts the user approves [116]. Prosei keeps per-case folders with extracted dates and deadlines for people representing themselves in court [117]. The estate tools (SwiftProbate, EstateExec, EverSettled, Alix, Empathy) keep per-estate checklists with deadlines [120, 124, 126, 122, 125]. All of these are cloud services. For an arbitrary life episode (a move, a renovation, a tax year, a board seat) no product keeps an agent-maintained case file.

What holds: local-first; compartments (a binder that no other binder, device or agent can see into) with a cross-binder roll-up (the view across all binders) under redaction (sensitive items shown only as a kind, such as "legal deadline"); a horizontal per-episode case file; an open, agent-neutral format reachable over MCP (the Model Context Protocol, the open standard an assistant uses to call tools in another program), with the constraint that cloud agents reach a Mac only through a desktop bridge; and availability that does not depend on region, now narrowed to the gaps that remain in the EEA and the UK. Section 9 gives the evidence for each.

Apple has built nothing case-file-like. Siri's personal context is an index with actions [86, 87]. The Foundation Models framework makes an on-device clerk easy for any developer to build, so local-first is a position Sprava chooses; it is no technical moat [93]. Apple's third-generation models come in a 3B and a 20B-sparse on-device size (sparse meaning only a few billion parameters are active at a time), built with Google, and Private Cloud Compute (Apple's server-side model service, which promises the device's privacy rules) now runs partly on Google Cloud [100, 101]. On 2026-10-02 Apple announced tighter controls on Full Disk Access (the macOS permission that lets an app read every file, including the Mail and Messages databases) because of AI agents [104]. That favours a design fed by user-granted folders and capture events (immutable records of a dictation or a dropped document, in a versioned format), which is the design Sprava has (decisions.md P6, P7).

The launch month's incidents argue for Sprava's posture. Muse shipped with a Mac zero-day (a security flaw with no fix available when it is disclosed), let a researcher export its VM filesystem, got into a dispute over an iMessage database, and still has no user-key-encrypted VM [27, 28, 29, 15]. Instinct logged three incidents [52]. OpenClaw 2.0 shipped without encryption at rest [140].

### 1.1 Corrections to section 7 and the earlier addendum

- Claude Cowork is no longer a separate app. It merged into Claude on 2026-09-16, and new Pro and Max tasks run in the cloud since 2026-10-06, with local files and local MCP servers reachable only while the desktop app is open. Scheduled tasks that need local resources run locally only. Section 7's "local files in a sandboxed VM" is out of date (section 3).
- Claude memory now spans chat and Cowork (since 2026-08-25), with per-topic controls, and only for Cowork sessions that run in the cloud (section 3).
- Muse: Meta does publish the quotas (Power $20 a month for 500M tokens a week; Maximum $100 for 3B); the Mac app needs Full Disk Access for file work; deletions go to the Trash without approval; computer use across any Mac app arrived 2026-09-23; the dictation zero-day was disclosed 2026-09-21 and hotfixed 2026-09-22; the Confidential VM is still "later this year"; staff access to VMs is confirmed in Meta's own words. The addendum's incident list changes: "iCloud photos exposed" has no source in the sweep and is dropped; "root access via agent impersonation" is unresolved; "disk permissions bypassed" is the unresolved iMessage dispute. Canada availability is reported by secondary trackers only (section 2.2).
- dots: proactive research is read-only; password changes and money transfers are hand-offs to the user; deletion and installs "may" require approval; Pro users in the EEA, Switzerland and the UK are excluded. Which Pro tier includes a dot is unresolved (section 2.1).
- Missed entirely: Gemini Spark (available to AI Pro subscribers in 160+ countries since 2026-07-30, with the EEA, UK, Switzerland and Nigeria excluded), Microsoft Autopilot and consumer Cowork, Instinct (a $1B round at a $10B valuation on 2026-09-28), Grok Bot, Manus Cue and Amazon Quick (section 2).
- Missed near-neighbours: Casefleet (fact-level provenance with approval) and Prosei (per-case deadline extraction), both cloud (section 7).
- Anytype has an "AI Ally" alpha (cloud, through Anthropic's API) and an Agents skill over its Local API, so "essentially no AI" is stale (section 8).
- Obsidian's Vault Operator now has fail-closed approvals (nothing is written unless the user allows it), undo through hidden version-control snapshots, and sensitive-folder gating (section 8).
- OpenClaw reached 247k stars by March; version 2.0 (2026-08-30) still lacks encryption at rest; the creator joined OpenAI (section 8).
- Mem0's OpenMemory MCP server is deprecated; Khoj Cloud is gone; both self-host only (section 8).
- Notion Custom Agents went GA (generally available) on 2026-05-04 at $10 per 1,000 credits (metered usage units), on Business and Enterprise only (section 5). Gemini Notebook's rename date is 2026-07-16 (section 5).
- Duckbill's listed tiers are $99, $169 and $350 (section 6). Trustworthy's "Azure private AI" is a 2024 press-release claim (section 6).
- Estate vertical: more AI entrants (SwiftProbate, EverSettled), Empathy's July 2026 AI push; EverSettled costs $1,999 total; Atticus pricing and Empathy's "Lila" are unverified (section 7).
- Apple (brainstorm sections 4 and 5): Siri AI on the Mac is available in the EU; the "about 3B model with 8,192 tokens" pairing is superseded (Apple's third-generation models, AFM 3, come as a 3B Core and a 20B-sparse Core Advanced, and Apple's docs fix no context size; Sprava designs for 4,096 per decisions.md P2); the fm tool and Python SDK are developer tools only (decisions.md P3); Private Cloud Compute is out (decisions.md P1). Apple announced the Full Disk Access tightening on 2026-10-02 (section 4).
- The addendum's item 4 ("teka-mcp lets dots, Muse, Claude or Codex act as clerks"; teka-mcp was the brainstorm's name for Sprava's MCP server): Muse has no MCP path at all, and dots reach a Mac only through the ChatGPT desktop app with opt-in local access (section 9.5).
- Section 7's list of four white-space items is replaced by the eight verdicts in section 9. The approval gate and inbox mining are table stakes; provenance and per-case structure have eroded in the verticals; the rest holds.

### 1.2 Not refreshed

The sweep did not revisit these section 7 entries, so they stand as unverified: ChatGPT Pulse's retirement, ChatGPT memory changes in 2026, Quicken LifeHub, Everplans, Family Folder, Mem 2.0, Reflect, Tana, Capacities, Logseq, Motion, Reclaim, Sunsama, Todoist, Limitless and the Meta pendant, Granola, and the local-first sync stacks.

## 2. Cloud personal agents

### 2.1 OpenAI dots

What it is. dots launched at OpenAI's DevDay on 2026-09-29 [1, 2]. Press coverage describes always-on agents, each with its own cloud computer and browser, running on a model the coverage calls GPT-6 Astra and connecting to more than 4,000 apps through plugins; those three details are press-only, because OpenAI's own pages returned HTTP 403 to the sweep and the help-centre text could be read only through search excerpts [1, 2, 13]. Coverage says a dot is reachable from the ChatGPT apps, Slack, Teams and voice, and that the first dot is included on Pro and Business Premium plans [1].

Idle behaviour (verified in OpenAI's help text). Between prompts a dot runs "proactive research" with tools "restricted to be read-only, which means that they can't send messages, change app content, or control your browser or computer" [3, 8]. "Your dot cannot turn off required Auto-review checks or remove those research restrictions" [3]. The example given is a dot that reviews a calendar every morning and reports the day's events [8].

Approvals (verified, with one correction). Custom Rules give each kind of action one of four behaviours, "Take action without asking", "Take action if pre-approved", "Ask before taking action" and "Hand off to you", plus block [4]. An Auto-review "checks certain planned actions against your instructions, Custom Rules, and safety requirements before they run" [3]. "The most sensitive actions like changing a password or transferring money require you to take over so you can complete them yourself, while other actions like permanently deleting data or installing software may require approval each time" [3]. The first pass said password changes "always need manual approval"; the verifier corrected this to a hand-off. Secondary coverage adds that approvals are event-based: approving one message gives no standing permission [9, 2]. Unresolved: the claim that pausing a dot leaves its delegated tasks, schedules and local-computer grants running rests on one secondary source [9]; OpenAI's pages say Pause suspends future scheduled runs without interrupting an active one, and local work is removed through "Revoke access" [4, 6].

Privacy and data location (verified). "Your dot can retain context from your conversations and plugins for as long as you keep your dot. Your dot's context does not retain credentials, images, or screenshots" [3, 10]. Deleting the dot deletes its context [3]. Local computer access is "optional and starts turned off"; it needs the ChatGPT desktop app installed on that computer, kept online and open [5]. There is no offline mode [1, 9]. Unresolved: whether the Enterprise dots beta lacks data residency (a choice of which country the data is stored in) and strict zero data retention (the vendor keeping no copy after processing) rests on a secondary source [9]; OpenAI's page on the related "local work sync" feature says zero data retention is not supported there while data residency is [7].

Structure (verified). A dot "can work across several projects"; "the more you work together, the more your dot learns your preferences, how you think, and what good looks like to you"; dots get a handle such as @yourname-agentname [4]. OpenAI's documentation describes no per-episode case file, no provenance for facts and no user-held keys [4]. ChatGPT Space (documents, sheets and slides with human and agent co-editing) launched alongside [2, 13].

Pricing and regions. Verified: Pro users "in eligible markets, excluding the EEA, Switzerland and the UK", Business Premium, and an admin-enabled beta for Enterprise, Edu and Healthcare that is off by default [4, 14, 1]. Unresolved: whether the $100 Pro tier includes a dot or only the $200 tier, the reported $500 ChatGPT Work tier, and the price of additional dots; secondary sources conflict and OpenAI's pages could not be read [11, 12, 2].

For Sprava. A dot is a profile-plus-projects model; it keeps no case file. Its reach to a Mac runs through the desktop app with opt-in local access [5]. Whether that path can carry a local MCP server is inferred from documentation; the sweep did not test it. Sprava's MCP surface is designed for clients of both protocol eras (decisions.md A4).

### 2.2 Meta Muse

Launch and availability. Muse launched 2026-09-08, "rolling out in the US on iOS, Android, and muse.ai" (verified) [15]. Secondary trackers report a Mac app on 2026-09-17 and Canada on 2026-09-18; Meta's own pages date neither, so both are unresolved [20, 21, 22]. For the UK and EU no Meta source gives a date; Meta says subscriptions are "not available in all locations yet" [17]. The earlier addendum said "US-only"; Canada is reported by secondary trackers and unconfirmed by Meta.

Architecture and approvals (verified). Each user gets a "Muse Secure VM" holding the agent and the user's data. A separate "Sentinel agent" is "the sole permission authority for approval to perform actions with connectors to third-party services and for all egress over the network", with allow, deny and ask-user decisions [15, 16]. Muse asks permission before sensitive actions such as sending an email or making a purchase, shows "a complete audit trail of everything it has done and plans to do", and can be told to "forget" things [15].

Pricing (verified on Meta's help page; corrects the first pass). A free tier "with a usage limit"; a Power plan at $20 a month with "500M Muse tokens per week"; a Maximum plan at $100 a month with "3B Muse tokens per week" [17]. The tier is called Maximum, and Meta does publish the quotas; the first pass said otherwise and was refuted. The 100M-a-week figure for the free tier is secondary only [23]. Subscriptions are "in limited testing and aren't available in all locations yet" [17].

Privacy posture (verified in Meta's own words). The Secure VM "does not prevent Meta from accessing data when necessary to support, secure or operate the service" [16]. The user-key-encrypted "Muse Confidential VM" is still due "later this year" in the launch post as updated on 2026-09-30; it has not shipped [15]. "Muse doesn't share a person's conversations or the data in their VM with Meta's ad systems", and Meta's safety post concedes that browsing on the user's behalf may indirectly influence ads [16, 24]. Muse builds a page for every person in the user's life; an AI-safety researcher extracted the instructions, press reported it on 2026-10-05, and Meta said the files were meant to be accessible for transparency [24, 25].

Mac app (verified on Meta's help page; corrects the first pass). Muse for Mac lets the cloud agent act inside Files, Mail, Messages, Calendar and Notes, and since Meta Connect on 2026-09-23 "Computer use is now available with Muse for Mac", so it can drive any Mac app [18, 19, 22]. Full Disk Access is the permission Muse needs "so your agent can find, read or update files. This permission covers all the files on your Mac"; it is opt-in and required for file work [18]. Deleting a file needs no approval: "When your agent deletes a file, it moves it to your Trash"; approvals are for "an important action like sending an email or making a purchase" [18]. The cloud VM stays the brain; there is no local-only processing [16, 22]. "US only" and "free" for the Mac app rest on secondary sources plus Meta's "not available in all locations yet" [22, 17]. The first pass said Full Disk Access was optional and deletion needed approval; both were corrected.

Incidents (verified unless marked).

1. A Mac zero-day: any local process could change undocumented Muse settings to redirect the dictation endpoint and take the account token, with a webcam and file-write proof of concept. A security researcher disclosed it on 2026-09-21; Meta hotfixed it (shipped an urgent patch) on 2026-09-22, and its engineering lead confirmed the fix publicly, calling it a local privilege escalation [26, 27, 34]. The first pass's "no patch as of 2026-09-22" was stale.
2. A 6.8 GB export of the VM filesystem (the agent's SOUL.md and MEMORY.md, 113 sub-agent transcripts, internal manuals, unreleased connector names) that Meta's bug bounty (its program that pays researchers for reported flaws) marked "Not Applicable" [28, 34].
3. A columnist found 187,462 rows of his Mac iMessage database synced while Full Disk Access was off; Meta says both Full Disk Access and the Messages connector are required. Unresolved; no independent investigation [29].
4. A Marketplace listing disclosed a reviewer's home address; Meta is "reviewing permissions" [30]. Root access through agent impersonation is listed as unresolved by one outlet only [33].
5. A VM escape fixed immediately before launch [31].
6. Amazon blocked Muse from 2026-09-20, citing undisclosed automation and credential capture [32].

The earlier addendum also listed "iCloud photos exposed"; no source in the sweep corroborates it, so it is dropped. Its "disk permissions bypassed" is the iMessage dispute above, which is unresolved.

For Sprava. Muse keeps a profile of the person and of everyone around them. It has no MCP path; it reaches local files only through its Mac app with Full Disk Access and computer use, so it cannot act as a clerk through Sprava's MCP surface (section 9.5). Staff access by policy and the unshipped Confidential VM are the contrast to a binder that never leaves the Mac (decisions.md A6, A7).

### 2.3 Google Gemini Spark and Daily Brief

Launch (verified). At I/O on 2026-05-19 Google announced Gemini Spark, a 24/7 agent on dedicated Google Cloud VMs, with Gmail, Docs and Workspace integration, its own Gmail address, Chrome access, and MCP connections chosen by Google (Canva, OpenTable, Instacart) [35, 37]. It asks permission "before performing high-stakes actions like spending money or sending emails" [35]. At launch it was a beta for Google AI Ultra ($100 or $200 a month), "U.S. only", with macOS integration promised for summer 2026 [36, 35]. Daily Brief, an overnight inbox and calendar digest, launched for AI Plus, Pro and Ultra, US only [36]. No Spark-specific privacy policy was published at launch (secondary) [37].

Correction (verified). The first pass said Spark was still US-only on Ultra with no expansion after May; that was refuted. Google's post of 2026-07-30 extended Spark to Google AI Pro subscribers in "over 160 additional countries" and added Chrome auto-browse, US first [38]. Press reports US AI Pro access from 2026-07-16 and exclusions for the EEA, the UK, Switzerland and Nigeria [39]. Daily Brief remains US-only per the May post and was not re-checked [36]. Whether the macOS integration shipped was not checked.

For Sprava. Spark's MCP connections are Google's choices, so a Sprava MCP server is out of its reach (section 9.5).

### 2.4 Microsoft Autopilot and consumer Cowork

Autopilot (verified). Microsoft Scout, announced at Build on 2026-06-02, became Autopilot on 2026-09-25: an always-on agent that "lives in your tenant with its own identity, memory, computer and workspace" (a tenant is an organisation's own Microsoft 365 account), grounded by Work IQ; "Give it a name, a role and a goal, and it goes to work" [44, 45]. "Sensitive actions can require a human to sign off before they proceed" [45]. The Copilot app is now Home (chat, Cowork and Office), Code and Autopilot. Autopilot was "expanding to private preview at month's end" for Frontier enterprise customers; Code reaches Microsoft 365 Premium and Pro subscribers "in preview ... later in 2026" [44].

Consumer Cowork (verified). For personal Microsoft accounts, Copilot Tasks are migrating into "Cowork (Preview)": "describe what you need in natural language, Cowork does the work, and you review and approve sensitive actions before they happen" [46]. "Cowork is a Premium or Pro feature in Preview. If you have a Personal or Family subscription, you will lose access to Cowork" [46]. Microsoft 365 Premium is $19.99 a month; personal and work data stay separated [46, 49]. Business Copilot Cowork went GA (generally available) on 2026-06-16 and bills pay-as-you-go at $0.01 per Copilot Credit [47, 48]. Unresolved: whether consumer Cowork is live for every Premium and Pro user as of October 2026, and any consumer pricing for Autopilot.

### 2.5 Instinct

(Verified through press.) Instinct, from Spear Street Technology in San Francisco, is an invite-only, currently free personal agent used through iMessage, WhatsApp and phone. It runs a persistent cloud computer with stored credentials. Its terms let it collect screen captures, keystrokes, email, messages, audio and location, and appoint it to enter binding transactions [52]. Three incidents are documented: message text retained after the user disconnected Google; a prompt injection (text planted in an email that steers the agent) that triggered unapproved actions; and an email sent without approval [52, 53]. Funding, corrected: a $250M Series B on 2026-08-26 (total raised $350M) at $2.5B, then a closed $1B Series C at a $10B valuation on 2026-09-28, with 100,000+ users [56, 57, 58]. The first pass gave "$350M at $2.5B" as the latest round, which was out of date [54, 55].

For Sprava. Instinct is the counter-example. The market expects an approval workflow, and a product without one logs incidents.

### 2.6 Grok Bot, Manus Cue and Amazon Quick

Secondary only; the verifier did not re-check these.

- Grok Bot (SpaceXAI, 2026-08-11): persistent agents on dedicated cloud VMs that sign into real tools; $120 a seat for teams; bundled from the $20 SuperGrok plan; enterprise controls 2026-09-03; Team Bots 2026-09-28 [59].
- Manus Cue (2026-09-28): each agent gets its own email address, phone number, wallet and computer, and pays within a budget the user sets; free early access by invite [60, 61].
- Amazon Quick desktop (preview 2026-04-28, macOS and Windows): reads local files without uploading them, runs proactively in the background and builds a personal knowledge graph; Plus $20 to $25 and Max $100 to $125 per user a month; served from the US East region [62].

All three keep the brain in the cloud, and none has a per-episode case file.

## 3. Claude

Timeline. Cowork had a research preview on 2026-01-12 (macOS, Max only; secondary, and the verifier did not re-fetch it) [64, 65]. It went GA on 2026-04-09 "on all paid plans" (verified) [66]. On 2026-09-16 "Claude Cowork and chat are merging into one Claude", Pro and Max first, with Claude Docs and Slides in beta (verified) [67, 63]. The brainstorm's section 7 describes Cowork as a separate app with "local files in a sandboxed VM"; that is out of date.

Where tasks run (verified). Cowork sessions run in an isolated environment on Anthropic's servers. On Pro and Max, tasks started after 2026-10-06 run in the cloud: "There's no setting to choose where a task runs on Pro and Max plans", and "you can't switch back"; tasks started before that date stay on the local computer [68]. "A session in the cloud reaches your computer only when the Claude Desktop app is open, only for the folders you've connected there" [68]. Local file access, local connectors, local MCP servers, browser use and computer use therefore work only through the open desktop app [68, 69]. One correction: the 2026-08-19 date on the help page applies to live artifacts; the sentence "plugins that include local MCP servers work through the desktop app only" carries no date [68].

Scheduled tasks (verified). They run remotely on their cadence even when the computer is asleep or the desktop app closed, with the same connectors, skills and plugins. "If a scheduled task requires local files or apps, it will only run locally." Scheduled tasks created before October 6 that run on the computer keep running there. Available on Pro, Max, Team and Enterprise [70].

Approvals (verified). Three modes: approve each action manually; auto-approve with Claude's own safety review ("Claude reviews each action for safety before it runs and blocks anything it determines to be unsafe"); or skip approvals. "Claude always asks before permanently deleting files, in any mode." Anthropic advises manual mode for sensitive files, sending messages or purchases, names prompt injection as the primary threat, and says "Avoid granting access to financial documents, credentials, or personal records" [71].

Plugins and MCP (verified). Plugins "bundle skills, connectors, and sub-agents into packages saved to user accounts" and work across chat, Code and Cowork. Users choose which MCP servers connect and set network egress permissions, which "don't apply to the web fetch or web search tools". There is no template gallery for life episodes [69].

Memory (verified). On 2026-08-25 Anthropic unified memory across chat and Cowork. Topics are added as you chat and can be read, edited or deleted topic by topic. Sensitive topics (health, race, religion, politics, gender identity) are excluded by default behind a toggle. Claude never stores government IDs, Social Security numbers, criminal history, immigration status or financial account numbers. Memory is on by default for Free, Pro and Max; Team and Enterprise are admin-controlled and off until enabled [72, 73, 74]. Two points matter here. "Memory across Cowork and chat only works when Cowork runs in the cloud. It isn't available in Cowork sessions that run locally on your computer" [74]. And the protection is policy, with no cryptography behind it [72].

Projects (verified, with one unverified number). "Each project has its own separate memory space ... separate from other projects or non-project chats"; project knowledge is expanded by retrieval "up to 10x"; "Free users can create a maximum of five projects" [79, 74]. The "about 200K tokens" figure from the first pass is not on the support page and is unverified [75]. On 2026-09-17 Anthropic redesigned Claude Code Projects as a coordinator plus parallel threads that share project memory and a file library. "Threads run in the cloud today; running on your machine ... is coming very soon." The beta is for "select Claude Pro and Max subscribers who use cloud sessions in Claude Code and don't have any existing projects on the web or desktop", with chat and Cowork later [78, 80, 76, 77].

Pricing (verified on claude.com/pricing). Pro $20 a month ($17 annual); Max $100 (5x) or $200 (20x); Team Standard $25 a month ($20 annual) and Premium $125 ($100 annual); Enterprise custom. "Claude Cowork is now just Claude. Rolling out to Pro and Max, with more plans to follow"; the support docs list Cowork on Pro, Max, Team and Enterprise [81, 69, 82].

For Sprava. Claude is the Tier 2 brain the author uses today (Tier 1 is the on-device clerk; Tier 2 is the optional outside agent that connects over MCP; decisions.md P1, M1). The reachability rule is now exact: a cloud Claude session reaches a local MCP server only while Claude Desktop is open, while Claude Code and Claude Desktop reach it directly. Sprava's MCP surface serves both eras of client (decisions.md A4). The brainstorm called Cowork "the most dangerous adjacent product" because it ran on local files. With the default now in the cloud, it is the nearest general agent and the clearest contrast to a binder that stays home. What it still lacks is unchanged: the format, the current-truth discipline, compartments with a roll-up, and a template for a life episode.

## 4. Apple

### 4.1 Siri personal context on macOS 27

(Verified, with corrections.) macOS 27 shipped on 2026-09-14 [85, 83]. Siri AI adds personal context, a semantic index (a search index over the meaning of the user's content) across Mail, Messages, Calendar, Reminders, Notes, Photos and Files, plus onscreen awareness and in-app actions; heavier requests go to Private Cloud Compute [86, 83, 84]. The rollout is waitlisted [87]. English is in beta now, with "French, Japanese, Korean, Portuguese, and Spanish coming in October" [86]. The EU block applies only to iOS, iPadOS and watchOS: "Mac and Apple Vision Pro users in the EU will be able to access Siri AI when set to a supported language" [85]. It is unavailable in China and to users under 13 [86]. The first pass's "English-only at launch in eight countries" and "initially blocked in the EU" were corrected: the "eight countries" figure appears nowhere in Apple's materials (Apple says "availability varies by region and platform"), and the Mac is open in the EU.

For Sprava. Siri AI is a retrieval and action layer. It has no obligations model, no provenance and no per-matter container [83, 84].

### 4.2 Reminders, Mail, Messages and Files

Reminders gains natural-language creation, with Apple Intelligence extracting date, time, urgency, repeat and location, and a metadata box (secondary, consistent across two outlets) [88, 92]. Mail gets "Suggestions, Personalized Smart Reply" and intent-ranked search, and "suggestions in Mail become even more capable with the ability to take action with third-party apps" [89, 91]. "Messages offers one-tap suggestions based on the context of users' conversations ... such as creating a reminder or a note" [91]. These are per-message suggestions; the first pass's "nothing pulls tasks out of Mail or Messages" was too strong and was corrected. Files suggests file and folder names [91, 89]. Claims that Visual Intelligence imports a photographed schedule into Calendar and Reminders, and that Journal adds generative prompts, were not found in Apple's releases and are unverified [89, 90]. No Apple feature files documents, tracks obligations or keeps a case file [89, 91].

### 4.3 The Foundation Models framework

(Verified on Apple's session page.) At WWDC26 Apple rebuilt the on-device model, added image input, improved tool calling and guided generation (the model fills a typed form instead of writing prose), and exposed tokenCount(for:) and a runtime contextSize [93]. Two precisions from the verifier: the contextSize and tokenCount APIs were released in iOS 26.4 and back-deployed (made available on the earlier OS too), and "8192" is the number printed in the session's sample. Apple's API documentation defines contextSize only as "The maximum context size in tokens that the model supports" and fixes no number; one secondary post reports 4,096 on iOS 26 and 8,192 on iOS 27 "newer devices" [93, 96, 95]. Sprava therefore designs the clerk for 4,096 tokens and reads the size at runtime (decisions.md P2).

The Private Cloud Compute model has a 32K context with light and deep reasoning, needs an entitlement (a permission Apple grants to a specific app) and no API keys, and carries "no cloud API costs to developers who have less than 2 million first time downloads", with higher limits for iCloud+ users [93, 94]. Under the decisions log it stays out of Sprava, because the entitlement is tied to App Store distribution (decisions.md P1, P4).

A LanguageModel protocol lets one LanguageModelSession be backed by SystemLanguageModel, PrivateCloudComputeLanguageModel, CoreAI or MLX local open-weights models (models whose files anyone can download and run), or Anthropic's and Google's Swift packages, with OAuth (a standard sign-in flow), keys stored in the Keychain (Apple's password store) and per-token usage reporting [93, 94]. New system tools include Spotlight search for local retrieval (feeding the model a few facts found on the device), OCR (reading text out of images) and barcode reading. A Python SDK (software development kit) and an fm command-line tool exist [93]. For Sprava: the product uses the Swift framework directly, the fm tool and the Python SDK are developer tools only, and the open-model fallback is a LanguageModel conformer (a component that implements that protocol, so a fallback model plugs into the same session code) (decisions.md P3). The Spotlight tool is never used for binder content, because items donated to Spotlight appear in the Mac's built-in search and that breaks compartments (decisions.md A3).

### 4.4 AFM 3 and the Google partnership

(Verified on Apple's research post.) Apple's third-generation Foundation Models are five models "custom-built in collaboration with Google": AFM 3 Core (3 billion parameters) and AFM 3 Core Advanced (20 billion, sparse, activating "1 to 4 billion parameters at a time") on device, plus AFM 3 Cloud, ADM 3 Cloud for images and AFM 3 Cloud Pro [100, 97, 98]. Core Advanced "is unlocked by and optimized for our most capable Apple silicon systems"; the device list exists only in leaks and is unverified [100]. Which on-device model backs SystemLanguageModel on a given Mac is not stated in the sources read [97]. In June 2026 Apple extended Private Cloud Compute to Google Cloud, using "NVIDIA Confidential Computing with NVIDIA GPUs, Intel CPUs with TDX, and Google's Titan chip", for "agentic tool-use and complex reasoning", claiming the same guarantees, with binaries published and research access through the bounty program [101, 99].

### 4.5 The Full Disk Access tightening

(Verified verbatim on Apple's developer news.) On 2026-10-02 Apple wrote: "Some developers are using Full Disk Access in ways that could put users at risk, exposing everything on their systems ... without users' full knowledge and understanding", and "we will introduce additional controls to ensure that users who genuinely wish to grant an app this extraordinary level of access can only do so with very explicit user action ... As AI agents become increasingly capable and autonomous, the risks associated with this level of access will grow substantially" [104]. No version or timeline was given, and the note singles out communication apps [104]. Press ties it to Muse and to a flaw in the ChatGPT Mac app [102, 103]. For Sprava: this is one reason holos (the author's separate dictation app) writes capture events into a folder the user chooses, and Sprava never reads another app's private files (decisions.md P7).

## 5. Google and Notion

Gemini Spark and Daily Brief are in section 2.3.

Gemini Notebook (secondary; not re-verified). NotebookLM was renamed Gemini Notebook on 2026-07-16 (notebook.google.com, also inside the Gemini app and Search). Every notebook gets a "secure cloud computer" that writes and runs code against its sources, for AI Ultra at once and for Pro on the web as a rollout; a reported free tier allows 100 notebooks of 50 sources each [40, 41]. It answers from documents and keeps no tasks, deadlines or state. The brainstorm's section 7 entry was right apart from the date.

Keep and Tasks (unresolved; secondary blogs only). Keep reminders have reportedly been folded into Google Tasks, visible in Tasks, Calendar, Keep and Gemini; "Keep Live" turns a spoken brain-dump into several notes and lists, rolling out globally in English on mobile as of September 2026, with Android gated to AI Pro and Ultra; Gemini can create Keep notes and Tasks reminders [42, 43]. No obligations or case model.

Notion (verified). Custom Agents went GA on 2026-05-04 (free beta from 2026-02-24, secondary). They run on triggers (schedule, Slack, email, database row, button) and bill through Notion Credits (metered usage units) at $10 per 1,000, as a Business and Enterprise add-on, free through 2026-05-03 and metered from 2026-05-04. "If you downgrade your Notion plan to Free or Plus, all existing Custom Agents are switched off." The personal Notion Agent stays included [50, 51]. A cloud workspace with no per-episode privacy or provenance. Section 7's "GA May 2026" was right; the pricing and the plan gate are new.

## 6. Vaults and family assistants

Trustworthy, "Family OS" (verified). Plans: Free, Silver $10, Gold $20 and Platinum $40 a month billed annually, from 2 GB to unlimited storage [105]. "Inbox (with Autopilot)" captures documents from Gmail and files them; Household AI; AI Answers at 10 a month on Free and 25 or unlimited on higher tiers; an encrypted vault, SecureLinks and reminders; AES-256 and multi-factor authentication [107, 108, 106]. The "Azure Private AI" claim comes from an April 2024 press release, and the sweep found nothing current on where processing runs [109]. Cloud only, no local processing, no per-matter open items and no case lifecycle. Section 7 called it the nearest commercial neighbour; it files documents and nudges, and it still does not run the case. Casefleet and Prosei (section 7 of this file) are now nearer on structure.

Duckbill (pricing page read 2026-10-06). Human "copilots" plus AI intake. Core $99 a month (about 4 to 6 tasks), Household $169 (about 8 to 12 tasks, 2 members), Household Plus $350 (about 16 to 20 tasks); a $49 Essentials tier appears only in secondary reviews. Tasks arrive by app, text or email, and the humans see everything [110, 111].

Ohai.ai (page read 2026-10-06). A text, email and voice household assistant: a free tier (reminders, meals, lists) and premium from $9.99 a month (shared calendars, family tasks). It syncs Google, Outlook and Apple calendars, scans emails, PDFs and photos to extract dates and propose calendar and task items, and "if something is complicated, like a detailed school schedule or document, human assistants can step in". Cloud; data "never sold or shared for advertising" [112].

Others (unresolved; most facts come from a vendor-run comparison blog). My Personal Admin is still a roadmap (alpha Q2, beta Q3, "Version 1.0: Q4 2026") promising "encrypted end-to-end with zero-knowledge architecture" and human-in-the-loop approvals; no pricing; cloud or local unspecified [113]. Ollie is text-only and scans Gmail or Outlook for school mail (free for 50 messages, then $25 or $100 a month); Carly sells AI executive-assistant agents from $35 a month; Nori is free with a kitchen display; Maple is free with a Maple+ tier; Saner.ai exists. All are cloud services centred on calendar and email with no case structure [114, 115].

Not refreshed: Quicken LifeHub, Everplans and Family Folder from section 7.

## 7. Legal and estate verticals

These are the near-neighbours the brainstorm missed. All are cloud services.

Casefleet (verified). Casefleet markets a lawyer-grade tool to individuals for IRS (US tax) audits, custody and divorce, veterans' (VA) and disability claims, insurance disputes, small claims, estate settlement and HOA (homeowners' association) disputes. "Build a fact chronology of your situation, where every fact links to the document, message, or transcript that proves it." Its AI drafts facts, names and tags for per-record approval: "Casey drafts facts; you approve them." Agentic workflows (multi-step automated work); "Files are encrypted in transit and at rest"; a 14-day trial with a work email and no card; no pricing shown; no hosting region stated [116]. This is fact-level provenance with approval, sold today.

Prosei AI (verified). Cloud case management for self-represented litigants: per-case folders, AI extraction of dates, parties and key points, deadline tracking with calendar sync, and motion drafting where "nothing is submitted without your go-ahead". Free (1 case, 30 documents, $5 in credits), Pro $39.99 a month (3 active cases, 50 documents per case, $25 credits), Premium $89.99 (unlimited, $60 credits), Paralegal $249 ($175 credits). "Bank-level encryption"; no attorney-client privilege; the legal-aid enterprise plan was not seen on the homepage; no hosting region or company jurisdiction stated [117, 118].

Estate executor tools.

- SwiftProbate (verified): a free tier plus $39 one-time; county-level guides for 3,200+ counties; deadlines calculated from the date of death; an AI assistant called Grace [120, 119].
- EstateExec (verified): $199 per estate; AI will and trust analysis added in 2026 [124, 123].
- Atticus (unverified): the $175 to $499 range, the in-house tax and legal experts and the personalised timeline appear only on a competitor's page; Atticus's own site shows no prices [119].
- Empathy (partly verified): free to users through employers and insurers; on 2026-07-07 it announced a broader AI push ("LifeVault Conversations") [125]. The "Lila" assistant and the 5M-employee and 35M-policyholder figures from the first pass were not found; Empathy's 2026 releases cite 50M+ policyholders.
- Alix (verified): a human team at "a flat 1% estate-funded fee (minimum $9,000)"; no AI automation [122, 121].
- EverSettled (verified): $1,999 total ($199 to start, $800, then $1,000 billed to the estate), with an AI called Sage plus a human specialist [126]. The first pass's "$1,499+" was refuted.
- Settled (secondary): free guides plus $19 personalised PDF plans, per SwiftProbate's compare page; the first pass's "$39 workspace" was wrong [119].

All keep per-estate checklists in the cloud; none is local or encrypted with the user's keys. For Sprava: the estate template comes third, after the ones the author lives, and v1 templates carry undated checklists only (decisions.md P9).

Naming (secondary). Products using the word "binder" are vaults with no agent behind them: LifeBinder (a one-time-payment digital binder for legal, financial and estate records), "Binder: Document Organizer" (iOS, OCR, tabbed binders) and Align (trial binders for litigators). Clio and Filex AI extract dates and deadlines for professionals. No consumer product positioned as a "dossier" or an AI "case file" for life admin was found [127, 128, 129, 130]. The sweep ran no trademark checks; the decisions log covers names (decisions.md P11).

## 8. Local-first and open source

Anytype (corrected). Anytype remains local-first and encrypted with peer-to-peer sync, releases every two months or so, and previewed multi-spaces at a September 2026 town hall [131, 132]. In February 2026 it said users may choose no AI, local AI, cloud AI or a hybrid, and that it was prototyping "a local agent ... using whatever API key you choose", "early and experimental" [131]. The first pass concluded there was no shipped AI feature; the verifier refuted that. On 2026-05-28 Anytype opened an alpha waitlist for "AI Ally" (codename Bobrik), an agent "that lives directly inside your Anytype spaces". In the alpha it is a cloud feature, "powered by Claude Sonnet on our infra and through Anthropic's API", with alpha conversations reviewed by Anytype staff; local on-device or private-provider models are promised later [133]. Anytype also documents an open-source "Anytype Agents' Skill" over its Local API for Claude Code, Cursor, Gemini CLI and GitHub Copilot [134]. Nothing is GA. Section 7's "essentially no AI" is stale.

Obsidian and agent plugins (verified). Obsidian's core still has no AI by design. Bases, its native database views, first shipped in 1.9; 1.10 (early access 2025-10-01, public 1.10.3 on 2025-11-11) added Bases features and an API [138, 139]. Vault Operator (Apache-2.0, v3.8.2, 219 releases) is a vault agent that is fail-closed by default: "write operations require approval unless auto-enabled per category" (read, write, plugin API, command, MCP, web); "One-click undo via shadow git checkpoints" (hidden version-control snapshots); "Sensitive folder gating via .obsidian-agentignore"; a three-layer persistent memory; local models through Ollama and LM Studio (tools that run models on the user's own machine); and it acts as an MCP server for ChatGPT, Claude Desktop and Perplexity [135]. Copilot for Obsidian (AGPL-3.0) and Claudian run Claude Code, Codex or opencode inside the vault (not re-verified) [136, 137]. None has a task schema, an obligations model or a digest.

OpenClaw and successors (verified on Wikipedia and vendor docs). The project went from warelay (2025-11-24) to Clawdbot (2026-01-02), Moltbot (2026-01-27) and OpenClaw (2026-01-30). It had 247k GitHub stars and 47.7k forks on 2026-03-02; the creator joined OpenAI on 2026-02-14 and an OpenClaw Foundation took stewardship; China barred state use in March 2026 [140]. "ClawJacked", where any website open in a browser could hijack the agent through a local connection, was disclosed on 2026-02-26 and fixed in v2026.2.25 and later [141]. OpenClaw 2.0 (v2026.8.1, 2026-08-30) was criticised because Secret Store values are not encrypted at rest and the sandbox (the isolation that keeps the agent's actions contained) is off by default [140]. OpenClaw's own docs say plaintext credentials remain readable by the agent when left in openclaw.json, .env or archived auth profiles, and recommend SecretRefs or keychains [143]. Successors: NanoClaw (a container sandbox per action) is named on Wikipedia; Nanobot, memU, NemoClaw and IronClaw rest on aggregator pages [140, 142]. Section 7's "100k+ stars in its first week" is superseded.

Mem0, Letta and Khoj (secondary and aggregator pages). Mem0 (Apache-2.0) shipped v3 in April 2026; its local-first OpenMemory MCP server (May 2025) "has been formally deprecated as of May 2026" and folded into the self-hosted (run on your own machine) Docker and Postgres server [144, 145]. Letta (Apache-2.0, from MemGPT) gives agents editable memory blocks; free up to 3 stateful agents, Pro $20 a month for 20, self-hosting free [148]. Khoj (AGPL-3.0) sunset Khoj Cloud on 2026-04-15 ("Service Deprecated"), is self-host only, was last tagged 2.0.0-beta.28 in March 2026, and offers custom agents, scheduled automations and an Obsidian plugin [146, 147]. These are memory substrates; none is typed state with approval.

Local Mac tools (secondary). Fully on-device Mac tools exist and are search or chat only: Fenn (natural-language search inside PDFs, slides, images, audio and video; "Everything runs fully on device on Apple Silicon Macs, so your data never leaves your computer"), LocalChat (offline chat with documents using GGUF models, a common file format for local models) and Locally AI (runs Apple Foundation Models and open models) [149, 150, 151]. None organizes obligations or files items into projects.

Not refreshed: Mem 2.0, Reflect, Tana, Capacities, Logseq and the local-first sync stacks from section 7.

## 9. Where the white space stands

The digest closes with white-space verdicts, each checked by the verifier against vendor pages. The verifier's conclusion: "None of the corrections overturn the eight white-space verdicts." The digest records the approval gate and provenance as two lines; they appear together here as verdict 9.4, because the claim that survives joins them. Each verdict gives the evidence and what Sprava does about it.

### 9.1 Local-first: holds

Evidence. Every 2026 consumer agent runs its brain on a vendor cloud VM: dots, Muse, Spark, Autopilot, Instinct, Grok Bot, Cue and Amazon Quick [1, 16, 37, 44, 52, 59, 60, 62]. Claude moved new Pro and Max Cowork tasks to cloud-only on 2026-10-06 [68]. Muse for Mac extends a cloud VM [18, 16]. Siri AI sends heavier requests to Private Cloud Compute, now partly on Google Cloud [86, 101]. Spark's spread to 160+ countries strengthens the pattern [38]. The local-only exceptions (Obsidian plugins, Anytype, Khoj, OpenClaw, Fenn) have no obligations model [135, 131, 146, 140, 149].

Erosion. Apple's Foundation Models framework (an on-device model, a Spotlight retrieval tool, OCR, swappable models) makes a local clerk easy for any developer to build [93]. Local-first is a position Sprava chooses; it is no technical moat.

Sprava. Nothing leaves the Mac by default, and the inventory of what can leave is explicit: backup ciphertext (the encrypted form of the binder), Tier 2 MCP clients per binder and opt-in, and, during the transition, the Google Tasks mirror run by the existing hub (the author's current cross-binder tool) (decisions.md P1, A7).

### 9.2 Compartments: hold, with partial erosion

Evidence. Per-container isolation exists in pieces: "Each project has its own separate memory space" in Claude Projects [74]; Vault Operator gates sensitive folders [135]; Cowork scopes cloud sessions to connected folders [68]; Gemini Notebook scopes sources per notebook [40]; Prosei and Casefleet scope per case [117, 116]. No product combines per-episode compartments with a cross-binder roll-up under redaction. None keeps compartments cryptographically: Muse's Confidential VM is unshipped [15], Claude's exclusions are policy [72], and Anytype's AI Ally alpha runs on Anytype's cloud [133].

Sprava. Each binder carries a disclosure setting (full, title, kind or none) that decides what the cross-binder view may show, enforced at the roll-up (decisions.md F6, A8). In v1 Sprava's compartments are also policy and MCP scope, with no cryptography between binders: binders are plain folders on a FileVault disk (macOS whole-disk encryption), and per-binder keys are designed and deferred to sharing and sync (decisions.md A6). The honest claim is "no agent or other binder can see into this one unless you say so, and nothing leaves the Mac".

### 9.3 A structured per-episode case file: holds horizontally, eroded in the verticals

Evidence. For an arbitrary life episode, no product keeps agent-maintained current truth with a lifecycle. General agents hold a profile of the person (Muse, dots, Claude memory) or task lists (Spark's dashboard, Autopilot's goals) [15, 4, 72, 35, 44]. The nearest horizontal structure is a dot that "can work across several projects", a profile-plus-projects model [4]. In legal and estate verticals, per-case structure with extracted dates and deadlines is standard: Prosei, Casefleet, SwiftProbate (deadlines from the date of death) and EstateExec are confirmed on their own pages; Atticus and Empathy rest on secondary pages [117, 116, 120, 124, 119, 125]. Trustworthy files documents and nudges and does not run the case [106].

Sprava. The binder is the product. Templates start with the episodes the author lives (a rental property, a condo-board seat, a tax year) so they get used; estate executor comes third (decisions.md P9).

### 9.4 Approval, provenance and undo: the gate is table stakes, provenance is partly taken, the combined claim survives

Evidence for the approval gate. dots: four rule behaviours plus block, an Auto-review and read-only idle research [3, 4]. Muse: Sentinel as "the sole permission authority", asking before send or buy [16, 15]. Claude Cowork: manual, auto or skip, with deletion always asking [71]. Microsoft consumer Cowork: "review and approve sensitive actions" [46]. Spark: asks before "high-stakes actions like spending money or sending emails" [35]. Vault Operator: fail-closed writes [135]. Prosei: "nothing is submitted without your go-ahead" [117]. Casefleet: "Casey drafts facts; you approve them" [116]. Instinct lacks an approval workflow and sent an unapproved email [52]. The market expects the gate.

Evidence for provenance. Casefleet sells fact-level provenance with approval to individuals [116]. Muse shows "a complete audit trail of everything it has done and plans to do" [15]. Claude exposes memory topic by topic [72]. Vault Operator's shadow-git checkpoints give undo over agent writes to a local vault, without typed state or provenance per fact [135].

What nobody offers. Approval of typed changes to a case file, with provenance on every item and undo, over local state, in an append-only log. The others gate outbound actions only.

Sprava. The catalog (the binder's current state file) is the truth of state and the op log (the append-only list of typed changes) is the truth of history, with content hashes before and after every op, so an outside edit is detected and recorded, and its provenance survives (decisions.md F1). Items carry provenance: source event ids, which tier proposed them, who approved (decisions.md F3). A proposal is an op batch (a set of typed changes) with provenance, confidence and source spans (the stretch of the capture each change came from); cards offer approve, edit or reject; undo is a compensating op (a new change that reverses the earlier one); Tier 1 and Tier 2 proposals look the same in the queue (decisions.md A5).

### 9.5 An agent-neutral open format over MCP: holds, with a reachability constraint

Evidence. No competitor publishes an open on-disk binder format. The nearest are Obsidian vaults (Markdown plus Vault Operator's MCP server) and Anytype's objects as agent memory [135, 134]. Cloud agents reach a local MCP server only through a desktop bridge: Claude cloud sessions reach local folders and MCP servers only while Claude Desktop is open, and scheduled tasks that need local resources run locally only [68, 70]; dots' local computer access is "optional and starts turned off" and needs the ChatGPT desktop app open [5]; Spark's MCP connections are Google's choices (Canva, OpenTable, Instacart) [35]. Muse for Mac now has computer use and file access through Full Disk Access, still with no MCP [18, 19]. So "any assistant writes into your binder" is true today for Claude Desktop and Claude Code, Codex, local agents of the OpenClaw kind, and ChatGPT through a local MCP server; it is false for Muse and Spark [68, 5, 35, 18]. The ChatGPT path is inferred from documentation and was not tested.

Sprava. The MCP surface is one daemon (a background process) with a thin shim (a small adapter program) per client, speaking both revisions of the protocol. Reads are read-only tools; proposals are additive tools that return a handle and never block; nothing is approved over MCP (decisions.md A4). Whether a minimal MCP surface ships in the MVP is open (decisions.md M1).

### 9.6 Availability that does not depend on region: holds, narrowed to the EEA and UK gaps

Evidence (corrected). dots exclude Pro users in the EEA, Switzerland and the UK [4, 14]. Spark is no longer US-only: AI Pro in 160+ countries since 2026-07-30, still excluding the EEA, the UK, Switzerland and Nigeria; Daily Brief remains US-only per the May post [38, 39, 36]. Muse's geography is limited and undated beyond the US [15, 17]. Siri AI is in English with more languages due in October; the Mac is open in the EU, with only iOS, iPadOS and watchOS blocked; China is excluded [85, 86]. The verdict survives because the EEA and UK gaps remain for dots and Spark.

Sprava. A local product has no such gate, except that Tier 1 depends on Apple Intelligence being enabled and available in the user's region and language. Apple's on-device model covers 24 locales and not Ukrainian, which is why the open-model fallback behind the same LanguageModel seam matters (decisions.md P8, P3).

### 9.7 Inbox mining is table stakes: confirmed, do not compete on it

Evidence. dots' read-only proactive research [3]; Google's Daily Brief and AI Inbox (US) [36]; Trustworthy's Inbox with Autopilot [107]; Ollie, Ohai and Maple scan mail [114, 112]; Amazon Quick's proactive background monitoring with action-item notifications [62]; Microsoft Autopilot [44]; and Apple's per-message suggestions in Mail and Messages as a platform-level version [91]. Amazon Quick and the family-assistant trio are secondary only.

Sprava. Email intake is deferred from the MVP (decisions.md M2). Captures come from holos and from documents the user drops in; the clerk files one capture at a time (decisions.md P5, P7).

### 9.8 Platform absorption by Apple: nothing case-file-like, and two moves that cut both ways

Evidence. Siri personal context is a semantic index with actions; Reminders parses natural language; Messages offers one-tap reminder suggestions from a conversation; Files suggests names [86, 92, 91]. None of it files documents, tracks obligations or keeps a per-matter container. The Foundation Models framework lowers Sprava's build cost and everyone else's [93]. The Full Disk Access tightening penalises agents that read the Mail and Messages databases wholesale and favours user-granted folders and capture events [104].

Sprava. The capture-event boundary and user-chosen folders are already the design (decisions.md P6, P7). Binder content never goes into the system Spotlight index (decisions.md A3). Private Cloud Compute stays out unless distribution changes (decisions.md P1, P4).

## 10. Sources

Dates are as the digest gives them: a publication date, or "read 2026-10-06" for a page read during the sweep. "Verifier read" marks pages the verifier opened on 2026-10-06 to check a claim. OpenAI's help-centre pages returned HTTP 403 to direct fetches; their text was read through search excerpts and should be opened once in a browser to confirm.

OpenAI dots

1. TestingCatalog, dots launch. https://www.testingcatalog.com/openai-launches-dots-agents-powered-by-gpt-6-astra.md (2026-09-30)
2. Fortune, dots and ChatGPT Space. https://fortune.com/2026/09/29/openai-takes-on-metas-muse-with-new-dot-agents-and-unveils-a-potential-google-workspace-competitor/ (2026-09-29)
3. OpenAI help centre, dots privacy, security and safety FAQs. https://help.openai.com/en/articles/20001529-dots-privacy-security-and-safety-faqs (verifier read, via search excerpts)
4. OpenAI help centre, getting started with your dot. https://help.openai.com/en/articles/20001530-getting-started-with-your-dot (verifier read, via search excerpts)
5. OpenAI help centre, manage dots in ChatGPT workspaces. https://help.openai.com/en/articles/20001554-manage-dots-in-chatgpt-workspaces (verifier read, via search excerpts)
6. OpenAI help centre, scheduled tasks in ChatGPT. https://help.openai.com/en/articles/10291617-scheduled-tasks-in-chatgpt (verifier read, via search excerpts)
7. OpenAI help centre, agent security and local work sync. https://help.openai.com/en/articles/20001548-agent-security-and-local-work-sync-in-chatgpt (verifier read, via search excerpts)
8. Search Engine Journal, dots read-only proactive research. https://www.searchenginejournal.com/openai-dots-read-only-proactive-research/591565/ (2026-09-30)
9. General Analysis, dots security controls. https://generalanalysis.com/guides/openai-dots-security-controls (2026-09-30)
10. DataCamp, OpenAI dots. https://www.datacamp.com/blog/openai-dots (2026-09/10)
11. Medianama, dots at DevDay. https://www.medianama.com/2026/10/223-openai-launches-dots-devday-2026/ (2026-10)
12. NYU Shanghai RITS, dots summary. https://rits.shanghai.nyu.edu/ai/openai-dots-always-on-agents/ (2026-09/10)
13. TechCrunch, dots launch. https://techcrunch.com/2026/09/29/openai-launches-dots-its-bubbly-agentic-avatar/ (2026-09-29)
14. OpenAI community forum, dots unavailable for Pro users in the EEA. https://community.openai.com/t/dots-looks-exactly-like-what-i-need-but-it-s-unavailable-for-pro-users-in-the-eea/1402170 (verifier read)

Meta Muse

15. Meta newsroom, introducing Muse. https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/ (2026-09-08, updated 2026-09-30)
16. Meta research, security and safety for AI agents with Muse. https://research.meta.ai/blog/security-and-safety-for-ai-agents-our-approach-with-muse (verifier read)
17. Meta help centre, Muse subscriptions. https://www.meta.com/help/subscriptions/1021145227643680/ (verifier read)
18. Meta help centre, Muse for Mac. https://www.meta.com/help/artificial-intelligence/1126304576638594/ (verifier read)
19. Meta blog, everything announced at Connect 2026. https://www.meta.com/blog/meta-connect-2026-everything-we-announced/ (2026-09-23, verifier read)
20. TechCrunch, Muse hits the Mac. https://techcrunch.com/2026/09/18/metas-muse-hits-mac-letting-the-ai-take-actions-on-your-computer/ (2026-09-18)
21. moveros.dev, Muse UK availability tracker. https://moveros.dev/availability/muse-uk (2026-10-01)
22. Codersera, Muse app guide. https://codersera.com/blog/meta-muse-ai-agent-app-guide-2026/ (2026-09)
23. Tech Insider, Muse launch. https://tech-insider.org/meta-muse-personal-ai-agent-launch-2026/ (2026-09)
24. Implicator, Muse friend profiles and privacy. https://www.implicator.ai/meta-muse-friends-profiles-privacy/ (2026-10-04)
25. Gizmodo, Muse collects information on everyone in your life. https://gizmodo.com/metas-muse-is-collecting-information-on-everyone-in-your-life-2000821697 (2026-10-05, verifier read)
26. Meta engineering lead on X, hotfix confirmation. https://x.com/dps/status/2102248329111634067 (2026-09-22, verifier read)
27. Gizmodo, Muse zero-day patched. https://gizmodo.com/meta-just-patched-a-major-zero-day-vulnerability-in-its-muse-ai-assistant-2000815429 (verifier read)
28. mouse.dev, Muse runtime export. https://mouse.dev/blog/muse-runtime-export/ (verifier read)
29. The Next Web, Muse private-messages denial. https://thenextweb.com/news/meta-muse-private-messages-denial-jason-aten (2026-09-30)
30. AppleInsider, Muse ignores user permissions. https://appleinsider.com/articles/26/09/28/metas-new-ai-agent-blatantly-ignores-users-permissions (2026-09-28, verifier read)
31. 404 Media, Muse VM escape fixed before launch. https://www.404media.co/meta-rushed-to-fix-muse-vm-escape-vulnerability-immediately-before-launch/ (verifier read)
32. GeekWire, Amazon blocks Muse. https://www.geekwire.com/2026/amazon-blocks-metas-muse-ai-assistant-in-new-standoff-over-agentic-shopping/ (verifier read)
33. Techdirt, Muse privacy and security. https://www.techdirt.com/2026/10/06/metas-muse-is-an-adorable-privacy-and-security-dumpster-fire/ (2026-10-06)
34. dev.to, Muse security: Mac zero-day and the 6.8 GB export. https://dev.to/axrisi/meta-muse-security-a-mac-zero-day-and-a-68-gb-filesystem-export-287f (2026-10-02)

Google

35. Google blog, the next evolution of the Gemini app (Spark). https://blog.google/innovation-and-ai/products/gemini-app/next-evolution-gemini-app/ (2026-05-19)
36. Google blog, Google AI subscriptions (Spark, Daily Brief). https://blog.google/products-and-platforms/products/google-one/google-ai-subscriptions/ (2026-05-19)
37. TechCrunch, Gemini Spark. https://techcrunch.com/2026/05/19/google-introduces-gemini-spark-a-24-7-agentic-assistant-with-gmail-integration/ (2026-05-19)
38. Google blog, Gemini Spark updates July 2026. https://blog.google/innovation-and-ai/products/gemini-app/gemini-spark-updates-july-2026/ (2026-07-30)
39. 9to5Google, Spark Chrome auto-browse and expansion. https://9to5google.com/2026/07/30/gemini-spark-chrome-auto-browse/ (2026-07-30)
40. Google blog, NotebookLM becomes Gemini Notebook. https://blog.google/innovation-and-ai/products/gemini-notebook/notebooklm-gemini-notebook/ (2026-07-16)
41. Elephas, what is NotebookLM. https://elephas.app/blog/what-is-notebooklm (2026)
42. TechSmartGuide24, Google Keep features 2026. https://techsmartguide24.com/2026/09/03/google-keep-new-features-2026/ (2026-09-03)
43. Android Police, Gemini, Keep and Tasks. https://www.androidpolice.com/connected-gemini-google-keep-tasks-fixed-chaotic-workflow/ (2026)

Microsoft

44. Microsoft blog, the new Copilot with Home, Code and Autopilot. https://blogs.microsoft.com/blog/2026/09/25/introducing-the-new-copilot-with-home-code-and-autopilot/ (2026-09-25)
45. Microsoft Copilot blog, introducing Scout. https://www.microsoft.com/en-us/copilot/blog/2026/06/02/introducing-microsoft-scout-your-always-on-personal-agent/ (2026-06-02)
46. Microsoft support, changes to the Microsoft Copilot app. https://support.microsoft.com/en-us/microsoft-365-copilot/learning/changes-microsoft-copilot-app (read 2026-10-06)
47. Microsoft 365 blog, Copilot Cowork generally available. https://www.microsoft.com/en-us/microsoft-365/blog/2026/06/16/copilot-cowork-is-now-generally-available/ (2026-06-16, verifier read)
48. Microsoft Learn, usage-based billing with Copilot Credits. https://learn.microsoft.com/en-us/microsoft-365/copilot/usage-based-billing-overview-copilot-credits (verifier read)
49. Quisitive, Copilot Cowork pricing 2026. https://quisitive.com/copilot-cowork-pricing-2026-how-usage-based-billing-works/ (2026)

Notion

50. Notion help, Custom Agent pricing. https://www.notion.com/help/custom-agent-pricing (read 2026-10-06)
51. Reworked, Notion Custom Agents reach GA. https://www.reworked.co/digital-workplace/notion-custom-agents-reach-general-availability/ (2026-05)

Instinct, Grok Bot, Manus Cue, Amazon Quick

52. TechCrunch, Instinct privacy and security concerns. https://techcrunch.com/2026/08/24/instincts-powerful-ai-assistant-is-raising-privacy-and-security-concerns/ (2026-08-24)
53. gyld.ai, Instinct review and incident list. https://gyld.ai/blog/instinct-ai-review-impressive-agent-real-privacy-risks (2026-09-17)
54. Axios, personal AI assistants roundup. https://www.axios.com/2026/09/20/ai-assistant-openai-meta-muse-instinct-grok-apple (2026-09-20)
55. eesel, Instinct pricing. https://www.eesel.ai/blog/instinct-ai-pricing (2026-09-30)
56. Yahoo Finance, Instinct funding. https://finance.yahoo.com/technology/ai/articles/viral-ai-startup-instinct-raised-002457707.html (verifier read)
57. Bloomberg, Instinct raises $1 billion at $10 billion. https://www.bloomberg.com/news/articles/2026-09-28/ai-agent-startup-instinct-raises-1-billion-at-10-billion-value (2026-09-28)
58. SiliconANGLE, Instinct raises $1B at $10B. https://siliconangle.com/2026/09/28/everyday-personal-ai-assistant-startup-instinct-raises-1b-at-10b-valuation/ (2026-09-28)
59. Implicator, Grok Bot pricing. https://www.implicator.ai/spacexai-grok-bot-starts-at-120-a-seat/ (2026-08)
60. Implicator, Manus Cue agents. https://www.implicator.ai/manus-cue-agents-phone-numbers-wallets/ (2026-09-28)
61. The Next Web, Manus 2.0 Cue. https://thenextweb.com/news/manus-2-0-cue-ai-agents-email-phone-wallet (2026-09-28)
62. SiliconANGLE, Amazon Quick desktop. https://siliconangle.com/2026/04/28/amazon-revamps-quick-proactive-desktop-app-gets-work-done/ (2026-04-28)

Claude

63. TestingCatalog, Claude merges Cowork and chat. https://www.testingcatalog.com/claude-merges-cowork-and-chat-into-one-experience/ (2026-09-17)
64. pasqualepillitteri.it, Cowork GA April 9. https://pasqualepillitteri.it/en/news/755/anthropic-managed-agents-cowork-ga-april-9-2026 (2026-04)
65. fast.io, Claude Cowork pricing plans. https://fast.io/resources/claude-cowork-pricing-plans/ (2026)
66. Anthropic blog, Cowork for enterprise (GA). https://claude.com/blog/cowork-for-enterprise (2026-04-09, verifier read)
67. Anthropic blog, Cowork is now Claude. https://claude.com/blog/cowork-is-now-claude (2026-09-16, verifier read)
68. Claude help centre, use Claude Cowork on web, desktop and mobile. https://support.claude.com/en/articles/15520349-use-claude-cowork-on-web-desktop-and-mobile (read 2026-10-06)
69. Claude help centre, get started with Claude Cowork. https://support.claude.com/en/articles/13345190-get-started-with-claude-cowork (read 2026-10-06)
70. Claude help centre, schedule recurring tasks in Claude Cowork. https://support.claude.com/en/articles/13854387-schedule-recurring-tasks-in-claude-cowork (read 2026-10-06)
71. Claude help centre, use Claude Cowork safely. https://support.claude.com/en/articles/13364135-use-claude-cowork-safely (read 2026-10-06)
72. TechCrunch, Claude Cowork memory. https://techcrunch.com/2026/08/25/claude-cowork-finally-remembers-what-you-told-the-app-in-chat/ (2026-08-25)
73. Anthropic blog, Claude's memory works everywhere. https://claude.com/blog/claudes-memory-works-everywhere-and-you-decide-whats-in-it (2026-08-25, verifier read)
74. Claude help centre, chat search and memory. https://support.claude.com/en/articles/11817273-use-claude-s-chat-search-and-memory-to-build-on-previous-context (verifier read)
75. memorylake.ai, Claude Projects thread memory. https://www.memorylake.ai/en/blogs/claude-projects-thread-memory (2026-09)
76. DevOps.com, Anthropic adds a coordinator to Claude Projects. https://devops.com/anthropic-adds-a-coordinator-to-claude-projects-for-running-ai-work-in-parallel/ (2026-09-17)
77. DataStudios, new Claude Code Projects. https://www.datastudios.org/post/anthropic-launches-new-claude-code-projects-with-parallel-ai-agents-and-shared-memory (2026-09)
78. Anthropic blog, Projects redesigned. https://claude.com/blog/projects-redesigned (2026-09-17, verifier read)
79. Claude help centre, what are Projects. https://support.claude.com/en/articles/9517075-what-are-projects (verifier read)
80. Claude Code docs, Claude Projects. https://code.claude.com/docs/en/claude-projects (verifier read)
81. Claude pricing page. https://claude.com/pricing (verifier read)
82. heyuan110, Claude pricing roundup. https://www.heyuan110.com/posts/ai/2026-02-25-claude-code-pricing/ (2026-02-25)

Apple

83. MacRumors, macOS 27 roundup. https://www.macrumors.com/roundup/macos-27/ (read 2026-10-06)
84. iGeeksBlog, Siri AI features in iOS 27. https://www.igeeksblog.com/siri-ai-ios-27-features/ (2026-09-25)
85. Apple newsroom, major updates for Apple's software platforms. https://www.apple.com/newsroom/2026/09/major-updates-for-apples-software-platforms-are-now-available/ (2026-09, verifier read)
86. Apple newsroom, Siri AI. https://www.apple.com/newsroom/2026/09/siri-ai-a-profoundly-more-capable-and-personal-assistant-is-here/ (2026-09, verifier read)
87. Apple support, Siri AI availability and waitlist. https://support.apple.com/en-us/127893 (verifier read)
88. 9to5Mac, everything new for Reminders. https://9to5mac.com/2026/08/26/heres-everything-new-for-reminders-in-ios-27/ (2026-09-29)
89. 9to5Mac, 20 new Apple Intelligence features in iOS 27. https://9to5mac.com/2026/09/18/apple-intelligence-has-20-brand-new-features-in-ios-27-heres-the-full-list/ (2026-09-18)
90. MacRumors, WWDC 2026 recap. https://www.macrumors.com/2026/06/08/wwdc-2026-recap/ (2026-06-08)
91. Apple newsroom, Apple Intelligence in everyday experiences. https://www.apple.com/newsroom/2026/06/apple-intelligence-brings-powerful-ai-capabilities-into-everyday-experiences/ (2026-06-08, verifier read)
92. MacRumors guide, iOS 27 Calendar and Reminders. https://www.macrumors.com/guide/ios-27-calendar-reminders/ (verifier read)
93. Apple WWDC26 session 241, Foundation Models. https://developer.apple.com/videos/play/wwdc2026/241/ (2026-06)
94. dev.to, what's new in Apple's Foundation Models framework. https://dev.to/hariharanjagan/whats-new-in-apples-foundation-models-framework-at-wwdc-2026-5227 (2026-06)
95. ivanmagda.dev, Foundation Models year two (the conflicting 4,096 figure). https://ivanmagda.dev/posts/wwdc26-foundation-models-year-two/ (2026-06)
96. Apple developer documentation, SystemLanguageModel.contextSize. https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize (verifier read)
97. 9to5Mac, Apple's new Foundation Models explained. https://9to5mac.com/2026/06/11/apples-new-foundation-models-explained-on-device-ai-cloud-ai-and-everything-in-between/ (2026-06-11)
98. The Next Web, Apple's third-generation Foundation Models. https://thenextweb.com/news/apple-third-generation-foundation-models-afm (2026-06)
99. MacRumors, Private Cloud Compute on Google's servers. https://www.macrumors.com/2026/06/08/apple-private-cloud-compute-google/ (2026-06-08)
100. Apple Machine Learning Research, third generation of Apple Foundation Models. https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models (2026-06-08, verifier read)
101. Apple Security Research, expanding Private Cloud Compute. https://security.apple.com/blog/expanding-pcc/ (2026-06-08, verifier read)
102. TechCrunch, Apple tightens Full Disk Access. https://techcrunch.com/2026/10/02/apple-says-its-tightening-macos-full-disk-access-controls-due-to-new-risks-from-ai-agents/ (2026-10-02)
103. MacRumors, Apple announces Full Disk Access changes. https://www.macrumors.com/2026/10/02/apple-announces-macos-full-disk-access-changes/ (2026-10-02)
104. Apple developer news, updates to Full Disk Access in macOS. https://developer.apple.com/news/?id=p6zjojqw (2026-10-02, verifier read)

Vaults and family assistants

105. Trustworthy pricing. https://www.trustworthy.com/pricing (read 2026-10-06)
106. Trustworthy homepage. https://www.trustworthy.com/ (read 2026-10-06)
107. Trustworthy help centre, Inbox with Autopilot. https://help.trustworthy.com/en/articles/4658625 (verifier read)
108. Trustworthy help centre, AI Answers. https://help.trustworthy.com/en/articles/11104129 (verifier read)
109. PR Newswire, Trustworthy AI features (the Azure claim). https://www.prnewswire.com/news-releases/trustworthy-sets-the-new-standard-in-family-digital-transformation-through-its-revolutionary-new-ai-features-302131556.html (2024-04)
110. Duckbill pricing. https://lp.getduckbill.com/pricing (read 2026-10-06)
111. Peacock Parent, Duckbill and Yohana review. https://peacockparent.com/duckbill-review-yohana-review/ (2026)
112. Ohai.ai homepage. https://www.ohai.ai/ (read 2026-10-06)
113. My Personal Admin homepage. https://www.mypersonaladmin.com/ (read 2026-10-06)
114. Carly blog, Ollie vs Ohai (vendor-run). https://www.usecarly.com/blog/ollie-vs-ohai/ (2026)
115. Carly blog, best family organizer apps (vendor-run). https://www.usecarly.com/blog/best-family-organizer-apps/ (2026)

Legal and estate

116. Casefleet, personal document organization. https://www.casefleet.com/use-cases/personal-document-organization (read 2026-10-06)
117. Prosei AI homepage. https://www.prosei.ai/ (read 2026-10-06)
118. Prosei AI blog, pro se case management guide. https://www.prosei.ai/blog/pro-se-case-management-complete-guide (2026)
119. SwiftProbate blog, best AI tools for estate executors (includes the Atticus and Settled claims). https://www.swiftprobate.com/blog/best-ai-tools-estate-executors (2026-04-04)
120. SwiftProbate, AI probate tool. https://www.swiftprobate.com/ai-probate-tool (verifier read)
121. SwiftProbate, compare with Alix. https://www.swiftprobate.com/compare/alix (2026-04-24)
122. Alix, flat-fee post. https://www.meetalix.com/post/what-full-service-estate-settlement-company-charges-a-flat-fee-instead-of-a-percentage-of-the-estate-value-like-some-competitors (verifier read)
123. Capterra, EstateExec. https://www.capterra.com/p/10002858/EstateExec/ (2026)
124. EstateExec pricing. https://www.estateexec.com/pricing.html (verifier read)
125. Built In NYC, Empathy's AI platform. https://www.builtinnyc.com/articles/empathy-ai-platform-20260707 (2026-07-07)
126. EverSettled homepage. https://www.eversettled.com/ (verifier read)
127. LifeBinder. https://lifebinder.com/ (read 2026-10-06)
128. App Store, Binder: Document Organizer. https://apps.apple.com/us/app/binder-document-organizer/id6755253047 (2026)
129. Align, digital binder software for litigators. https://align.lawyer/resources/the-best-digital-binder-software-in-2026-what-litigators-should-actually-look-for (2026)
130. Filex AI, AI document management apps. https://filexai.com/blog/best-ai-document-management-apps (2026)

Local-first and open source

131. Anytype blog, February 2026 community update. https://blog.anytype.io/february-community-update-2026/ (2026-02)
132. Anytype community, roadmap update February 2026. https://community.anytype.io/t/roadmap-update-2026-feb/30112 (2026-02)
133. Anytype community, AI agent on Anytype alpha demo (AI Ally). https://community.anytype.io/t/ai-agent-on-anytype-alpha-demo/30881 (2026-05-28, verifier read)
134. Anytype docs, Anytype Agents' Skill. https://doc.anytype.io/anytype/features/integrations/anytype-agents-skill (verifier read)
135. Obsidian plugin directory, Vault Operator. https://community.obsidian.md/plugins/vault-operator (read 2026-10-06)
136. Obsidian plugin directory, Copilot. https://community.obsidian.md/plugins/copilot (read 2026-10-06)
137. dev.to, Obsidian AI 2026. https://dev.to/saaro_net/obsidian-ai-2026-from-a-pile-of-notes-to-a-knowledge-base-for-ai-agents-2a5n (2026)
138. Obsidian changelog, desktop 1.10.0. https://obsidian.md/changelog/2025-10-01-desktop-v1.10.0/ (2025-10-01, verifier read)
139. Obsidian changelog, desktop 1.10.3. https://obsidian.md/changelog/2025-11-11-desktop-v1.10.3/ (2025-11-11, verifier read)
140. Wikipedia, OpenClaw. https://en.wikipedia.org/wiki/OpenClaw (read 2026-10-06)
141. Oasis Security, OpenClaw vulnerability (ClawJacked). https://www.oasis.security/blog/openclaw-vulnerability (2026)
142. Bitdoze, OpenClaw alternatives. https://www.bitdoze.com/openclaw-alternatives/ (2026)
143. OpenClaw docs, gateway secrets. https://docs.openclaw.ai/gateway/secrets (verifier read)
144. ContextBolt, Mem0 MCP. https://contextbolt.com/blog/mem0-mcp/ (2026)
145. Mem0 blog, introducing OpenMemory MCP. https://mem0.ai/blog/introducing-openmemory-mcp (2025-05-13)
146. Khoj app (service deprecated notice). https://app.khoj.dev/ (read 2026-10-06)
147. Khoj GitHub releases. https://github.com/khoj-ai/khoj/releases (2026-03)
148. CompareEdge, Letta pricing. https://comparedge.com/tools/letta-ai/pricing (2026)
149. Shyft, Fenn. https://www.shyft.ai/tools/fenn (2026)
150. LocalChat blog, AI for Mac. https://www.localchat.app/blog/artificial-intelligence-for-mac (2026)
151. Locally AI. https://locallyai.app/ (read 2026-10-06)
