# Importers and exporters

Status: draft for the author, 2026-10-07 (decisions.md P17). It formalizes what binders do ad hoc today: a mail
monitor configured in a binder's `scripts/` folder, a work-tracking service an agent remembers to check, and
email drafts an agent writes when asked. Nothing here is built yet. Examples are invented.

## 1. The idea

An **integration** connects one binder to one outside system, in one direction.

- An **importer** brings material in: mail from one label, updates from one work-tracking account, files
  from one watched folder. It writes into the binder's `intake/`, and the adaptation layer reads what lands
  there like any other file (`docs/adaptation-layer.md`).
- An **exporter** takes approved instructions out: create an email draft, post an update, write a calendar
  file. It reads instructions from the binder's `outgoing/` and acts on them only after the person approved
  them.

Each integration is an instance of a **plugin**, a kind of integration Sprava knows how to run: the IMAP
importer, the monday.com importer, the IMAP draft exporter. The binder says which integrations it has and how
they are set; Sprava runs them. What an agent once had to remember becomes structure the binder carries.

Today's example, invented: a binder `rental-elm-street` reads the mail label `Labels/Elm-Street` with a
monitor configured in `scripts/mail/.env`, gets its building manager's updates from a work-tracking service
that the agent checks when it remembers, and has the agent write reply drafts when the person asks, using the
same `.env`. After this design: two importers and one exporter, each visible on the binder's page, each with
a health line, none relying on memory or hand instructions.

The hub lane is already such a pair, built in: the drain imports check-offs, the publish exports the agenda
slice (binder-v0 §8). It can be described as built-in integrations later without changing its behaviour.

## 2. Principles

1. **Configuration in the binder, secrets never.** What a binder is connected to (which label, which board,
   which draft folder) is part of the binder's knowledge and travels with it. Credentials never do: they live
   in the Keychain under an account entry, and the binder names the account. Today's `scripts/*/.env` files
   hold passwords in plain text inside the binder, where backups, terminal agents and any brain with shell
   access can read them.
2. **Plugins are installed in Sprava, never found in a binder.** Sprava runs no code that lives inside a
   binder (decisions.md F9). A binder can only name a plugin Sprava already has. Built-in plugins come
   first; outside plugins, if ever, are separate executables with a manifest, run sandboxed with the network
   hosts they declare.
3. **Importers only add to `intake/`.** They never touch the catalog. Everything they bring is read, carded
   and approved like any other intake file, and carries how it was obtained (P16): `channel` (`email`,
   `service`), `from`, and the integration's id.
4. **Exporters act only on approved instructions, and never send on the person's behalf.** The email
   exporter creates a draft; the person sends it from their mail app. Every external effect is recorded in
   the binder's history and counted in the inventory of what leaves the Mac (decisions.md A7).
5. **Each integration is a runtime job** with a time budget, a breaker and a Health line (architecture 3.4),
   and its cursor (the last message seen, the last update read) is kept in Sprava's own state, outside the
   binder.
6. **One account, many binders.** An IMAP account or a service account is set up once; each binder's
   integration names it and adds its own filter (a label, a board).

## 3. Where it lives

```
<binder>/
  intake/                     importers write here; the adaptation layer reads it
    mail/                     the IMAP importer's files (one message: the .eml and a folder of attachments)
  outgoing/                   instructions for exporters (visible, so agents and the person can write one)
    <id>.json                 an instruction waiting for approval
    done/<id>.json            an instruction carried out, with its result
  .sprava/integrations.json   which integrations this binder has, and their settings (no secrets)

Sprava's own state:
  accounts.json               account entries (kind, host, user name), each with a Keychain item for its secret
  integrations/<binder-id>/   each integration's cursor and last result
```

`.sprava/integrations.json`, invented:

```json
{
  "format_version": "0",
  "integrations": [
    {"id": "mail-in", "plugin": "imap-import", "account": "mail-1",
     "folder": "Labels/Elm-Street", "filter": {"since": "2026-10-01"}, "mark_read": false},
    {"id": "tracker-in", "plugin": "monday-import", "account": "tracker-1",
     "boards": ["1234567890"], "include": ["updates", "status_changes"]},
    {"id": "mail-drafts", "plugin": "imap-draft-export", "account": "mail-1", "drafts_folder": "Drafts"}
  ]
}
```

`outgoing/` is a binder folder. It is named so that it does not collide with the hub spool's `outbox/`
(binder-v0 §8), which lives outside every binder and is a different thing (decisions.md P18).

binder-v0 does not allow these writes yet. Before any integration is built, its folder table (§3.2) and its
write rule (§9.7) gain two entries: an importer may create new files in `intake/`; and `outgoing/` holds
instructions that people and agents write, which an implementation reads, and moves to `outgoing/done/` with
their result once carried out. It writes nothing else there. Until then an implementation leaves `outgoing/`
alone.

## 4. Importers

### 4.1 IMAP, with a filter (built in)

What `imap-extract` does today, kept: one folder or label per integration; IMAP IDLE for prompt arrival, with
a periodic sync as the guarantee; a UID cursor; a first run that starts from the newest message instead of
importing the whole history; mail left unread on the server unless the person asks otherwise; STARTTLS for a
local mail bridge.

What changes inside Sprava:

- The original message is kept as an `.eml` file, so nothing is lost to the Markdown conversion and the
  Message-ID survives for replies (4.4, 5.2). The adaptation layer's email adapter reads the `.eml`.
- Files are written atomically (a temporary name, then a rename), so the intake watcher never reads half a
  message, and a message's attachments are written before the message itself.
- A filter beyond the folder: sender, subject words, a date floor, all applied after fetching.
- A local mail bridge's self-signed certificate is pinned on first use instead of accepting every
  certificate.
- The password is read from the Keychain; nothing is read from `.env`.

Implementation: a Swift port inside the runtime, reusing `imap-extract`'s logic and tests (about 800 lines of
Rust in `orlenko/homebrew-tap`), rather than running the binary as a subprocess. The binary writes in place,
drops the original message and keeps its own `.env` and `state.json`, all of which this design replaces.

### 4.2 monday.com (built in)

Reads one account's chosen boards through monday.com's GraphQL API with a personal API token from the
Keychain. Each new update (a comment on an item), and each status change when asked for, becomes one intake
file: the text as Markdown plus a small JSON of facts (board, item, author, time), with `obtained.channel:
service`, `obtained.from` the update's author, and the integration id. A cursor per board avoids re-reading.
Polling every few minutes stays well inside the API's rate limits. To verify before building: the exact
queries for updates and activity since a cursor, and the token's scopes.

### 4.3 A watched folder (built in, later)

A folder outside the binder (a scanner's output, a downloads subfolder) whose new files are moved into the
binder's `intake/`, with `obtained.channel` set from the integration (`paper` for a scanner's folder).

### 4.4 What every importer records

Each imported file carries, in a sidecar the adaptation layer reads: the integration id, the outside system's
own id for the thing (a Message-ID, an update id), `obtained.channel`, `obtained.from`, and when it was
received. The outside id is what lets an exporter answer the right thing later, and what lets the importer
skip duplicates after a restore.

## 5. Exporters

### 5.1 The outgoing folder

An instruction is a small JSON file in the binder's `outgoing/`. It can come from three places:

- an approved card: the clerk classifies an email as "action needed: reply" (P13), a smarter model drafts the
  reply, and the card offers "create this draft";
- a connected brain, through a new MCP tool that writes an instruction as a proposal;
- the person, or an agent working in the binder, writing the file directly.

Whatever its origin, an instruction in `outgoing/` is a request, never an order. The runtime turns it into a
card; only when the person approves the card does the exporter run. A file an agent wrote by hand is shown as
"not written by Sprava", as foreign proposal files are today. After the exporter runs, the instruction moves
to `outgoing/done/` with its result, and the binder's history gets one log entry ("draft created: subject").

A crash can come after the outside system acted and before the instruction moved. So every exporter is safe
to retry: before it acts, it records the instruction's id as started in Sprava's own state, and it marks
what it creates with that id. An instruction found started is first looked for at the destination; if it is
there, the result is recorded and nothing is created again.

An instruction, invented:

```json
{
  "format_version": "0",
  "exporter": "mail-drafts",
  "action": "create_draft",
  "to": ["manager@example.com"],
  "subject": "Re: Heater repair at Elm Street",
  "in_reply_to": "<message-id of the imported email>",
  "body_markdown": "Thank you, Thursday works. ...",
  "attachments": ["documents/heater-quote.pdf"]
}
```

### 5.2 IMAP draft (built in)

Builds a MIME message (plain text, and HTML from the Markdown), sets `In-Reply-To` and `References` from the
imported message so the draft threads in the person's mail app, attaches files only from the binder's own
document folders, and appends it to the account's drafts folder with the `\Draft` flag. It never sends: there
is no SMTP in Sprava. The result records the draft's UID and the folder. The draft's Message-ID is made from
the instruction's id, so a retry first searches the drafts folder for it (`UID SEARCH HEADER Message-ID`)
and appends only when it is not there.

### 5.3 Later exporters

- monday.com: post an update on an item, after approval.
- Calendar: write an `.ics` file for a deadline, for the person to open.
- Others when a binder needs them, each a plugin with a small instruction schema.

## 6. In the app

- **Accounts** (Settings): add an IMAP account or a monday.com token once; Sprava stores the secret in the
  Keychain and tests the connection.
- **Connections** (each binder's page): the binder's importers and exporters, each with its last run, its
  health colour, and buttons to pause or remove it; "Add connection" picks a plugin and an account and asks
  for its filter.
- **Moving from today's setup:** the adoption survey already counts credential files in a binder
  (binder-v0 §9.2). For a binder whose `scripts/` holds an IMAP `.env`, the Connections page offers to set up
  the same integration; the person enters the password again into Sprava, then stops the old monitor and may
  delete the `.env`. Sprava never reads the password out of the file.

## 7. Security and privacy

- Credentials only in the Keychain; never in a binder, a log, a card or an MCP answer.
- An exporter's output leaves the Mac: it is listed in the inventory of what leaves (A7) and counted on the
  Health page by integration, never by content.
- Importers bring other people's text into the binder, so everything they bring is private by default and
  is read by the clerk on the device; a smarter model sees it only as P13's escalation allows.
- An instruction can only attach files from the binder's own document folders, checked after resolving
  links, so a crafted instruction cannot mail out another binder's documents or a file elsewhere on the Mac.
- An exporter never runs without an approval from the app, by the same rule that guards every op
  (architecture 4.6).

## 8. Questions for the author

1. Is this in the MVP, or the first feature after it? The IMAP importer and the draft exporter would replace
   habits used daily; the monday.com importer replaces a habit that currently depends on an agent's memory.
2. Should integration settings live in the binder (`.sprava/integrations.json`, travels with backups and
   restores) as proposed, or only in Sprava's own state?
3. Answered 2026-10-07: the visible folder is `outgoing/`, not `outbox/`, so it does not collide with the
   hub spool's `outbox/` (decisions.md P18).
4. Port `imap-extract` to Swift inside Sprava (recommended), or extend the Rust tool and run it as a
   supervised subprocess?
