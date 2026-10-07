# The adaptation layer

Status: draft, revised 2026-10-07 with the author's decisions P12 to P16 (decisions.md). Sprava is
input-agnostic: it receives text, images, office documents and PDFs, through an adaptation layer that
establishes the ingestion protocol for each type. Audio and video are not part of Sprava. Nothing here is
built yet, except what section 7 lists.

## 1. What the layer is for

Sprava's core does one thing with new material: it reads it, proposes changes to binders, and waits for the
person. The core never knows which tool produced the material. A note typed or dictated with any tool, a PDF
from a bank, a photo of a paper letter, an email saved by a mail monitor: by the time the core sees any of
them, each is the same kind of object.

The adaptation layer sits between the world and that object. It has two jobs:

- turn each type of input into the one inbound contract the core reads (section 3);
- make a new type cheap to add: a short descriptor, one extraction step if a new one is needed, and fixtures
  (section 6).

Out of scope for the layer:

- How a person produces text (P12). The keyboard, built-in dictation, a commercial tool: invisible to Sprava.
- Audio and video (P14).
- Writing to a binder. Adapters and the reading pipeline produce cards; the person approves them
  (architecture 6). Nothing is filed behind the person's back.
- Any one producer. No adapter is privileged and none is required.

## 2. Principles

1. **One contract.** Everything enters as a capture event (capture-event-v0 §3): text, the original files as
   media, and a few facts. The core never reads an adapter's private `extensions`.
2. **Type adapters and sources.** A *type adapter* turns a kind of content into text and facts: plain text,
   image, office document, PDF, email file. A *source* is where material arrives: a binder's `intake/` folder
   (the main one), Sprava's note field, drag and drop, the share sheet, and any outside program that writes
   capture events.
3. **Read in full (P13).** A file in intake is read completely: every page through OCR when it has no text
   layer, every part of an office document. Limits exist only for safety (a file that is enormous or that
   hangs the parser); a file stopped by one is held for the person, never filed half-read without saying so.
4. **Code first, then the local model, then a smarter one (P13).** Deterministic steps come first (text layer,
   OCR, headers, dates, amounts, known senders), because they make classification easier and are always
   right about what they find. The local model then classifies and reads. A smarter model follows up only
   when warranted (section 4.4).
5. **Untrusted input, parsed apart.** Files come from other people. Every parser runs in the sandboxed
   extraction helper of architecture 2.1: no network, no Keychain, one file at a time, a time budget, a crash
   that kills only the helper. Nothing in a file is executed: no PDF JavaScript, no macros, no links followed,
   no remote images loaded.
6. **Originals are kept unchanged.** The original file is copied beside the event as media with its SHA-256
   (capture-event-v0 §3.5). Derived copies (a photo without location data, OCR text) are separate.
7. **How it was obtained is always recorded (P16).** Every capture says how the information reached the
   person: by email, a paper letter they scanned, a download, a note they wrote. Sources fill in what they
   know; the person's own words win.
8. **Private by default for other people's material.** Documents, images and email default to
   `sensitivity: private`; a note the person wrote defaults to `unmarked` (capture-event-v0 §3.3).

## 3. The contract

The contract is capture-event-v0, with the changes in 3.2.

### 3.1 What an adapter fills in

| Field | Filled by | Notes |
|---|---|---|
| `source.app` | the adapter's id (`sprava.intake`, `sprava.note`) or an outside program's name | Registered per device folder (architecture 8). |
| `source.kind` | the content type: `text`, `image`, `document`, `pdf`, `email` | See 3.2. |
| `source.ref`, `source.revision` | an id for the underlying thing, and a version key | For a file: its SHA-256 is the revision. |
| `obtained` | how the information reached the person (P16) | See 3.3. |
| `text` | the full extracted text, normalized (NFC; control and bidi characters removed) | Empty only for a retraction. |
| `title` | the file name, or the first line of a note | |
| `media[]` | the original and any derived copies, with `sha256`, `bytes`, `mime` | |
| `captured_at`, `ended_at` | when the material arrived, and when entering it ended | The minute counts from `ended_at`. |
| `locale` | the language of `text`, detected by code when the source does not know it | `und` when unknown. |
| `sensitivity` | `private` for other people's material; `unmarked` for the person's own notes | Raised by the person, never lowered silently. |
| `extensions.<adapter>` | anything the adapter keeps for itself | The core never reads it (P12). |

### 3.2 Changes to capture-event-v0

1. **`source.kind` names the content.** Today: `dictation`, `meeting`, `text`, `document`, `share`, `email`.
   Proposed: `text`, `image`, `document` (office formats), `pdf`, `email`. Readers keep accepting the old
   values (`dictation` and `meeting` read as `text`), so existing files stay valid.
2. **A new `obtained` object** (3.3).
3. **`text_from`** inside `obtained`: how the text was extracted (`entered`, `text-layer`, `ocr`, `parsed`).
   It lets a card say "read from a scan; check the numbers".
4. **The holos profile (§7) stays as a worked example**, with its note.

### 3.3 `obtained`: how the information came (P16)

| Field | Meaning | Who fills it |
|---|---|---|
| `channel` | `email`, `paper` (a paper document the person scanned or photographed), `download`, `message` (a chat or text message), `note` (the person wrote it), `other` | The source when it knows (a mail monitor knows `email`), else the person. |
| `from` | who it came from, as the person or the headers say ("the strata manager", an email sender) | Headers by code; the person's words otherwise. |
| `received` | the date it reached the person, when it differs from the capture date (a letter that arrived last week) | The person, or a header date. |
| `said` | the person's own words about it, kept verbatim ("came in the mail from the notary, scanned it today") | The person. |
| `text_from` | `entered`, `text-layer`, `ocr`, `parsed` | The adapter. |

When the source cannot tell and the person said nothing, `channel` is `other` and the card asks once, with
one tap per channel. The answer is kept on the capture and copied into the provenance of everything filed
from it (binder-v0 §5.8), so a binder can always say how it learned a fact.

## 4. Reading intake (P13)

The pipeline every file in a binder's `intake/` goes through, as soon as it holds still:

### 4.1 Deterministic steps (code)

1. **Sniff** the type from the bytes, never from the name. A mismatch (a PDF named `.jpg`) is noted.
2. **Copy the original** into Sprava's capture store with its SHA-256. The file stays in `intake/` until the
   person approves filing it.
3. **Extract all the text**: the PDF text layer, OCR (Vision, on device) for every page or image without one,
   the text of an office document, the headers and body of an email file. Attachments inside an email become
   their own captures, linked to the message.
4. **Facts by code**: dates and amounts (the grammar already used by the clerk), page count, sender and
   subject from headers, known senders matched against the binder's documents and items, reference numbers
   (invoice, account, file numbers) by pattern.
5. **Signals for classification**: words such as "invoice", "notice", "due", "please reply", "minutes",
   "bylaw", "amendment", "statement"; a question addressed to the person; a deadline in the text.

### 4.2 Classification by the local model

The local model answers one closed question, with code's facts in front of it: what is this?

| Class | Example | What the card proposes |
|---|---|---|
| Governing document | bylaws, a contract, a lease, a ruling, a policy | file it as a document; add any obligations and deadlines it creates as items |
| Action needed | an email that warrants a reply, an invoice to pay, a form to sign | file it; add the action as an item with its due date; mark `reply-owed` or `payment` |
| Information to keep | a statement, a receipt, minutes, a confirmation | file it; note what it updates (a balance, a status) |
| Not sure | anything else | file it as a document with the model's best reading shown |

Code checks the answer as it checks the clerk's today (capture-event-v0 §6.4): every quoted fact must occur
in the text, every date is resolved by code, amounts are parsed by code.

### 4.3 Understanding by the local model

Then the local model reads the document with the document variant of capture-event-v0 §6.4: title, date,
parties, amounts, deadlines, a one-sentence summary, and the binder's existing items it touches (the
duplicate check). Long documents are read in windows, as notes are; every window is read, because the file is
read in full.

### 4.4 Escalation to a smarter model

The local model is good at filing and poor at long reasoning. A smarter model (a connected brain, such as
Claude Code over MCP; architecture 7) follows up when one of these holds:

- the class is "not sure", or the local model's reading failed its code checks;
- the document is long or dense (above a page or word count to be set from fixtures);
- it is a governing document, whose obligations are worth a careful reading;
- it needs a reply drafted;
- the person asks ("look at this properly").

Today a brain proposes only when it is asked from its own side. Escalation therefore needs one new MCP
capability: a queue of documents waiting for a careful reading, which a connected brain can list, read within
its scope, and answer with proposals. Nothing leaves the Mac unless the person has connected a brain and put
the binder in its scope (architecture 7.5); otherwise the card says a careful reading is recommended.

### 4.5 Held for the person

A file is held, with a card that says why, instead of read, when:

- it is encrypted or password-protected, or will not parse;
- it is far outside the size or page limits;
- its type does not match its name in a way that looks deliberate;
- it is an executable, a script, an archive of many files, or a kind no adapter accepts;
- the reading contradicts itself badly enough that the checks drop most of it.

## 5. The type adapters (P14)

| Type | Accepts (sniffed by content) | How text is obtained | Kept | Read as |
|---|---|---|---|---|
| Text | plain text, Markdown, RTF; notes; a shared text or URL | as given; RTF flattened; tracking parameters removed from URLs | the text | notes (capture variant) |
| Image | JPEG, HEIC, PNG, TIFF; screenshots; photos of paper | Vision OCR; date taken; location stripped from a derived copy | original and the stripped copy | document variant when it holds text |
| Office document | DOCX, XLSX, PPTX, Pages, Numbers, Keynote, RTF, ODF | the document's own text, tables as rows; no macros run | the original | document variant |
| PDF | PDF | the text layer; Vision OCR for pages without one; every page | the original | document variant |
| Email | `.eml`, `.emlx`, `.msg` | headers and body by code; HTML bodies as text with no remote content; attachments as their own captures | the message file | notes for the body; documents for attachments |

## 6. Making a new type cheap

### 6.1 A descriptor per type

A type adapter is mostly data: `id` and `version`; `accepts` (content types and magic bytes, checked on the
bytes); `steps` from the step library; safety limits; the default `sensitivity`; the default
`obtained.channel` when the source implies one; and how it is read (notes or document variant).

### 6.2 A small step library

Each step is pure and runs inside the extraction helper:

`sniff` → `copy-original` → one or more of `text-layer`, `ocr`, `office-text`, `parse-email`,
`strip-location` → `normalize-text` → `detect-locale` → `facts` → `signals` → `emit`.

A type that combines existing steps is a descriptor and fixtures. A new step is parser code, reviewed as such.

### 6.3 A conformance kit

Every adapter ships invented fixtures and the expected event for each, minus ids and clocks, plus hostile
files: truncated, oversized, mislabelled, encrypted, nested archives, bidi characters in names, PDFs with
JavaScript, office files with macros, HTML email with remote images and tracking pixels. Expected results: a
card or a hold, never a crash of the runtime, never a network request, never executed content.

### 6.4 Outside programs (P15)

An outside program (a mail monitor, a scanner's software, a script) can feed Sprava in two ways:

- drop files into a binder's `intake/`, as such programs do today (importers, `docs/integrations.md`, are
  Sprava's own built-in way of doing this); Sprava reads them as any other file and
  takes `obtained.channel` from where they land: `intake/mail/`, the mail monitor's export target, implies
  `email`;
- write capture events, with files as media, into its own device folder under the capture root
  (capture-event-v0 §5), registered once by the person (architecture 8).

The trust rules stay as built: an unregistered folder's events are marked "unverified source", and only
Sprava's own notes, proven by the app's notices, can choose a binder by hint.

## 7. What already exists

- The contract reader, with type checks, quarantine, chains, retractions and sensitivity raises
  (`SpravaCore/Capture/CaptureEvents.swift`, `CaptureInbox.swift`).
- Text from the note field and `sprava note`, with code-built cards and the clerk's notes reading
  (`SpravaCore/Clerk`).
- The intake watcher of increment 5: it notices a file that holds still in `intake/` and builds a filing card
  that reads no text (`SpravaCore/Capture/Intake.swift`). P13 replaces the "reads no text" part; the watcher,
  the filing op with its digest check, and the folder choice stay.
- Producer registration and the app's notices (section 6.4).

Not built: the extraction helper, every extraction step, `obtained`, the classification and document
readings, escalation, and the sources other than notes and `intake/`.

## 8. A build order (increment 7 of the MVP)

1. **Contract:** `obtained` with `text_from`; the wider `source.kind`; an "how did this reach you?" answer on
   cards; provenance copied into filed items.
2. **The extraction helper** as its own sandboxed executable, with the step runner, safety limits and the
   conformance kit.
3. **PDFs and images:** text layer and Vision OCR, every page; intake files become captures that are read.
4. **Classification and the document reading** by the local model, with the code checks; holds.
5. **Office documents and email files.**
6. **Escalation:** the queue a connected brain can read and answer.

## 9. Questions for the author

1. Answered 2026-10-07. Each binder that consumes email runs its own mail monitor (`imap-extract`) from
   `scripts/` (the newer lifeproj layout), watching one mail label, and its export target is the binder's
   `intake/mail/`. So the intake watcher reads message files in `intake/mail/` as email
   (`obtained.channel: email`, filled without asking), and still never reads, files, indexes or shows a
   `.env` or `state.json` anywhere under `intake/` (binder-v0 §3.3). Sprava never runs the monitor and never
   reads its configuration. Still open: the exact shape of an exported message (see 4).
2. Each binder's agent watches its `intake/` today and processes what lands. Once Sprava reads intake, two
   readers would file the same file twice. Should the manual addendum tell agents to leave `intake/` to Sprava
   and work from Sprava's cards (and the escalation queue) instead?
3. A note the person enters gets `obtained.channel: note`. When the note relays something ("the manager
   called: the plumber comes Thursday"), should the card ask for the channel too (`message`, a call), or is
   `note` enough there?
4. Answered 2026-10-07: `imap-extract` writes `<date>_<uid>_<slug>.md` (YAML front matter with subject,
   from, date and to; the body converted from HTML) and, when there are attachments, a sibling folder
   `<same name> attachments/`. It writes in place, so a message and its folder are read as one capture once
   both have held still. It keeps neither the original `.eml` nor the Message-ID; the built-in IMAP importer
   of `docs/integrations.md` keeps both.
