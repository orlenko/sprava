# The adaptation layer

Status: draft for the author, 2026-10-07. It works out decisions.md P12: Sprava is input-agnostic. It
receives text, and it will receive documents, images and videos through an adaptation layer that quickly
establishes the ingestion protocol for each type of input. Nothing here is built yet, except the pieces
section 6 lists as already in place.

## 1. What the layer is for

Sprava's core does one thing with new material: it reads it, proposes changes to binders, and waits for the
person. The core should never know where the material came from or how it was made. A note typed on the
keyboard, a note dictated with any tool, a PDF from a bank, a photo of a letter, a screen recording: by the
time the core sees any of them, each is the same kind of object.

The adaptation layer sits between the world and that object. It has two jobs:

- turn each type of input into the one inbound contract the core reads (section 3);
- make a new type cheap to add: a short descriptor, one extraction step if a new one is needed, and fixtures
  (section 5).

Three things are out of scope for the layer, and stay out:

- How a person produces text. Dictation, accessibility features, a keyboard, a commercial tool: all of it
  happens before Sprava and is invisible to it (P12).
- Choosing a binder or writing to one. Adapters produce text and facts; the clerk and the review queue decide
  (architecture 5, 6). An adapter that could file things would bypass the person.
- Any one producer. No adapter is privileged and none is required. Removing any adapter leaves Sprava working.

## 2. Principles

1. **One contract.** Everything enters as a capture event (capture-event-v0 §3): text, optional media, a few
   facts. The core reads nothing else, and it never reads an adapter's private `extensions`.
2. **Two kinds of adapter, one contract.**
   - *Type adapters* turn a kind of content into text and facts: plain text, document, image, audio, video.
     They are built into Sprava.
   - *Sources* are where material arrives: Sprava's note field, drag and drop, the share sheet, a binder's
     `intake/` folder, and any outside program that writes capture events into the capture folder. A source
     hands bytes to a type adapter, or, for an outside program, writes the event itself.
3. **Untrusted input, parsed apart.** Documents come from other people. Every parser runs in the sandboxed
   extraction helper of architecture 2.1: no network, no Keychain, one file at a time, a size and time cap, a
   crash that kills only the helper. Nothing in a file is ever executed (no PDF JavaScript, no macros, no
   embedded links followed).
4. **Code first, model second.** An adapter gets text by code: a text layer, on-device OCR (Vision), on-device
   speech recognition, file metadata. The clerk reads the result afterwards. A type adapter never calls the
   language model, so every capture gets a code-built card within the minute even when the model is off
   (architecture 5.2).
5. **Originals are kept, unchanged.** The original file is copied beside the event as media with its SHA-256
   (capture-event-v0 §3.5), and the extracted text points back to it. An adapter never edits, re-encodes or
   "cleans" the original. Stripping location data from a photo produces a separate derived copy.
6. **Private by default for other people's material.** Documents, images, audio and video default to
   `sensitivity: private` (capture-event-v0 §3.3, §9); text the person entered defaults to `unmarked`.
7. **Deterministic and testable.** The same file and the same adapter version give the same event, apart from
   ids and clocks. Each adapter ships with fixtures and expected events (section 5.3).

## 3. The contract

The contract is capture-event-v0 as it stands, read with three clarifications that P12 makes necessary.

### 3.1 What an adapter fills in

| Field | Filled by the adapter | Notes |
|---|---|---|
| `source.app` | the adapter's id, such as `sprava.note`, `sprava.pdf`, or an outside program's name | Registered per device folder (architecture 8). |
| `source.kind` | the content type: `text`, `document`, `image`, `audio`, `video`, `email` | See 3.2. |
| `source.ref`, `source.revision` | an id for the underlying thing, and a version key | For a file: its SHA-256 is the revision. |
| `text` | the extracted text, normalized (NFC; control and bidi characters removed; length capped) | Empty only for a retraction. |
| `title` | the file name, or the first line for text | Optional. |
| `media[]` | the original, and any derived copies, with `sha256`, `bytes`, `mime`, `seconds` | capture-event-v0 §3.5. |
| `captured_at`, `ended_at` | when the material arrived, and when entering it ended | `ended_at` starts the one-minute measure. |
| `locale` | the language of `text`, detected by code when the source does not know it | `und` when unknown. |
| `sensitivity` | `private` for documents, images, audio and video; `unmarked` for entered text | The person can raise it, never lower it silently. |
| `extensions.<adapter>` | whatever the adapter wants to keep for itself | The core never reads it (P12). |

### 3.2 Three changes P12 asks of capture-event-v0

1. **`source.kind` names the content, not the way it was made.** Today the enum mixes the two:
   `dictation`, `meeting`, `text`, `document`, `share`, `email`. Proposed: `text`, `document`, `image`,
   `audio`, `video`, `email`. Readers keep accepting `dictation` and `meeting` as `text`, and `share` as
   whatever it carries, so existing files stay valid.
2. **One optional fact about how the text was obtained**, for the clerk's confidence and for the card:
   `text_from`: `entered`, `text-layer`, `ocr`, `speech`, `caption`. It says nothing about the tool. A card
   built from OCR can say "read from a scan; check the numbers", which is useful; whether the person
   dictated or typed is not recorded.
3. **The holos profile becomes an example.** capture-event-v0 §7 stays as one worked mapping for an outside
   producer, with the note already added. Nothing in the core or the plan refers to it.

## 4. The type adapters

Each row is one ingestion protocol. "Tier 0 card" is what the person sees within the minute with no model.

| Type | Accepts (sniffed by content, not by extension) | How text is obtained (code) | What is kept | Clerk reads it as | Tier 0 card |
|---|---|---|---|---|---|
| Text | `text/plain`, Markdown, RTF; the note field; a shared text or URL | as given; RTF flattened; tracking parameters removed from URLs (capture-event-v0 §8.3) | the text | capture variant (items) | one item per line, binder "not sure" (built) |
| Document | PDF; later DOCX, Pages, HTML | the PDF text layer; pages with no text layer go through Vision OCR, first N pages; DOCX and HTML by their text | the original file; page count | document variant: title, date, parties, amounts, deadlines (capture-event-v0 §6.4) | "File this document": name, date, size, digest, first lines |
| Image | JPEG, HEIC, PNG; screenshots | Vision OCR; image metadata (date taken); no faces, no location | the original; a copy without location data | document variant when it holds text, else no reading | "File this image", with the OCR text if any |
| Audio | M4A, MP3, WAV (a voice memo, a recorded call) | on-device speech recognition (SpeechAnalyzer), capped by duration | the original; duration | capture variant, read in windows | "File this recording", first lines of the transcript |
| Video | MOV, MP4 (a screen recording, a clip) | the audio track as for audio; optionally OCR of a few key frames | the original; duration | capture variant on the transcript | "File this video", duration and first lines |
| Email | `.eml`, later an inbox | headers parsed by code; body as text; attachments become their own captures linked to it | the message file | capture variant; attachments as documents | one card for the message, one per attachment |

Limits apply to every type and are part of each descriptor: a byte cap, a page or duration cap, a time
budget in the helper, and a text cap. Material over a limit is still kept and carded; only the extraction
stops, and the card says what was not read.

## 5. Making a new type cheap

### 5.1 A descriptor per type

A type adapter is mostly data. A descriptor names:

- `id` and `version`;
- `accepts`: content types (UTIs and MIME types) and magic bytes, checked on the bytes, never on the name;
- `steps`: an ordered list from the step library (5.2);
- `limits`: bytes, pages or seconds, time, text length;
- `sensitivity` default and `clerk_variant` (capture or document);
- `card`: which facts the Tier 0 card shows.

### 5.2 A small step library

Most types reuse the same few steps, each pure and run inside the extraction helper:

`sniff` → `copy-original` (with SHA-256) → one or more of `text-layer`, `ocr-pages`, `ocr-image`,
`speech-to-text`, `parse-headers`, `strip-location` → `normalize-text` → `detect-locale` → `facts`
(dates, page count, duration) → `emit`.

Adding a type that only combines existing steps is a descriptor and fixtures. Adding a step is code in the
helper, reviewed as parser code.

### 5.3 A conformance kit

Every adapter ships invented fixtures: input files and the expected event for each, minus ids and clocks.
The kit also feeds hostile files to every adapter: truncated, oversized, mislabelled (a PDF named `.jpg`),
nested archives, bidi controls in names, PDFs with JavaScript, images with location data. Expected results:
a card or a quarantine, never a crash of the runtime, never a network request, never an executed script.

### 5.4 Outside programs

A program outside Sprava (a phone inbox later, another person's tool, a script) does not need a type adapter.
It writes capture events into its own device folder under the capture root (capture-event-v0 §5), and the
person registers that folder once (architecture 8). The same trust rules apply as today: a registered
folder's events are read as that program's; an unregistered folder's events are marked "unverified source";
only Sprava's own folder, backed by the app's notices, can choose a binder by hint.

## 6. What already exists

- The contract reader, with type checks, quarantine, chains, retractions and sensitivity raises:
  `SpravaCore/Capture/CaptureEvents.swift`, `CaptureInbox.swift`.
- The text type, from the note field (`CaptureProducer`) and `sprava note`, with Tier 0 cards and the clerk's
  capture variant (`SpravaCore/Clerk`).
- A first document source: files in a binder's `intake/` become code-built filing cards that read no text
  (`SpravaCore/Capture/Intake.swift`). Under this design they would become document captures, so their text
  reaches the clerk.
- Producer registration and the app's notices, which section 5.4 relies on.

Not built: the extraction helper, every step but text normalization, the clerk's document variant, the share
sheet, drag and drop, and the email type.

## 7. A build order

1. **Contract cleanup.** Rename "producer" to "adapter" in the docs and code; make `extensions` opaque to the
   core by a test; add `text_from`; widen `source.kind` as 3.2 proposes.
2. **The extraction helper** as its own sandboxed executable, with the step runner, the limits and the
   conformance kit, starting with `sniff`, `copy-original`, `normalize-text`, `detect-locale`.
3. **Documents:** PDFs with a text layer, then Vision OCR for scanned pages; `intake/` and drag and drop as
   sources; the clerk's document variant (capture-event-v0 §6.4) and its binder call.
4. **Images:** OCR and location stripping; the share sheet as a source.
5. **Audio:** on-device speech for recordings that arrive as files.
6. **Video and email**, when needed.

Steps 1 to 3 cover the documents that real binders receive most. Each later step is a descriptor, perhaps a
step, and fixtures.

## 8. Open questions

1. Should files in `intake/` become document captures that the clerk reads, or stay as filing cards that read
   no text, with drag and drop as the only path to the clerk? The first gives better cards; the second keeps
   other people's documents away from the model until the person asks.
2. OCR and speech limits: how many pages and how many minutes before a capture is "kept but not read"?
3. Audio and video are heavy. Are they needed before the 30-day trial, or after?
4. Should outside programs be able to send documents (media in their events), or only text?
5. Is `text_from` worth recording at all, given P12? This draft keeps it for the card's honesty about OCR,
   and never records the tool.
