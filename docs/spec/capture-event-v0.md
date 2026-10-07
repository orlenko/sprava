# Capture event format, version 0

Status: v0 draft of 2026-10-06, revised twice the same day after design-skeptic passes that checked it
against the holos source, the transport rules, privacy and real runs of the on-device model. Written
for the author to review, from the holos source at commit ccbc4de and from `docs/decisions.md`. No
real holos file was inspected, because holos has never run on the Mac this was drafted on; every holos
shape below comes from the Swift types and the holos design docs. Every example is invented. This
draft follows decisions C1 to C4, P5, P7 and F1 and cites them in the form "(decisions.md C1)". Where a
skeptic finding pulled against a recorded decision, the decision stands and the concern is listed in
section 12.

Licence note: the prose of this specification is meant to be CC-BY-4.0 and the JSON Schemas, samples
and conformance checks Apache-2.0 (decisions.md L2). No rights in the names "Sprava" or "teka" are
granted by this document.

## 1. Scope and status

A capture is anything a person records in the moment: a dictated note, a recorded meeting, a typed
line, a document dropped on the app, an item shared from another app, a forwarded email. Sprava's job
is to turn captures into filed, typed changes to a binder (a teka, one folder per life episode). This
document defines the file that carries a capture from the app that made it to the app that files it.

The file is open and versioned for four reasons.

1. holos, the author's dictation and meeting app, keeps working on its own. Sprava never links holos
   code and never treats holos's private file layout as its contract (decisions.md P6). The boundary
   stays even if both apps end up under GPL-3.0, because they ship on their own cycles and a phone app
   or an email intake can speak the same format (decisions.md L3).
2. Reading holos's own files from the outside is fragile: its dictation log has no cursor and is
   rewritten in place, its retention sweep deletes records and audio after 7 or 30 days, a sandboxed
   reader would need a folder grant, and Apple announced tighter Full Disk Access controls on
   2026-10-02. So holos is the producer: it writes one immutable file per finished dictation and per
   saved meeting into a folder the user chooses (decisions.md P7).
3. The format is append-only. Files are written once and never changed, so a second device can add its
   own files to the same folder without conflicts. That is why a phone inbox can ship before any real
   sync exists (decisions.md C2).
4. Every fact Sprava later files can point back to the capture it came from, and to the model run that
   read it. Provenance needs stable, immutable inputs (decisions.md F1, F3).

holos is the first producer and the one checked here against the code (section 7). Other producers
(Sprava's own text box, document drop, share sheet, email forward, a phone inbox) differ only in the
ways section 8 lists.

Out of scope here: the binder format (`docs/spec/teka-v0.md`, a sibling draft), the op vocabulary
that proposals use, the runtime that watches the folder (`docs/architecture.md`), and the review
queue's screens.

## 2. Terms

- Capture: something a person recorded in the moment, in any form.
- Capture event: one JSON file describing one capture, written once and never changed.
- Producer: the app that writes capture events. holos is the first one.
- Consumer: the app that reads capture events and files them. Sprava is the first one.
- Capture folder (or capture root): the folder the producer writes into and the consumer watches.
- Derived event: a JSON file describing something computed from captures: the clerk's reading of a
  capture, a summary, a proposal, or the record of a filing.
- Interpretation: the clerk's typed reading of one capture, which is the content of one derived event.
- Clerk: Sprava's Tier-1 helper, an on-device model that works on one capture at a time
  (decisions.md P5).
- Brain: an optional Tier-2 agent connected over MCP. It never writes capture events.
- MCP, Model Context Protocol: the protocol a brain uses to talk to Sprava (decisions.md A4).
- Binder, teka: one folder per life episode, the thing captures get filed into.
- UUID: a 128-bit identifier written as 36 characters, such as `01a11262-6445-7d4e-8a1b-2c3d4e5f6a7b`.
  Version 7 UUIDs start with the time they were made, so they sort by time.
- HLC, hybrid logical clock: a timestamp that stays close to the wall clock. A producer's stamps never
  run backwards, and an effect is stamped after a cause it has seen. Section 4 defines it.
- SHA-256: a digest of a file's bytes, written as 64 hex characters. Two files with the same digest
  have the same content.
- Atomic write: writing a file so that a reader on the same disk sees either nothing or the whole file,
  never a half.
- Cursor: a consumer's private record of which events it has already read.
- Supersede: a later event replaces an earlier one because the source changed. Both files stay.
- Retraction: a superseding event that says the person deleted the thing in the producer.
- Chain: all the events with the same `source.app` and `source.ref`, whatever device wrote them
  (section 3.2).

## 3. The capture event envelope

The envelope is the fixed set of fields every capture event carries (decisions.md C1). The schema in
section 10 is the authority; this table explains it.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `format` | the string `sprava-capture-event` | yes | Tells a reader what the file is. |
| `format_version` | the string `0` | yes | The version of this format (see "Versions" below). |
| `id` | UUID, lowercase | yes | The event's own identity. Version 7 recommended (section 4.1). Never reused. |
| `hlc` | object `{wall_ms, counter, node}` | yes | The producer's hybrid logical clock stamp when it wrote the file (section 4.2). |
| `device` | object `{id, name?}` | yes | The producer installation that wrote the file. `id` is a UUID made once and kept; it names the folder the producer writes into (section 4.4). `name` is a display name the person chose. |
| `source` | object `{app, kind, ref, revision, version?, processing?}` | yes | Who produced the capture and what it is. `app` is a lowercase producer name such as `holos`. `kind` is one of `dictation`, `meeting`, `text`, `document`, `share`, `email`. `ref` is the producer's own identifier for the thing, verbatim. A producer that has no identifier of its own (a typed note, a dropped file) mints a UUID when the capture is made and stores it with the draft, so a retry after a crash reuses it. `revision` is the producer's version key for it at the time of writing, compared only for equality; for a capture that is never edited, the SHA-256 of `text` is enough. `processing` says where speech or images were turned into text: `on-device` (the default) or `network` (section 9). |
| `captured_at` | ISO 8601 with numeric offset | yes | When the capture started, by the producer's clock, with the UTC offset in force at that instant (section 4.3). |
| `captured_at_estimated` | boolean | no | `true` when `captured_at` is not when the content was recorded, for example the time a recording was imported. Relative dates are then left unresolved (section 6.6). |
| `ended_at` | ISO 8601 with numeric offset | no | When the capture ended, by the producer's clock (section 4.3). Lets a consumer time its work from the end of a capture without reading producer extensions. |
| `locale` | BCP 47 tag | yes | The language of `text`, such as `en-CA` or `fr-CA`, with hyphens and no `@` keywords. `und` when unknown. |
| `title` | string | no | A name the producer already had: the meeting's name, the file name, the email subject. |
| `text` | string | yes | The capture as readable text. Rules per kind below. |
| `alt_text` | string | no | What was heard or seen before any fixes, when it differs from `text`. |
| `media` | array of `{kind, sha256, path?, of?, bytes?, seconds?, mime?}` | no | Files that belong to the event (section 3.5). |
| `people_hints` | array of `{name?, external_id?, kind?, confirmed?}` | no | People the producer already knows are involved. `kind` is `speaker`, `self` or `mention`. `confirmed: false` marks a guess. |
| `app_context` | object `{app?, terminal?}` | no | Where the person was: the display name of the app the capture was made for or taken from. Never a bundle identifier (a reverse-DNS name such as `com.example.app`). The consumer keeps it in its capture store only (section 9). |
| `sensitivity` | `unmarked` or `private` | yes | Section 3.3. |
| `binder_hint` | string | no | The binder the producer believes this belongs to, when the person said so. A hint only; it files nothing. |
| `supersedes` | UUID | no | The id of an earlier event this one replaces (section 3.2). |
| `retracted` | boolean | no | `true` when the person deleted the thing in the producer (section 3.2). |
| `extensions` | object of objects, keyed by producer name | no | Producer-specific data, such as `extensions.holos`. A reader ignores keys it does not know. |

Versions. Two schemas describe each file. The producer schema is strict: it allows no key it does not
define, so a typo in a core field is caught when a producer is tested. The reader schema is the same
schema with every `additionalProperties: false` removed, so a reader ignores fields added later. The
reader schema also opens the closed lists that have a safe fallback, and a reader maps an unknown value
to that fallback (holos's own readers do the same: an unknown code compares unequal instead of failing):

| Field | An unknown value is read as |
|---|---|
| `source.kind` | `text` |
| `source.processing` | `network` |
| `media[].kind` | `file` |
| `people_hints[].kind` | `mention` |
| `sensitivity` (capture and derived events) | `private` |
| derived `outcome` | `error` |

New optional fields, new keys inside `extensions`, and new values in the lists above keep
`format_version` at `0`. A change that a reader must understand to stay correct (a new required field,
a new value in any other closed list, a changed meaning) moves to the next `format_version`. A producer
writes the lowest `format_version` that carries its data, so an older consumer keeps reading it. A
reader that meets a `format_version` it does not know defers the file: it keeps it, shows it on the
health page, and reads it again after the reader is upgraded.

JSON conventions: UTF-8 without escaping of non-ASCII characters, two-space indent, a trailing
newline (decisions.md F10). Key order is free, because the file is never rewritten; a reader must not
depend on it.

### 3.1 What `text` holds, per kind

- `dictation`: the whole dictation as the producer recorded it, after its own fixes. For holos this is
  the record's `text` verbatim, which already holds the whole dictation when only part of it reached
  the target app (section 7.1).
- `meeting`: the labelled transcript as plain text, one paragraph per turn, in time order, with pause
  and marker lines. Section 7.5 gives the rendering.
- `text`: the text the person typed.
- `document`: the document's text layer when it has one, else the recognized (OCR) text. May be empty
  when nothing could be extracted; the media entry still carries the file.
- `share`: the shared text or URL, followed by any text the person added.
- `email`: the message body as plain text.
- Any kind, when `retracted` is `true`: the empty string.

### 3.2 Immutability and the supersedes rule

A capture event is written once and never modified or deleted by its producer. A consumer may read it
any number of times and always sees the same bytes.

When the underlying thing changes after the event was written (holos's Update History edits a
dictation; a meeting is relabelled, renamed or summarized again), the producer writes a new event with
a new `id`, the same `source.ref`, the new `source.revision`, and `supersedes` set to the id of the
latest event it wrote for that `ref`. It writes one only when `source.revision`, `title`, the people
hints' names or `sensitivity` changed, or the thing was deleted, so a regeneration that changes
nothing writes nothing. A superseding event copies `captured_at` from the first event of its chain.
`supersedes` only ever names an event the same device wrote.

Chains. A chain is every event with the same (`source.app`, `source.ref`), whatever device wrote it.
Membership comes from that pair. `supersedes` is advisory: it tells the consumer which event the
producer meant to replace, and the health page uses it, but a missing or wrong link never splits a
chain.

The current event of a chain. Files can arrive out of order, and a crash can make a producer write the
same change twice, so a consumer never assumes a chain is a tidy line. The current event for
(`source.app`, `source.ref`) is, among the events the consumer has, the one with the highest HLC that
no other known event supersedes. On a tie the larger id wins. Two exceptions:

- Once any event of a chain has a revision that does not start with `approx:`, events whose revision
  starts with `approx:` (the developer importer's, section 7.8) are ignored when choosing the current
  event of that chain. A producer's own event always outranks an approximation.
- A retraction stays current until an event with a higher HLC arrives (a restore, below).

A `supersedes` that names an event the consumer does not have yet, or two events that supersede the
same one, are tolerated and shown on the health page as warnings.

What changes are worth reading again:

- Two events with the same `source.app`, `source.ref` and `source.revision` are the same capture,
  whatever device wrote them. A consumer that has read one ignores the other, except for `title`,
  people hints' names, and a raise of `sensitivity` from `unmarked` to `private`, which it applies.
- A superseding event whose `text` is byte for byte the same as the event it replaces changes the same
  three things and nothing else. No new interpretation is made.
- Any other event that becomes the current event of a chain with filed or queued items is a change to
  review, whether or not it carries `supersedes`. A consumer that already filed items from the old
  event keeps their provenance pointing at the old id (which still exists) and builds a change proposal
  by code (section 6.5). It never files the new event as new content beside the old items.

Applying a raise of sensitivity. When a chain becomes `private`, the consumer marks its stored copies
of the capture and of the chain's derived events private at once, before any approval. When the chain
has filed items, it also builds a change proposal that sets `redact: true` and a teka `kind` on each of
them (section 3.3). The card says that titles already published to the hub or its Google Tasks mirror
may persist there until the next publish.

Retraction. When the person deletes the thing in the producer (holos's Delete, Clear History, Delete
Meeting, or the same from holos's command line), the producer writes a retraction: a superseding event
with `retracted: true`, the same `source.ref`, `source.revision` set to `retracted`, empty `text`, and
no `title`, `alt_text`, media, people
hints, `app_context`, `binder_hint` or `extensions`. A producer never reuses its normal mapping for a
retraction, because that mapping copies content into `extensions`. The consumer then:

- withdraws any proposal built from the chain that is still waiting in the queue, and drops the chain's
  derived events from the queue;
- forgets the content it holds, whether or not anything was filed: it deletes its own copies of the
  chain's events and media in the app's capture store and in each binder's `captures/` folder, and
  replaces the content of its own derived events for the chain with a tombstone that keeps only the
  id, `inputs`, `outcome` and the word "retracted". That is a named exception to immutability, and it
  applies only to files the consumer itself owns;
- for items already filed, shows a review card that offers to remove what was filed (`drop` ops), and
  keeps provenance as the old id marked "retracted";
- lists on that card, in plain words, what still remains: the event files in the capture folder until
  cleanup (section 12, question 4), the titles in each binder's op log, which is the binder's history
  (decisions.md F1), and backups until they are pruned;
- never treats a retraction as new content.

Restore. A thing the person restores after deleting it (a meeting put back from the Trash with the same
id) gets a new event with a higher HLC that supersedes the retraction. The consumer treats it as new
content to review, because its earlier items may already have been dropped.

A producer's own automatic cleanup (holos's retention sweep) is not a retraction by default, because
the capture was already handed over and the person chose to keep it in Sprava. A producer may offer a
setting that turns sweeps into retractions too.

### 3.3 Sensitivity

`sensitivity` has two values in v0. `unmarked` means nothing was decided. `private` means:

- every item or document filed from the capture gets `redact: true` and a teka `kind` by default
  (decisions.md F3), so the cross-binder view shows at most that kind, as a binder's `disclosure`
  already allows for redacted items (decisions.md F6). The person may change that on the review card,
  and the filing event records the change;
- a filed copy of the capture (section 9) is recorded as a document with `redact: true`. Its text,
  quotes and titles are never returned over MCP, by `read_document`, `search`, resources or proposals
  listed over MCP, unless the person allowed that for the binder it is filed into (decisions.md A4,
  A7);
- every derived event computed from it is `private` too (section 6.1).

Two things are kept apart. The event's `sensitivity` never goes down: a later event of the same chain
may raise it, and nothing lowers it, because the event does not change. The redaction of a filed item
is the person's choice on the card, and the binder's op log records it.

Defaults per kind are in section 9: `private` for meetings, documents, email and any share that carries
a file, `unmarked` for the rest. A producer may also set `private` when the person asks (a toggle on
the capture). Section 3.2 says what a consumer does when a later event raises it.

### 3.4 People hints

A people hint is a name plus an opaque id. The name is whatever the producer shows the person: a full
name from the producer's own people list, or a role such as "the notary". The id lives in the
producer's own namespace and is prefixed with the producer's name, for example
`holos:profile:C3D4E5F6-A7B8-4C9D-8E1F-2A3B4C5D6E7F`. The consumer uses it only to recognize the same
person again across captures from the same producer. A hint for the person capturing (`kind: self`)
may have no name. A hint whose name is a guess, such as an automatic voice match, carries
`confirmed: false`, and the review card shows it as a guess. Voiceprints and voice embeddings never
travel (section 9).

### 3.5 Media

Media entries list files that belong to the capture and that the consumer can actually read. There are
two forms.

- Copied: the file lives beside the event, named `<event-id>.<slot>.<extension>` (for example
  `01a11262-6445-7d4e-8a1b-2c3d4e5f6a7b.audio.m4a`). The `<event-id>` is the event's own id. The slot
  is `audio` for a dictation's audio, `image-<n>` and `file-<n>` for images and other files, numbered
  from 1, and `<track>-<n>` for meeting audio (`mic-1`, `system-1`). In a synced root a producer uses the
  neutral slot `m<n>` instead (section 5.1). The entry carries `path`, `bytes` and `sha256`, plus `mime`
  and, for audio and video, `seconds`. A `path` never ends in `.json` or `.tmp`.
- Reused: a superseding event that keeps the same file points at it instead of copying it again. The
  entry carries `of` (the id of the earlier event in the same chain whose copied entry holds the file)
  and the same `sha256`.

A file the producer did not copy is not a media entry. A producer may describe it under its own
`extensions` (holos lists meeting audio chunks there, section 7.2), but in v0 such a description only
records that the file existed. There is no way to ask the producer for it later, and the producer may
delete it at any time. The consumer has the audio only when copying was on.

## 4. Identifiers and time

### 4.1 The id

Every event gets a fresh UUID. Version 7 (RFC 9562) is recommended: its first 48 bits are the
millisecond timestamp of creation, so ids sort by time, a folder listing sorted by name is roughly
chronological, and two devices never collide without talking to each other. Version 4 is accepted.
Ids are lowercase. An id is never reused, not even after the file is gone. Apple's `UUID()` makes
version 4; a producer needs a small version-7 generator (timestamp, 12 random bits, the version and
variant bits, 62 random bits). Nothing in this format depends on ids sorting by time. A producer that
writes into a synced root uses version 4 ids there, because a version 7 id puts the capture's creation
time in a file name the sync provider can see (section 5.1).

### 4.2 The hybrid logical clock

Wall clocks on different devices disagree, jump when set, and can give two events the same reading. A
pure counter orders events but loses the human sense of time. A hybrid logical clock (Kulkarni,
Demirbas, Madeppa, Avva and Leone, 2014) keeps both: a logical time `l` that tracks the wall clock, and
a counter `c` that breaks ties. When a clock merges the stamps it receives, an effect is stamped after
its cause, and `l` stays within the clock skew of the wall clock. The counter stays small in practice.

The rules, in plain words. Each clock keeps `l` and `c`, both starting at zero.

- Making a new event: read the wall clock `pt` in milliseconds from the system clock at the moment of
  writing. If `pt` is later than `l`, set `l` to `pt` and `c` to 0. Otherwise keep `l` and add 1 to
  `c`. Stamp the event with `(l, c)`.
- Receiving an event stamped `(lm, cm)` from another clock (a consumer merging two devices' folders):
  set the new `l` to the largest of the old `l`, `lm` and `pt`. Then: if the new `l` equals both the
  old `l` and `lm`, set `c` to the larger of `c` and `cm`, plus 1; if it equals only the old `l`, add 1
  to `c`; if it equals only `lm`, set `c` to `cm` plus 1; otherwise set `c` to 0.
- Comparing two stamps: compare `l` first, then `c`, then the node id. Earlier sorts first.
- Persisting: a producer stores its `(l, c)`, and it stores the new value, flushed with
  `F_FULLFSYNC` (section 5.2), before it renames the event into place, so a crash never reuses a stamp.
  At launch it restores them and then sets `l` to at least the highest `hlc.wall_ms` found among the
  events in its own device folder, so neither a restart nor a state file rolled back by a power loss
  makes the clock run backwards. When one producer writes from several processes (holos does, section
  7.7), the stored state is shared by all of them and updated under one file lock, read, increment and
  write together.

Every producer stamps with its millisecond wall clock, whatever precision its stored dates have (holos
stores dates as whole seconds, but its clock reads milliseconds). A producer that truly has no
sub-second clock uses `seconds × 1000` as `pt`, and the counter tells its events apart.

Encoding. In the file the stamp is an object: `wall_ms` is `l` as milliseconds since
1970-01-01T00:00:00Z, `counter` is `c` (0 to 65535), `node` is the clock's identity, which is the
device id with hyphens removed (32 lowercase hex characters). The string form, used for sorting and
display, is fixed width and sorts correctly as plain text:

```
<wall_ms as 13 decimal digits, zero-padded>-<counter as 4 lowercase hex digits>-<node as 32 hex>
1791309800517-0000-4c1f2a9e5b7d4e039a612f8c0d7b1e55
```

The schema requires `wall_ms` of at least 10^12 (September 2001), so it always has 13 digits, which
last until the year 2286. Four hex digits hold the counter's full range. The whole string is 51
characters. This is the encoding local-first systems commonly use (wall milliseconds, counter, node
id, compared as strings). The paper's own compact form, 48 bits of NTP time and a 16-bit counter in
one 64-bit word, is analogous, with a different epoch and unit.

Drift. A producer never moves its clock backwards. If its `l` is more than 60 seconds ahead of the wall
clock (the clock was set back), it keeps `l`, keeps incrementing `c` for each event, and records the
skew on its health page; it checks this at launch and again each time it stamps an event. Its stamps
catch up with the wall clock once the wall clock passes `l`. The paper's reset (`l` set to the wall clock, `c` to 0) is used only on a consumer's
receive path. A consumer that reads an event whose `wall_ms` is more than 60 seconds ahead of its own
wall clock keeps the event (nothing is ever dropped), does not let that stamp push its own clock past
its wall clock plus 60 seconds, and flags the event as clock skew. A counter that would pass 65535
makes the producer set `l` to `l` plus 1 millisecond and `c` to 0. It never waits: a clock once set
years ahead would otherwise stop the producer from writing captures. Stamps stay increasing, which is
all CE-17 needs, since the order within a chain comes from links.

What the HLC is for: a stable display order and tie-break between events that no link connects, across
several devices. It is not a dedupe key: a replayed file is recognized by its id, and a re-emitted
capture by its (`source.app`, `source.ref`, `source.revision`) (section 5.4). Causal order between
events always comes from the links:
`supersedes` for a chain, `inputs` for derived events. The HLC is not for showing people when
something happened; `captured_at` is. A consumer never decides what to ingest from the order of
stamps or file names (section 5.3).

### 4.3 `captured_at`

`captured_at` is when the capture started, by the producer's clock, written as ISO 8601 with a numeric
UTC offset, for example `2026-10-06T14:03:05+02:00`. The offset is the one in force at that instant in
the producer's time zone (in Swift, `TimeZone.current.secondsFromGMT(for: date)`), never the offset at
the time of writing, which differs across a daylight-saving change. It is required (write `+00:00`
rather than `Z`, and never `-00:00`) so that a consumer can show the local time of day and resolve
"Thursday" correctly even when the file is read on another device or months later. Precision is
whatever the producer has: holos gives whole seconds. Milliseconds are allowed. A superseding event
copies `captured_at` from the first event of its chain. When the producer does not know when the
content was recorded, it writes the best time it has and sets `captured_at_estimated: true`.

`ended_at` is optional and is when the capture ended, in the same form: for a dictation, `captured_at`
plus its length, rounded down to the producer's precision; for typed text, when the person saved it.
A consumer that times its own work, such as the one-minute measure of the MVP, counts from `ended_at`
when present. A value earlier than `captured_at` is read as absent. A superseding event copies
`ended_at` from the first event of its chain, as it does `captured_at`.

### 4.4 Device ids

A device id is a UUID a producer makes once, the first time it writes, and keeps for the life of its
installation. It is created with an exclusive create, so two processes starting together cannot make
two. It names the folder the producer writes into (section 5) and, without hyphens, it is the HLC
node. Two producers on the same Mac (holos and Sprava) have two device ids, because they are two
clocks and two writers.

Clones. Migration Assistant or a phone restore can copy a device id to a second machine. A producer
therefore stores its device id together with a fingerprint of the installation (for example the
volume's UUID and the path of its support folder) and makes a new device id when the fingerprint
changes. Old events keep the old id.

`device.name` is for people. It must not default to the system's computer or device name, or to the
account name, because those usually hold the owner's name. The producer leaves it out or offers a
generic suggestion such as "Office Mac" that the person can change.

## 5. Transport

Transport is a folder (decisions.md C2). There is no socket, no notification and no daemon on the
producer's side, which matches how holos already talks to its own parts (files, flock probes, atomic
publishes).

### 5.1 Layout

```
<capture-root>/
  <device-id>/
    <event-id>.json                  one capture or derived event
    <event-id>.audio.m4a             media beside its event, named after it
    .<event-id>.json.tmp             an in-flight write; readers ignore dot-prefixed names
    .<event-id>.audio.m4a.tmp        an in-flight media write
```

The capture root is a folder the user chooses once in the producer's settings and once in the
consumer's. Each producer writes only inside its own `<device-id>/` folder, which it creates with
permission 0700; the files it creates are 0600. The consumer never writes inside any device folder.

Local and synced roots. By default a capture root is on the Mac's own disk, and Sprava's own producers
(section 8) write only into a local root. A root that a sync service carries off the Mac (for a phone
inbox) is opt-in, is listed in the inventory of what leaves the Mac (decisions.md A7), and holds only
files encrypted one by one to the Mac's age recipient (decisions.md A6): `<event-id>.json.age` and
`<event-id>.<slot>.<ext>.age`. The consumer decrypts each file before any check in 5.3, and every
check applies to the decrypted bytes. The exact framing is an open question (section 12). A consumer
may watch more than one root.

Encryption hides contents, not names, sizes or times. In a synced root the sync provider still sees the
device folder names, the file names, each file's size, and when each file appeared. A version 7 id
would add the capture time to the millisecond, and a slot named `audio` would say that audio exists and,
by its size, how long it is. So a producer writing to a synced root uses version 4 ids (4.1) and the
neutral slot `m<n>` (3.5). What remains visible (how many captures, how large, when they arrived) is
listed in the inventory of what leaves the Mac.

### 5.2 Writing an event

1. Copy or write every media file first, each to `.<event-id>.<slot>.<ext>.tmp` in the device folder,
   flush it to disk, then publish it under its final name with an exclusive rename that fails if the
   name exists (on macOS, `renamex_np` with `RENAME_EXCL`; elsewhere, `link` then `unlink`).
2. Flush the device folder, so the media names are durable.
3. Persist the HLC state used for the stamp (section 4.2), flushed to disk.
4. Write the event JSON to `.<event-id>.json.tmp` in the same folder, flush it, publish it as
   `<event-id>.json` with the same exclusive rename, then flush the folder again.
5. Only now update the producer's own records of what it wrote (holos's per-ref table, section 7.7).
   A crash between steps 4 and 5 then gives at worst a second event with the same (`source.app`,
   `source.ref`, `source.revision`), which a consumer already treats as one capture (5.4). The opposite
   order would record an event that never reached the folder, and it would never be written.
6. Never modify or delete either file afterwards. A later change produces a new event (section 3.2).

"Flush to disk" on macOS means `fcntl(F_FULLFSYNC)`, because plain `fsync` does not empty the drive's
own cache. A producer that cannot afford it must say its durability is best effort.

Because the media land before the event, the presence of `<event-id>.json` means its media are
complete on the producer's disk. This is the same order holos uses for its own history (audio renamed
into place before the record line is appended).

Leftover temporary files. Only the producer removes its own, and only those older than one hour, the
age holos uses for its own partial audio. Several processes of one producer can share a device folder
(holos does, section 7.7), so a launch must never remove a file another process is still writing.

When the root cannot be written (an external volume is not mounted, a folder grant was revoked, the
disk is full), the producer keeps the event in its own "to write" queue, retries, and shows "capture
folder unavailable, N waiting" in its own window. Section 7.7 says how holos does this.

### 5.3 Reading

A consumer lists each device folder, ignores dot-prefixed names and names that are not `<uuid>.json`
(or `<uuid>.json.age` in an encrypted root), and compares the names with its cursor. The cursor is its
own and lives in the consumer's storage, never in the capture folder. It holds:

- the set of ingested ids, each with the file's size and SHA-256;
- the set of pending, deferred and quarantined names, each with the file's size and modification time
  when last examined.

Ingesting is one durable step. The consumer records the id, size and digest in its journal and flushes
it before any model call. Interpretations are keyed by (capture id, `prompt_version`), and proposals by
interpretation id, so a crash that re-runs a step finds the derived event already made and builds
nothing new. The cursor can be rebuilt from durable facts: the ids named in `inputs` of the consumer's
stored derived events, and the capture ids in each binder's provenance. A rebuilt cursor makes no new
interpretation or proposal for a capture that already has one. In Sprava the journal is
`capture/journal.ndjson` (architecture.md, section 8).

Every pass lists the folder and diffs the names against these sets, which costs the same as the
listing. Ingestion never depends on the order of names or stamps: files from a synced folder can
arrive in any order, version 4 ids do not sort by time, and a clock that was set back writes stamps
that sort below earlier ones. The consumer watches the folder for new names (an atomic rename raises a
directory event; polling every few seconds is an acceptable fallback).

An event file is complete for a reader when all of these hold:

1. its name is `<uuid>.json` with no leading dot;
2. it parses as JSON, `format` is known, `format_version` is one the reader knows, and the file
   validates against that version's reader schema;
3. `id` equals the file name, `device.id` equals the folder name, `hlc.node` equals `device.id`
   without hyphens, `supersedes`, when present, differs from `id`, `captured_at` and `created_at` parse
   as real instants (no 30 February), and every copied `media[].path` starts with `<id>.` and does not
   end in `.tmp`;
4. every `media[].path` names a file that exists with the stated `bytes` (a reader that verifies
   `sha256` does so here). In an encrypted root the file on disk is `<path>.age`, and `bytes` and
   `sha256` are checked after decryption;
5. for a derived event, every `inputs[].id` names an event the consumer has.

What happens when a check fails:

- Check 2 fails because the file does not parse, or check 4 or 5 fails: the file is pending. A sync
  client may deliver a file in pieces, so a half-written JSON file is normal there. The consumer
  retries whenever the file's size or modification time changes. Some sync clients leave an
  online-only placeholder that never downloads by itself, or that blocks on read. The consumer asks
  the sync client to download a placeholder, reads it off the watcher's thread with a timeout, and
  treats it as pending until then. After a grace period with no change
  (an hour is reasonable for a synced folder), a file that still does not parse is quarantined; a file
  still missing media is ingested with the media marked missing, and the consumer keeps retrying the
  media; a derived event still missing an input stays pending.
- `format_version` is unknown: the file is deferred and read again after the consumer is upgraded.
- Check 2 fails on schema validation, or check 3 fails: the file is quarantined.

A quarantined file is shown on the consumer's health page and never deleted by the consumer. Its name
stays out of the ingested set, and the consumer examines it again whenever its size or modification
time changes, and after every consumer upgrade.

Warnings. The checks CE-5 to CE-10 in section 11 never block ingestion, except the media id prefix,
which check 3 above enforces. A failure is shown on the
health page with the file's name.

### 5.4 Idempotence

Reading the same file twice must change nothing. Ids are the dedupe key. The triple (`source.app`,
`source.ref`, `source.revision`) is a second one, across devices: two events with the same triple are
one capture (section 3.2). Both parts are required in every event, so two typed notes always differ:
each has its own minted `ref`. The developer importer (section 7.8) and holos's own producer compute
the same dictation revision from the same bytes, so the hand-over from one to the other ingests nothing
twice.

### 5.5 The phone inbox

A phone app is just another producer with its own device id. It writes the same layout into a folder
that a file-sync service carries to the Mac, encrypted as 5.1 requires, or hands the files over
directly, encrypted the same way. Every path off the Mac or onto it is encrypted. Because nothing in the folder is ever modified, the sync service has nothing to merge. A file
may be seen partly written while the sync client delivers it; the reader's pending rule (5.3) covers
that, and also files that arrive before their media. Sprava v1 does not ship the phone app
(decisions.md M2); the format is ready for it.

## 6. Derived events

A derived event records what was computed from one or more capture events or earlier derived events
(decisions.md C3). It follows the same immutability rule. Its `device` and `hlc` belong to the app that
computed it, in the same shape as a capture event's: Sprava stamps its interpretations with Sprava's
own device id and clock, never with the device id of the capture it read. The schema is in section 10.

### 6.1 Shape

| Field | Type | Required | Meaning |
|---|---|---|---|
| `format` | `sprava-derived-event` | yes | |
| `format_version` | `0` | yes | Read as in section 3. |
| `id`, `hlc`, `device` | as in section 3 | yes | Of the app that computed it. |
| `kind` | `interpretation`, `summary`, `proposal`, `filing` | yes | What was computed. |
| `created_at` | ISO 8601 with offset | yes | When it was computed. |
| `inputs` | array of `{id, format, sha256?}`, at least one | yes | The events it was computed from. |
| `sensitivity` | `unmarked` or `private` | yes | `private` when any input is private, or when the event names or targets a binder whose `disclosure` is `none` (decisions.md F6). Otherwise `unmarked`. |
| `producer` | object, section 6.2 | yes | Who computed it and with what. |
| `outcome` | enum, section 6.3 | yes | Whether `content` is usable and, if not, why. |
| `outcome_detail` | object | no | Numbers behind the outcome: context size, token count, reset time, parts skipped, windows cut off (`truncated`), items dropped, retries, an error code. Never capture text or model text. |
| `content` | object | when outcome is `ok` or `partial` | Depends on `kind`. |
| `binder` | string | no | For a `proposal` or `filing`: the binder its ops target. Absent on a not-sure proposal. |
| `supersedes` | UUID | no | The derived event this replaces. |
| `extensions` | object of objects | no | Producer-specific data. The rule for `outcome_detail` applies here too: no capture text, model text or binder content beyond what `content` holds. |

Kinds:

- `interpretation`: the clerk's typed reading of one capture; `content` follows the interpretation
  schema (section 6.4). This is the Tier-1 derived event.
- `summary`: a free-text title, summary, key points and action items as plain strings. holos produces
  these for meetings with Apple's on-device model (section 7.4). Sprava's clerk does not produce
  summaries in v0 (decisions.md P5).
- `proposal`: an op batch built by code from an interpretation, pointing back at it. Its `content`
  is a teka op batch (`docs/spec/schemas/op-batch.schema.json`, from the sibling draft
  `docs/spec/teka-v0.md`) and is opaque here. One proposal targets one binder, named in `binder`; the
  items with no binder form one not-sure proposal with no `binder` (section 6.5).
- `filing`: the record that a proposal was approved and applied: which ops (as lines of the binder's
  `.sprava/ops.ndjson`, `docs/spec/schemas/op.schema.json`), into which binder, who approved, when. It
  closes the chain from a binder item back to the capture (decisions.md F3, `provenance`). A capture
  whose items went to two binders has one filing event per binder, each naming only that binder's ops.

Where derived events live: ones written by an external producer (holos's summaries) go into the capture
folder beside the capture event, under the producer's device folder. Ones Sprava computes live in
Sprava's own store and are never written into another producer's folder. Before filing that is the
app's capture store, and the full capture and the full interpretation stay only there. At filing,
each binder receives a per-binder excerpt (section 9): the capture's sentences for its own items, the
capture id and digest, and an interpretation excerpt holding only its own items, whose `inputs` name
the full interpretation by id and digest. The proposal and filing events for that binder go with it.
The file format is the same in every place.

### 6.2 Producer identity

| Field | Meaning |
|---|---|
| `tier` | 0: code only, no model. 1: an on-device model. 2: a brain connected over MCP. |
| `app` | Who ran it: `sprava`, `holos`, or an MCP client's name. |
| `app_version` | That app's version. |
| `model` | The model's name, such as `apple-on-device`. Null for tier 0. |
| `variant` | The model variant when known. For Apple's model on macOS 27: `core3` (the 3B model, 4,096-token context, M1 and M2 Macs and M3 or later Macs with less than 12 GB; architecture.md 5.1) or `coreAdvanced3` (the 20B-sparse model, 8,192 tokens, M3 or later with 12 GB). |
| `os_build` | The OS build, such as `26A428`. |
| `prompt_version` | The producer's version tag for its instructions and schema. Apple says prompts behave differently across model versions, so a re-run under a new tag supersedes the old reading. |
| `context_size` | The model's context window in tokens at the time, read at runtime (decisions.md P2). |

### 6.3 Outcomes

| Outcome | Meaning | Apple framework error it maps from |
|---|---|---|
| `ok` | `content` is complete. | |
| `partial` | Some of the input was not read or not covered: a window skipped, a window the model refused after the retries in 6.4, an answer cut off at the response cap, or actionable sentences no item covers. `outcome_detail.parts`, `skipped_parts` and `truncated` say how much, and `content.unfiled` lists the spans. | |
| `invalid_output` | The answer did not parse, or no item survived the code-side checks (section 6.4). | |
| `context_exceeded` | The input did not fit even in the smallest window; `outcome_detail.context_size` and `token_count` carry the numbers. | `LanguageModelError.contextSizeExceeded` |
| `guardrail` | The model's safety filter blocked input or output for every window, after the retries in 6.4. A long benign text can trip it. | `guardrailViolation` |
| `unsupported_language` | The capture's language is not one the model supports (Ukrainian, for example). | `unsupportedLanguageOrLocale` |
| `refused` | The model declined every window, after the retries in 6.4. | `refusal` |
| `rate_limited` | Too many requests; `outcome_detail.reset_at` when known. | `rateLimited` |
| `concurrent` | The session was already busy. A bug in the caller, recorded so it is visible. | `LanguageModelSession.Error.concurrentRequests` |
| `unavailable` | No model: Apple Intelligence off, device not eligible, model not ready. | `SystemLanguageModel.availability` |
| `timeout` | The producer gave up waiting. | |
| `error` | Anything else; `outcome_detail.error_code` names it. | |

A failed outcome is still a derived event. It is how the review queue shows "this capture could not be
read, here is why" instead of silence, and how a later retry (new event, `supersedes` the failed one)
is tied to the first attempt. Whatever the outcome, a capture's text reaches the queue: on a failure
the card shows the capture itself so the person can file it by hand (Tier 0).

### 6.4 The Tier-1 interpretation

The interpretation is the clerk's output for one capture. It is deliberately flat and stable: the
model emits a small set of typed facts, and plain code turns them into proposals. The op vocabulary
can change without touching any prompt, a small model is more reliable on one flat shape than on a
growing union of op types, and "Thursday" is resolved by code from the capture's own timestamp and
locale (decisions.md C3, A3). The model copies words; code computes dates, numbers and confidence.

The interpretation has two variants. Code picks the variant from the capture: `document` for a
`document` capture and for a `share` whose media include a PDF or an image of a document; `capture`
for everything else. The `capture` variant reads a dictation, a meeting, a typed note, a shared item
or an email and lists items. The `document` variant reads one short document and lists its facts
(decisions.md P5: title and date a short document). `language` is the capture's `locale`, and titles
are written in that language.

Capture variant, one entry per item in `items[]`:

| Field | Filled by | Meaning |
|---|---|---|
| `title` | model | A short title for the item. |
| `action` | model | `call`, `pay`, `send`, `review`, `wait`, `file`, `meet`, `decide`, `note` or `other`. Named `action` so it is never confused with the teka item `kind`, to which code maps it (section 6.5). |
| `when_text` | model, checked by code | The time expression exactly as spoken. Never a resolved date. |
| `when_role` | code | `due`, `expected` or `follow_up`, from the words around `when_text` (section 6.6). |
| `when_resolved` | code | The date code resolved `when_text` to (section 6.6). Absent when it could not. |
| `people` | model, checked by code | People named for this item, as spoken; a role such as "the notary" is fine. |
| `amount` | model `text`, code `value` | `{value, currency?, text}`. The model copies `text` exactly as spoken; code parses `value` and `currency` from it. |
| `speaker` | code | Meetings only: the label of the turn that holds the item's sentence. |
| `binder_guess` | binder call `name`, code the rest | `name` is the binder the separate binder call chose (step 2), or the one `binder_hint` names, and is absent when the answer was "not sure". `signals` and `confidence_band` are computed by code (check 5). `from_hint` marks a binder taken from `binder_hint`. |
| `match` | model (third call), checked by code | `{candidate, relation}` when the item is an open item already in the binder (step 3). |
| `source_span` | model `quote`, code the rest | `quote` is the opening words of the sentence the item came from (model). `anchored`, `start` and `end` say whether and where code found it; `start` and `end` cover the whole sentence, in Unicode scalar values (section 12, question 22). |

`unfiled[]` (code) lists spans of the capture that no item covers and that look actionable, that the
model refused to read, or whose answer was cut off, so the review card can show them in the capture's
own words.

Document variant, one object under `document`:

| Field | Filled by | Meaning |
|---|---|---|
| `title` | model | A title for the document. |
| `date_text` | model | The document's date as printed. |
| `date` | code | `date_text` normalized to `YYYY-MM-DD`. |
| `kind` | model | `invoice`, `receipt`, `letter`, `notice`, `statement`, `contract`, `form`, `court`, `tax` or `other`. |
| `parties` | model, checked by code | `[{name, role?}]`, roles such as sender, recipient, payer, payee. |
| `amounts` | model `text`, code `value` | `[{value, currency?, text}]`. |
| `deadlines` | model `when_text` and `label`, code `when_resolved` | `[{when_text, when_resolved?, label}]`. |
| `summary` | model | One sentence on what the document is. |
| `binder_guess` | binder call, code | As above. |

The model-facing schemas. The model never sees `interpretation.schema.json`. It is given separate,
published schemas in the form Apple's guided generation accepts (section 10.3):
`interpretation.model.schema.json` for the capture variant, `interpretation.document.model.schema.json`
for the document variant, and `interpretation.binder.model.schema.json` for the binder call. Their
rules, learned by testing with the `fm` developer tool: every object has a `title` and an `x-order`
list and `additionalProperties: false`; a `$ref` names its target by that title; no `pattern`
(generation fails with "An unsupported generation guide was used"); no type unions such as
`["string", "null"]`. `enum`, `minimum`, `maximum` and `maxItems` stay in the schema the model is
given. `minLength` and `maxLength` load without error but are removed from the schema the model
actually uses, so they are not enforced: a saved transcript shows them gone, and a quote of 52 words
came back against `maxLength: 200` and "at most twelve words". Code therefore checks every length
afterwards. The capture schema holds only what the model writes: `quote`, `title`, `action`,
`when_text`, `people` and `amount_text`, with at most six items per window (`maxItems`). `when_text`
and `amount_text` are required and empty when there is none, which the test in 10.5 found gave better
recall than optional fields. Code builds the per-call parts: the binder call's enum is the names
offered plus `not-sure`, and the duplicate call's enum is the candidate ids plus `none`.

What the clerk receives. Each capture is read in steps, each a small task in its own call
(decisions.md A3, P5).

1. Extraction. One call per window of the capture text (see "Windows"), with the window, `captured_at`
   and `locale`. No binder list, no retrieved facts and no binder content are in this call. It splits
   the window into items and copies their words.
2. Binder. One call per item, with greedy sampling, the item's sentence, and the names of the binders
   the capture may be filed into, each with a one-line description (architecture.md 5.3, the binder call:
   about 330 tokens of binder list for 20 binders). A binder whose `disclosure` is `none` (decisions.md F6) is left
   out unless the person added it to the filing list on purpose, as architecture.md 5.4 requires; an
   opted-in one is offered with a description the person wrote, so its name never appears by accident.
   When the capture has a `binder_hint` that names a binder the person has, code takes that binder,
   skips this call, and marks the guess `from_hint`. Splitting and picking a binder are two tasks:
   in one call they did poorly (section 10.5).
3. Duplicates. For each item with a binder, code retrieves a handful of open items from that binder
   only, by a full-text search of the sentence in the binder's index (decisions.md A3), redacted items
   included. Redaction controls what the hub and the cross-binder view show (decisions.md F2, F8); this
   call runs on the device, already reads the capture, and holds one binder's content, so CI-10 still
   holds. Leaving redacted items out would make every item filed from a meeting, document or email
   (private by default) invisible to the next capture about the same matter. When there are
   candidates, one call asks whether the item is one of them; the answer is an enum of the candidate
   ids plus `none`, and a relation `same`, `done` or `update`. Code checks the id against the offered
   list.

Who owns the call plan. This section owns the interpretation's shape, the windows, the code-side
checks and the date rules. architecture.md 5.3 owns the token budget table, the 60-second time budget
per capture (decisions.md M3) and what happens when time runs out (architecture.md 3.4 and 5.3): a
code-built card first when the minute is at risk, and a clerk pass that runs out of time keeps its
finished windows and lists the rest as unfiled spans. Both documents use the windows below. For
meetings, architecture.md 5.3 takes the second option of section 12, question 6: it reads holos's
action items one at a time and files the transcript as a document. The cost of one capture is one call per window, one binder
call per item and at most one duplicate call per item. Measured on the faster Core Advanced model, a
window of 100 to 140 words took 3.1 to 6.5 seconds and a binder call about 0.9 seconds, so a 538-word
note (5 windows, about 16 items) needs about 21 seconds of extraction and about 15 of binder calls
before any duplicate call. On the 3B model it will be slower; the 60-second fallback then applies.

Windows. Recall falls as captures grow. On an invented 538-word dictation that held 18 actionable
items, one call returned 11 distinct items and silently missed 7, including a payment instalment and
its due date; reading the same text one paragraph at a time recovered several of the missed items
(section 10.5). So code splits any capture above about 150 words into windows of about 100 to 150
words, at paragraph boundaries, or at turn boundaries for a meeting. The window size is a starting
point to be measured. Each window is one call in a fresh session.

Budget. Before each call, code measures `tokenCount(instructions + schema + window)`, adds a reserve of
`maxItems` times a measured per-item cap, plus a margin, and makes the window smaller when the total
does not fit `contextSize` (decisions.md P2). A worked example for a 4,096-token Mac, measured with
`fm count-tokens`: realistic instructions (147 words of field rules, the capture date, the locale and
a short binder list this call no longer needs) 281 tokens; the capture schema as text 412 tokens, which a saved `fm` transcript confirmed (about 413); a
150-word window about 220 tokens; a reserve of 6 items at about 110 tokens each, 660 tokens. That is
about 1,600 tokens, well inside 4,096. Even the whole 538-word note in one call (1,313 input tokens,
18 items at 80 to 110 tokens each) would total about 2,750 to 3,300. So windowing exists for recall;
the budget alone would not need it. Code sets `maximumResponseTokens` to the reserve. An answer cut off at that cap is
not a complete object, so code streams the response, keeps the items that were complete when the cap
was hit, lists the rest of the window's text in `unfiled` with reason `truncated`, counts the window
in `outcome_detail.truncated`, and makes the outcome `partial`. The model writes only the opening words
of each sentence as its quote and code finds the whole sentence, because quotes were the largest part
of the answer.

Retries. On `refused` or `guardrail` for one window (a short, benign paragraph was refused under guided
generation in the skeptic's runs), code retries once with the window merged with a neighbouring window,
then once with reworded instructions. After that the window's text goes on the review card as an
unfiled span with reason `refused` or `guardrail`, `skipped_parts` counts it, and the outcome is
`partial`. A refused or cut-off window's text always reaches the queue word for word.

Code-side checks after the model answers, all required before an interpretation is accepted. Code
first cleans each item, then validates each item on its own. In a meeting, turn headers ("A. Example
(00:15:20):"), gap lines and marker lines are part of `text` but are never read as content by checks
2, 4 and 8.

1. Anchor. Each `quote` is located in the capture text, case-insensitively and with whitespace
   collapsed; `start` and `end` are set to the sentence that holds it, and `anchored` to `true`. An
   item whose quote is not in the capture text is dropped and counted in `outcome_detail.dropped_items`;
   the card says only "the clerk mentioned N things that are not in your note", with no quote stored.
   This also removes items the model built from anything other than the capture. A quote or title
   longer than the strict schema allows is shortened at a word boundary, never dropped.
2. Time. `when_text` is kept only when it occurs in the item's sentence and matches a known time
   pattern for the locale (section 6.6). Values such as "none", "now" or "not to the tenant" are
   dropped.
3. Amount. An amount is kept only when its `text` occurs in the item's sentence and code can parse a
   number above 0 from it, in digits or in words, in English or French. The model never writes the
   number; the published model schema has only `amount_text`.
4. People. Each entry of `people` must occur in the capture text as whole words, case-insensitively,
   and have at least two letters, or be an initial followed by a surname ("A. Example"). Pronouns and
   indefinites are dropped by a per-locale list: someone, somebody, anyone, nobody, me, I, you, him,
   her, them, us, we; quelqu'un, personne, moi, toi, lui, elle, eux, nous, vous. In the skeptic's runs
   the model returned "someone", "me" and a cut-off "A", and a plain substring test would have kept
   all three. A `wait` item left with no person becomes an open item.
5. Binder. A name outside the offered list (impossible with the enum, checked anyway) is dropped;
   `not-sure` becomes no name. Code then records which signals agree with the name in `signals`:
   `hint` (the `binder_hint` names it), `binder_call` (the model picked it), `index_match` (a full-text
   match of the item's sentence in that binder's index), `neighbours` (the items around it went to the
   same binder). `confidence_band` follows a fixed table:

   | Signals | Band | Proposal confidence |
   |---|---|---|
   | `hint`, with or without others | high | 0.9 |
   | `binder_call` and `index_match` | high | 0.9 |
   | `binder_call` and `neighbours`, no `index_match` | medium | 0.75 |
   | `binder_call` alone | low | 0.5 |

   An item goes to its binder when the band is high or medium, and to "not sure" when it is low, with
   the guess shown on the card. The proposal's and each op's `confidence` (op-batch.schema.json) take
   the number in the table. The number is advisory: code acts on the band, never on the number alone
   (architecture.md 4.6). The card shows the signals. A new binder has an empty index and can reach only medium. The model never
   writes a confidence: in the skeptic's runs it gave 1.0 to wrong binders as readily as to right ones.
6. Merge. Two items are merged only when their sentences, their `action` and their titles (near
   duplicates) all agree. One sentence often holds two actions, and both are kept.
7. Speaker. In a meeting, code sets `speaker` to the label of the turn that holds the item's sentence
   (section 6.5 uses it).
8. Validate. Each item, with the code fields added, is validated against `interpretation.schema.json`.
   An item that fails is dropped and counted; the others stand. The outcome is `invalid_output` only
   when the answer does not parse or no item survives.
9. Coverage. Code splits the capture into sentences. A sentence that no accepted item covers and that
   holds a time expression, an amount or an action verb is listed in `unfiled` with reason
   `not_covered`, and the outcome is `partial`. The review card shows it as "not filed yet", in the
   capture's own words.

The document variant. The model reads the document's text from the start, capped by tokens at the
first block, about 400 tokens, as architecture.md 5.3's document call is, through `interpretation.document.model.schema.json`, then the binder call
runs once for the document. The same protection as checks 1 to 4 applies: each deadline's `when_text`,
each amount's text and each party's name must occur in the text that was read, case-insensitively and
with whitespace collapsed, or it is dropped and counted. `date_text` and each deadline's `when_text`
are resolved by code (section 6.6), and over-long strings are shortened as in check 1.

`outcome_detail.error_code` is a short code such as `answer_not_json`; it never holds capture text or
model text, which keeps the rule holos already follows that dictated text never reaches logs.

### 6.5 From interpretation to proposal to filing

Code builds one proposal per (interpretation, binder), plus at most one not-sure proposal per
interpretation for the items with no binder, stored as architecture.md section 4.6 says (a binder's
`.sprava/proposals/`, or the app's `unfiled/` for not-sure). Each proposal derived event names its
binder in `binder` (section 6.1). When the person moves a not-sure item into a binder, code builds a
new proposal for that binder that supersedes the not-sure one. For an item with a binder, the ops are:

| Interpretation | Teka op and fields (`docs/spec/teka-v0.md`, decisions.md F2, F3) |
|---|---|
| `match.relation` `same` | No op. The card shows "already in the binder" with a link to the item. |
| `match.relation` `done` | `complete` on the candidate. |
| `match.relation` `update` | `update_item` on the candidate with the changed dates. |
| No match | `add_item`, as below. |
| `title` | `title`. |
| (none) | `priority: normal`. |
| `action` `wait` and at least one person in `people` | `status: waiting`, `waiting_on` the first person. Otherwise `status: open`. |
| a meeting item whose `speaker` is not the person capturing (the `self` hint, section 3.4), with `action` `call`, `send`, `pay` or `review` | `status: waiting`, `waiting_on` the speaker's name. "I'll send the statement by Friday", said by the property manager, is something the person waits for. The card says so. |
| `when_resolved` with `when_role` `due` | `due`. |
| `when_resolved` with `when_role` `expected` | `expected_by`. |
| `when_resolved` with `when_role` `follow_up` | `follow_up_at` for a waiting item; `due` for an open one. |
| a waiting item with no `follow_up_at` | `follow_up_at` by the default formula of teka-v0 §5.3, with the capture date as today: `max(today, min(base, due))`, where `base` is `expected_by` plus 1 day, else today plus 7 days (a setting), and `min` with `due` applies only when `due` is present. The field is listed in `derived` (decisions.md F3). item.schema.json requires it for a waiting item. |
| an open item with no `due` | `no_deadline: true`. |
| `action` | teka `kind`: `pay` is `payment`; `file` is `filing`; `meet` is `appointment`; `decide` is `decision`; `send` with a person is `reply-owed`; `wait` whose sentence names a document (a report, a draft, a statement) is `document-request`; everything else is `other`. The person can change it on the card. |
| `amount` | the op's `note` (for example "1,200 dollars"), until section 12, question 8, is settled. |
| capture `sensitivity` `private` | `redact: true` by default, with the `kind` above. |
| (always) | `provenance`: the capture event id in `events`, the interpretation id in `interpretation`, `proposed_by` `{kind: clerk, model}`, the proposal id. The batch's `provenance` uses the same two fields. |

Every `add_item` that code builds is validated against `item.schema.json` before the proposal is
stored (CI-14). An item that fails is shown on the card with what is missing, never sent to the
transaction guard to be rejected there (decisions.md A2).

For the document variant, code first copies the document's media file into the binder's `intake/`
folder, then proposes `file_document` with `from` set to that file (decisions.md F7: the path is inside
the teka) and the record's `title`, `date`, `kind` and `sha256`, plus one `add_item` per deadline that
resolved, titled with the deadline's `label`, with teka `kind` `payment` for an invoice,
`legal-deadline` for a court document, `filing` for a tax document, and `other` otherwise.

When a superseding capture arrives:

- a proposal built from the old capture that is still waiting is withdrawn and rebuilt from the new
  one;
- items already filed from the old capture get a change proposal (`update_item`, `complete` or `drop`),
  so a corrected dictation becomes a reviewable change and never a duplicate;
- a superseding event with the same text, a raise of sensitivity, or a retraction, follows section 3.2.

When the person approves, the runtime applies the ops and writes one `filing` derived event per binder
whose `inputs` name the proposal and whose `binder` names the binder.

### 6.6 Relative dates are resolved by code

The model never writes a date. Code resolves `when_text` from `captured_at` (its date and offset) and
`locale`, with rules a person can predict. When `captured_at_estimated` is `true`, relative expressions
are left unresolved and the card shows `when_text` for the person to confirm; only full dates resolve.

Prefixes are stripped before resolving, and they set `when_role`. A prefix counts when its words occur
in the same sentence within six words before `when_text`, in order, with other words allowed between
them: "if nothing comes by Wednesday" matches "if nothing by", although the model copied only
"Wednesday".

- "by", "before", "at the latest", "d'ici", "avant", "au plus tard": `due`;
- "until", "within", "should arrive", "jusqu'à": `expected`;
- "if not by", "if nothing by", "follow up", "relancer": `follow_up`;
- hedges ("probably", "maybe", "sans doute") are stripped and set nothing.

With no prefix, the role is `expected` when the item's `action` is `wait` (a bare date about another
party's action is the date that party gave, decisions.md F3), and `due` for every other action.

English rules:

- A weekday name ("Thursday", "by Friday"): the next such day after the capture date. Said on that
  weekday, it means one week later; "this Thursday" said on a Thursday means the same day.
- A day of the month ("the 15th", "the fifteenth"): the next such day after the capture date. Said on
  that day, it means the same day next month, the same rule as for a weekday. A day the month does not
  have ("the 31st" in a 30-day month) is left unresolved.
- "next Thursday": left unresolved, because people use it for both this week and the next.
- "tomorrow", "in three days", "in two weeks": counted from the capture date.
- "next week": the Monday of the following week.
- "end of the month", "end of the year": the last day of the capture's month or year.
- A month and day without a year ("October 3"): in the capture's year when that day is today or later.
  When it passed less than about 60 days ago ("the invoice from October 3", said on October 6), it is
  left unresolved and shown, because the person most likely means the past date. Only a day that passed
  longer ago moves to the next year.
- Numeric dates: ISO dates (`2026-10-15`) resolve. Any other numeric form is left unresolved for
  `en-CA`, where both day-first and month-first are in use.

French rules (`fr-CA`, `fr-FR`), the same way:

- "jeudi", "d'ici vendredi": the next such day, as above; "jeudi prochain": unresolved.
- "demain", "dans trois jours", "dans deux semaines": counted from the capture date.
- "la semaine prochaine": the Monday of the following week.
- "fin du mois", "à la fin du mois", "fin de l'année": the last day of the month or year.
- "le 15", "le quinze": as "the 15th" above.
- "le 3 octobre": as "October 3" above.
- Numeric dates are day first for `fr-FR`. For `fr-CA` only ISO dates resolve, as for `en-CA`.

Everything else stays unresolved; the item still reaches the queue with `when_text` shown, and the
person types the date. A date that resolves to before the capture date ("yesterday", "two weeks ago")
is never used as `due` or `follow_up_at`; it stays as text on the card.

Document dates (`date_text` to `date`) use the same code, with the printed year.

## 7. Producer profile: holos

> **Reframed by decisions.md P12 (2026-10-07).** Sprava is input-agnostic: it receives text, and later
> documents, images and videos through an adaptation layer. No producer is privileged or required. This
> section stays as one worked example of an adapter's mapping; nothing in Sprava depends on it.

holos ("Voice is Local") is the author's GPL-3.0 dictation and meeting app for macOS 27. It records
every finished dictation as one JSON line and every meeting as a portable folder, all written
atomically with the same JSON conventions (ISO 8601 dates in UTC at one-second precision, sorted keys,
readers ignore unknown keys). It offers no notification, URL scheme or socket; every cross-process
signal in holos is a file. This section maps what holos has today onto the envelope and the derived
events (decisions.md C4). Paths are relative to the holos repository.

### 7.1 Dictations

A dictation record (`DictationRecord`, `Sources/HolosCore/DictationHistory.swift`) maps as follows.

| holos field | Envelope field | Notes |
|---|---|---|
| (new) | `id` | A fresh UUID v7; never the dictation id, because one dictation can produce several events over time. |
| (new) | `hlc` | holos's own clock at the time of writing (section 4.2). |
| (new) | `device` | holos's device id on this Mac. |
| `schemaVersion` (1) | `extensions.holos.schemaVersion` | |
| `id` (uppercase UUID) | `source.ref` | Verbatim. |
| the record as stored | `source.revision` | Defined on the stored bytes, never on the in-memory record, whose `date` has sub-second precision that the stored form drops: take the bytes `HolosJSON.line(record)` appends to `dictations.jsonl` (`Sources/HolosStorage/DictationHistoryStore.swift`), parse them as JSON, remove the `audio` key, write the result in RFC 8785 canonical form (sorted keys, no spaces) and hash it with SHA-256. The developer importer gets the same value from the same stored form, read back through `history list --json` (section 7.8; CH-17 tests it). Leaving `audio` out means that deleting kept audio, which drops records' audio links, changes no revision. |
| `date` (UTC seconds) | `captured_at` | With the offset in force at `date` in the Mac's time zone, `TimeZone.current.secondsFromGMT(for: date)`, second precision. The UTC value is kept verbatim in `extensions.holos.date`. |
| `app` (display name or nil) | `app_context.app` | Left out when the value looks like a bundle identifier (the pattern in CE-9): for keystroke targets holos stores `localizedName ?? bundleID` (`Sources/HolosDesktop/TextInsertion.swift`). |
| `terminal` (true or absent) | `app_context.terminal` | Only when true. |
| `language` (locale id) | `locale` | Normalized with holos's own `DictationLanguage.identifier` (`fr_CA` becomes `fr-CA`), with any `@...` keywords dropped, then cut before the first single-letter subtag: `identifier` keeps extensions such as `-u-ca-gregory` and private-use parts such as `-x-...`, which the schema's pattern does not allow, so `en-CA-u-ca-gregory` becomes `en-CA`. holos returns a saved locale as stored, and older data can hold `en_CA`. The raw value goes to `extensions.holos.language` when it differs. |
| `text` | `text` | Verbatim. holos's `text` is already the whole dictation, also when only part of it was written. |
| `unwritten` | `extensions.holos.unwritten` | The tail of `text` that never reached the target app, with its leading space. The review card shows its "not written" note only when `extensions.holos.unwritten` is present. `outcome.partial` alone is history: after Update History it is kept while `unwritten` is dropped and `text` is the new full text. |
| `heard` | `alt_text` | The recognizer's text before filler removal, corrections and the AI fix. Omitted when equal to `text`. |
| `fixes` | `extensions.holos.fixes` | `fillersRemoved`, `corrections`, `aiChangedWords`, `codeSpans`, as holos names them. |
| `outcome` | `extensions.holos.outcome` | `kind` (`inserted`, `typed`, `needsCopy`, `unverified` or `targetChanged`) and `partial` only. holos's `reason` is left out: it is an English sentence for holos's own window that embeds the target app's name, and for a keystroke target that name can be a bundle identifier (`Sources/HolosDesktop/TextInsertion.swift`), which no pattern check inside a sentence catches. The card phrases its own note from `kind`. |
| `seconds`, `words` | `extensions.holos.seconds`, `extensions.holos.words` | Listening-to-release seconds and the word count. `date` plus `seconds`, rounded down to the second, also gives `ended_at` (section 4.3). |
| `audio {file, seconds}` | `media[]` | Only when the person turned on audio copying (off by default, section 7.7) and holos's History keeps audio: copied from holos's finished dictation audio (AAC mono 16 kHz) to `<event-id>.audio.m4a` with `mime` `audio/mp4`, `bytes`, `sha256`, `seconds`, at the moment section 7.7 item 3 names. A superseding event reuses it with `of`. |
| (none) | `people_hints` | Empty; holos extracts no people from dictations. |
| (none) | `sensitivity` | `unmarked`, the default for dictations (section 9). holos has no marking yet. A dictation that ends while secure input is on never produces an event (section 7.7, item 3). |
| (none) | `title`, `binder_hint` | Absent. |

Inside `extensions.holos`, keys keep holos's own names (camel case), so the mapping needs no
translation and a reader can compare against holos's source.

### 7.2 Meetings

A saved meeting is a folder `<UUID>.holos` under holos's sessions directory. The event is built from
the files holos documents as its outward shape: `manifest.json`, `meeting.json`,
`exports/transcript.json` (format `holos-transcript`, the already-projected, label-applied view) and
`summary.json`. holos's internal files (`events.jsonl`, `transcripts/*.json` with word timings,
`speakers/*`, `status.json`, `live.json`, `screen/`, `echo/`, `derived/`, `eval/`) are not part of the
mapping. The holos producer, being holos, reads some of them through its own code to compute the
version key (7.3); a consumer, and the developer importer, never read them (decisions.md P6).

When an event is written is decided by the files, not by the manifest's status: holos writes one when
`transcripts/current.json` names a readable revision and `filesState` reports the exports current.
`transcriptionIncomplete` ("Part of the transcript is missing") still has a readable transcript that
holos labels and offers for deep transcription, so it gets an event, with
`extensions.holos.session.status` set to `transcriptionIncomplete` and `extensions.holos.partialTranscript: true`,
which tells the review card the transcript is partial. `audioOnly`, and an `interrupted` or
`incomplete` meeting with no readable transcript, produce no event until a transcript appears, because
`text` is required. A `recovered` meeting is written like any other once its exports are current.

| holos source | Envelope field | Notes |
|---|---|---|
| (new) | `id`, `hlc`, `device` | As for dictations. |
| `manifest.json.id` (= folder name) | `source.ref` | Verbatim uppercase UUID. |
| version key (7.3) | `source.revision` | |
| `manifest.json.createdAt` | `captured_at` | With the offset in force at that instant. For `meeting.json.origin` `imported`, `createdAt` is the import time (`SessionArchive.create` stamps the current date), so the event sets `captured_at_estimated: true` and relative dates stay unresolved (section 6.6). |
| `manifest.json.locale` | `locale` | Normalized as for dictations; the raw value goes to `extensions.holos.session.locale`. `meeting.json.languages` (when several) goes to `extensions.holos.meeting.languages`. |
| `meeting.json.name`, else `manifest.json.name` | `title` | holos shows the name the person gave; for a meeting that still has its default name, the current summary's title; else the default name (`displayTitle`, `Sources/HolosMeeting/Summary/MeetingSummaryStore.swift`). Sprava uses the person's name, else the default name, and never the summary's title, which arrives as a summary derived event and may change. One exception: an imported meeting with `nameSource` `default` has the imported file's name as its default name, which can hold personal names, so its title is the literal "Imported meeting". |
| `exports/transcript.json` `turns`, `gaps`, `markers`, `speakers` | `text` | Rendered as in 7.5. `turns`, `gaps` and `markers` are kept verbatim under `extensions.holos`. Each speaker is kept with `id`, `ordinal`, `label`, `name`, `automatic`, `profileID`, `talkSeconds` and `turnCount` only: `provenance` is left out, because for an automatic match it carries a voice-match distance for a named person (`Sources/HolosCore/SpeakerModels.swift`). |
| `exports/transcript.json` `speakers[]` | `people_hints[]` | Decided from the export's own signals, never from label strings (a person can rename a speaker "Speaker 3"). `provenance` `userRenamed` or `userConfirmed`, or a non-null `profileID`, gives a confirmed hint with the speaker's `name`. `automatic: true` with `profileID` null gives the name with `confirmed: false`. `diarizer` or `channelAssumption` with neither gives no hint, except the channel speaker `mic:me`, which gives a `kind: self` hint, with no name when it has none; a linked profile marked `isSelf` is `kind: self` too. `external_id` is `holos:profile:<profileID>` only when `profileID` is not null. Suggestions ("possible" matches) are never exported by holos and never appear. |
| `manifest.json.chunks[]` | `extensions.holos.session.chunks` | Not media: meeting audio is not copied by default, and holos registers normally recorded chunks with no digest (`Sources/HolosAudio/ChunkWriter.swift`). Each entry keeps `id`, `track`, `start`, `end`, `frameCount`, and `sha256` when present. When meeting audio copying is on, the producer copies the audio into the device folder and lists the copies as media. |
| `meeting.json` (`mode`, `othersInRoom`, `origin`, `expectedSpeakers`, `languages`, `nameSource`, `name`) | `extensions.holos.meeting` | Verbatim, except that `name` follows the `title` rule above. `applicationBundleID` and `importedFileName` are left out: the first is a bundle identifier and the second can hold personal names. |
| `manifest.json` (`source`, `locale`, `backend`, `status`) and the export's `session.durationSeconds` | `extensions.holos.session` | |
| `exports/transcript.json` `transcriptID`, `runID`, `edits`, `languages` | `extensions.holos.*` | Plus holos's `editsGeneration` string and the `namesDigest` from the version key, for information. |
| `summary.json` (when current) | a derived event of kind `summary` | See 7.4. |
| (none) | `sensitivity` | `private`, the default for meetings (section 9). |
| (none) | `binder_hint` | Absent unless holos gains a per-meeting binder field. |

### 7.3 The meeting version key

A meeting keeps changing after it is saved: every processing pass (recovery rebuild, language merge,
live-hint reconciliation, word fixes, deep transcription, review revert) creates a new immutable
transcript revision and repoints `transcripts/current.json`; a relabel appends to
`speakers/edits.jsonl`; `exports/` is regenerated after each of these. The people store changes the
names too, but not always the exports: renaming a person regenerates no export ("Meetings keep the name
the person had when they were linked", `Sources/HolosCLI/People.swift`), while it still changes the
names holos would compute live for automatic names and for the user's own name. A merge regenerates
exports only for meetings with recognition results. The event must therefore be versioned by what the
exports actually show. The key keeps the four parts decisions.md C4 names:

```
(transcriptID, runID, edits generation, names digest)
```

- `transcriptID` is the revision named by `transcripts/current.json`.
- `runID` is the diarization run named by `speakers/head.json`, or `-` when there is none.
- The edits generation is the byte length of the session's whole `speakers/edits.jsonl`, one journal
  per session, or `0`. holos's own generation (`SessionSpeakerStore.generation`) is
  `<head runID>:<byte length>`; its run id part repeats `runID`.
- The names digest is computed from the same `ExportDocument` that was just rendered into the exports:
  `MeetingSummaryKey(document, selfName:)` with the `selfName` that regenerate used. It is a SHA-256
  over every speaker-labelled line as rendered and the people named
  (`Sources/HolosMeeting/Summary/MeetingSummaryStore.swift`). It is never computed live with
  `MeetingSummaryKey.loadChecked(...)`, which builds a fresh document from the current speaker state
  and can disagree with exports that are stale.

All four parts are read inside `SessionExports.regenerateLocked`, under the session's `.speakers.lock`,
from the document that call rendered (section 7.7, item 4). So the key describes exactly the `text` the
event carries.

`source.revision` is the four joined with `|`, for example
`A1B2...|B2C3...|812|5a7c...`. A revision is opaque: a consumer only compares it for equality.

Because the key is taken from the rendered document, two events with the same key carry the same
`text`, which section 3.2 relies on. A fifth part, the SHA-256 of the rendered `text`, would make that
hold by construction; decisions.md C4 fixes four parts, so it is section 12, question 15. A summary
arriving later does not change the key, so it never supersedes the capture. An edit that changes the
edits generation but not the text (a stale edit, an enrollment flag) gives a superseding event with the
same text, which section 3.2 tells the consumer to take without a new interpretation. A rename alone
changes `title` without changing the key; the producer still writes a superseding event, and the
consumer updates the title without re-reading the capture.

A consumer must not derive this key itself from the `.holos` folder. The producer knows it; the
developer importer (7.8) can only approximate it and says so.

### 7.4 holos's summary as a derived event

`summary.json` holds a title (at most 8 words, no date), a summary (one or two sentences), up to five
key points and up to five action items as plain strings, the model code `apple-on-device`, the
language, the transcript revision and names digest it was made from, and optional part counts. It is
current exactly when its stored (`transcriptID`, `namesDigest`) equals the meeting's key
(`MeetingSummaryKey.isCurrent`). A summary is identified by its `createdAtMilliseconds` (else
`createdAt`), never by that key: Summarize Again writes a new `summary.json` for the same transcript
and names, so the key stays the same while the summary changes. While `summary.json` has
`exportsPending` set, the producer waits. It maps to one derived event per distinct summary:

| summary.json | Derived event |
|---|---|
| (new) | `id`, `hlc`, `device` as for the capture event |
| | `kind`: `summary` |
| | `inputs`: the latest meeting capture event whose `transcriptID` and names digest equal the summary's |
| | `sensitivity`: the input's, so `private` by default |
| `createdAtMilliseconds`, else `createdAt` | `created_at`, with the offset in force at that instant |
| `model` (`apple-on-device`) | `producer`: `{tier: 1, app: holos, app_version, model: apple-on-device, variant: null, os_build: null, prompt_version: null}`; holos does not record the variant or build |
| `title`, `summary`, `points`, `actions`, `language` | `content` |
| `parts`, `skippedParts` | `outcome` `partial` when `skippedParts` is above 0, else `ok` (also when either is missing); the numbers present go to `outcome_detail` |
| `transcriptID`, `namesDigest`, `createdAt`, `createdAtMilliseconds` | `extensions.holos.summary` |
| a newer summary for the same meeting (a different `createdAtMilliseconds`) | `supersedes` the previous summary event |

Action items stay plain strings here. Reading them into typed items with dates and people is the
clerk's interpretation, computed by Sprava from the capture event and the summary.

### 7.5 Rendering the transcript as text

`text` for a meeting is built from the export's turns, gaps and markers. The rules follow holos's
Markdown export (`Sources/HolosSpeakers/Export/MarkdownExport.swift`) without its Markdown styling:

- Order: turns by (`start`, track); at equal times a gap comes first, then a marker, then a turn. A
  turn whose JSON `start` is null (holos writes a non-finite number as null) sorts after everything,
  as in holos's `ExportDocument`.
- Each turn becomes one paragraph: the label, then a space, the start time in parentheses as
  `HH:MM:SS` rounded down to whole seconds (no time when `start` is null), a colon, a space, the turn
  text. The label follows holos's `ExportDocument` (`Sources/HolosSpeakers/Export/ExportDocument.swift`):
  - when `speakers` is not empty (the meeting has speaker labels), the speaker's `label` looked up by
    the turn's `speakerID`, and "Unknown speaker" for a turn with `speakerID` null, whatever its track.
    Labelling such a turn "Microphone" would attribute a stranger's words to the person capturing,
    since holos's own summarizer reads "Microphone" in a call as the user;
  - when `speakers` is empty, the track: "Microphone" for `mic`, "System audio" for `system`. A turn
    with no track takes it from `session.source` when only one track was recorded.

  The label is what holos shows, so an automatic match reads "B. Example (auto)" and is never presented
  as a confirmed person. Consecutive turns of one speaker stay separate paragraphs (holos's Markdown
  merges them, the JSON does not, and the JSON is the source).
- Each gap becomes a line in brackets with holos's wording and an en dash between the times:
  `[Recording paused 00:10:01–00:10:55]` for `paused`, `[No audio: computer was asleep ...]` for
  `sleep`, `[Audio restarted ...]` for `deviceChanged` and `captureRestarted`,
  `[No audio: microphone unavailable ...]` for `audioUnavailable`, `[Audio gap ...]` otherwise. A gap
  reported for several tracks prints once.
- Each marker becomes `[Marker 00:15:12: label]`, or `[Marker 00:15:12]` without a label; a doubled
  marker prints once.
- Paragraphs are separated by one blank line; the text ends with a newline.

Times are session time (seconds from the first captured audio, pauses included), as holos defines
them, so they match the structured turns under `extensions.holos.turns`.

### 7.6 What holos deletes, and what the producer must therefore copy

- Dictation records are swept at launch, once a day and when the setting changes, according to the
  retention setting: 7 days, 30 days (the default), forever, or off (`HistoryRetention`,
  `Sources/HolosCore/DictationHistory.swift`). Off stops recording new dictations. Delete removes one
  record; Clear History removes all, in the app or with `voiceislocal history clear --yes`. Audio is
  deleted with its record. Turning off "Keep the audio of dictations" stops keeping new audio and asks
  whether to delete the audio already kept; only if the person accepts is every record's audio link
  dropped (`Sources/HolosApp/HolosApp+History.swift`).
- Update History rewrites a record in place: it sets new `text`, `heard`, `fixes` and `language`,
  recomputes `words`, and drops `unwritten`; it keeps `id`, `date`, `app`, `terminal`, `outcome`,
  `seconds` and `audio` (`Sources/HolosDictation/DictationRerun.swift`).
- Meetings are never deleted automatically. Delete Audio writes `audio-deleted.json` and removes
  `audio/`, `derived/`, `screen/` and `speakers/voice/`; transcripts, runs, edits and exports stay.
  Delete Meeting, `voiceislocal session delete`, or dragging a `.holos` folder to the Trash in the
  Finder moves the whole folder to the Trash, from where the person can put it back.

So the producer copies dictation audio, when copying is on, at the moment the finished audio lands in
History, before any sweep can run (7.7, item 3). The consumer has no deadline when holos is the
producer only while every write succeeds: an event that could not be written (the app was quit or
killed, the capture folder was unavailable) is kept in holos's "to write" queue and found again by the
dictation reconcile, which runs at launch before the retention sweep (7.7, item 5). With History off,
a dictation lost to a crash before its event was written cannot be recovered. Meeting audio is not
copied by default (7.2); a user setting may turn copying on for meetings. When only the developer
importer is available (7.8), the deadline is the shorter retention period: the importer must run at
least every few days.

### 7.7 What holos would need to add

A small feature on the GPL side, in order of work:

1. Settings, all off by default: the capture folder; which dictations to send (all, or only those made
   into apps on an allow list; dictations into a terminal only when the person also turns that on);
   copying dictation audio; copying meeting audio; and "retract when History forgets a dictation".
   The settings pane says that audio copying works only while holos keeps dictation audio, and that
   the capture folder keeps a dictation's text after holos's own History has forgotten it (decisions.md
   C2: the producer never deletes). Turning the capture folder on sends only new captures; a button
   "Also send what is still in History" sends the earlier ones.
2. Shared producer state. The device id is created once with an exclusive create (holos's
   `AtomicFile.create`), together with the installation fingerprint of section 4.4. The HLC state
   `(l, c)`, a per-ref table and a "to write" queue live in holos's support folder, updated under one
   producer `flock`, the same pattern as holos's `profiles.lock`. The per-ref table holds, for each
   ref, the latest event id and revision, the title, a digest of the people hints' names, the
   sensitivity, whether it was retracted, and for a meeting the identity of the last summary written
   (7.4), which is what section 3.2 and item 4 need to decide whether to write. Every holos process
   that writes events takes that lock: the app; the `voiceislocal` child processes and commands that
   run post-processing, summaries, renames, diarization, word fixes and deep transcription; and the
   commands that create or delete captures, `session import`, `session delete`, `history clear` and
   `history rerun`. Under the lock it stamps and persists the HLC, writes the event to its temporary
   name, renames it into place, flushes the folder, and only then records the id and revision in the
   table (section 5.2, step 5).
   The producer lock is always the innermost lock: it is taken after any session `.speakers.lock` or
   `profiles.lock` (holos's own order is speakers, then profiles), held only for the stamp, the rename
   and the table update, and never held while waiting for another holos lock. Media are copied before
   the lock is taken. At launch, holos checks the table and the HLC against its own device folder: it
   scans the `<id>.json` files, sets `l` to at least the highest `hlc.wall_ms` found (4.2), and for each
   ref takes the latest revision actually on disk.
3. Dictations. holos's `recordHistory` (`Sources/HolosApp/HolosApp.swift`) checks, in one guard, that
   an outcome exists, the text is not empty, History records, and secure input is off, and only then
   builds the record. The capture hook splits that guard. It runs on the same draft and applies every
   condition except "History records": a draft exists (it was not refused at key-down and not
   cancelled), an outcome exists, the trimmed text is not empty, and secure input is not active when the
   dictation ends. holos builds no such record today, so this is a code change in `recordHistory`. Within the
   scope setting, the event is written at one of two points:
   - With History on, on History's serial queue, right after the store's append returns the record
     with its audio link. Only then is the audio finished and renamed to `History/audio/<ID>.m4a`
     (`Sources/HolosStorage/DictationHistoryStore.swift`), so that is when it is copied, before any
     sweep on the same queue can run.
   - With History off, from `recordHistory` itself, before the dictation is reported finished, as a
     text-only event: no audio writer exists when History does not keep audio.

   In both cases the dictation is first added to the "to write" queue under the producer lock and
   removed after the table update, so a quit or a crash in between leaves a trace that item 5 finds.
   One superseding write per Update History edit, in the app or with `history rerun`. One retraction per
   Delete, and one per record removed by Clear History, in the app or with `history clear`
   (section 3.2). Nothing for a retention sweep unless the person turned that setting on. When the
   capture folder cannot be written, the event stays queued, and holos shows "capture folder
   unavailable, N waiting".
4. Meetings. The write happens inside `SessionExports.regenerateLocked`
   (`Sources/HolosMeeting/PostProcessing/SessionExports.swift`), which every export path goes through
   and which runs under the session's `.speakers.lock`, so writes for one meeting are serialized. The
   key is taken from the `ExportDocument` that call just rendered, with
   `SessionSpeakerStore.generation` read under the same lock (7.3). Post-processing, relabels, renames,
   summaries, word fixes, deep transcription, language merges and imports all pass through it. A
   people-store rename does not (7.3); item 5 covers it. The event is written only when the exports
   were written and `filesState` reports them current, and only when the key, title, names or
   sensitivity differ from the per-ref table (section 3.2). A summary derived event is written beside
   it when `summary.json` is current, has no `exportsPending`, and its `createdAtMilliseconds` differs
   from the last summary written for that ref (7.4). One retraction per Delete Meeting or
   `session delete`.
5. A reconcile pass, because a hook alone loses events: a process can stop between the export and the
   event, a people-store rename changes names without regenerating anything, exports can stay stale
   until another writer retries, things can be deleted outside holos, and captures made before the
   setting was turned on have no event. It runs at launch, when the setting is turned on, and
   periodically (holos already scans sessions every 30 seconds for summaries).
   - Meetings. For each meeting, the pass calls `SessionExports.regenerate(session:people:)`, which is
     idempotent and writes only the files that differ, and writes the event from the document that
     call rendered, exactly as item 4. It never compares a key computed live with the table and then
     copies the existing exports, because stale exports would then travel under a new key and the
     corrected text would never follow. A ref in the table whose meeting folder is gone (deleted in the
     Finder or from the command line) gets a retraction. A folder that reappears after its retraction
     (put back from the Trash) gets a new event that supersedes the retraction (section 3.2, Restore).
   - Dictations. At launch the pass runs before the retention sweep. It first writes everything left in
     the "to write" queue. Then, when History is on, it writes an event for every History record dated
     after the capture folder was turned on that is absent from the table, with audio when copying is on
     and the audio still exists. A dictation ref in the table whose record is gone while its date is
     still inside the retention period was deleted, not swept, and gets a retraction. With History off,
     only the queue can be replayed: a crash before a dictation reached the queue loses it.
6. Nothing for a dictation refused at key-down, cancelled, empty, or ending while secure input is on,
   whatever the History setting (section 9).
7. The same privacy rules holos already keeps: display names, no bundle identifiers anywhere (holos's
   `outcome.reason` is not copied, 7.1), no voiceprints and no voice-match distances, no vocabulary
   strings, no suggestions. A per-dictation or per-meeting "private" toggle would let the person mark a
   capture beyond the defaults.
8. Optional: a `voiceislocal capture write <dictation-id | session>` command for tests and fixtures.

### 7.8 The developer-only importer

Until holos ships the hook, a developer build of Sprava may read holos's command-line output
(decisions.md P7). It is not for end users. Decisions.md P7 names two commands; the importer needs
two more read-only ones, listed here and flagged in section 12:

- `voiceislocal history list --json [--limit N]`: a JSON array of dictation records, newest first, with
  no wrapper object; each record carries its own `schemaVersion`. "Note:" lines about unreadable or
  newer-schema lines go to stderr and are ignored. The output is pretty-printed, so the importer
  parses each record as JSON and hashes its canonical form exactly as 7.1 defines the revision, never
  the printed bytes. Its dates are the stored whole-second strings, the same values the stored line
  holds.
- `voiceislocal session list --json` (extra): a JSON array of session summaries, newest first, with
  `id`, `name`, `createdAt`, `state` (`complete`, `audioOnly`, `interrupted` and others),
  `transcriptID`, `runID`, `hasSpeakerEdits`, `audioDeleted` and more; the generated summary is
  deliberately left out.
- `voiceislocal session export <id> --format json`: exactly the bytes `exports/transcript.json` would
  hold, with the people store's current names applied, on stdout; it embeds the summary only when one
  is current. Never `--all`, which regenerates files inside the session folder, and never `--output`.
- `voiceislocal people list --json` (extra): the `holos-people` document without voiceprints. It still
  holds, per person, `isSelf`, `createdAt`, `lastUsedAt`, a suggestions flag, and samples with
  `sessionID`, `sessionName`, `speakerIDs` and speech seconds, so meeting names travel through it. The
  importer keeps only `id`, `name` and `isSelf` and discards the rest as it reads.

The importer synthesizes what holos lacks: its own device id and HLC; `captured_at` from the record's
UTC `date` with the offset in force at that date; `source.revision` for dictations exactly as in 7.1;
for meetings, `approx:` followed by the SHA-256 of the export's `transcriptID`, `runID`, `edits`
counts and rendered speaker labels, which is not the 7.3 key. When audio copying is on, it copies a
dictation's audio from `History/audio/<ID>.m4a` under holos's support folder, the one place it reads
holos's private layout, and only because the audio is otherwise lost at the sweep; a missing file
means the event has no media.

Hand-over to holos's own producer. The consumer alone decides it; holos never reads the importer's
device folder and never names an importer event in `supersedes`. Dictations hand over cleanly, because
both compute the same revision: the consumer treats an importer event and a holos event with the same
(`source.app`, `source.ref`, `source.revision`) as one capture (section 5.4). For meetings, the chain
is the same (`source.app`, `source.ref`), and once a holos event exists for a ref, the importer's
`approx:` events for it no longer count when choosing the current event (section 3.2). The first holos
event is then handled as a change to the chain; when the texts are equal, no new interpretation is
made. Once a holos device folder exists in the capture root, the importer stops for good, and the
consumer's settings say so.

Its limits: there is no cursor, so it lists everything every run and dedupes on `ref` plus
`revision`; it must run at least every few days to beat a 7-day retention; it sees an Update History
edit only as a changed revision and a Delete only as a missing record, which it does not retract; it
must never run `session summarize`, `session export --all`, `history clear`, `history rerun` or
anything that writes; it needs `voiceislocal` on the PATH; and nothing it produces has been checked
against real output, because none exists on the drafting Mac.

### 7.9 holos files that are not captures

These exist in holos and must never be read into an event: `vocabulary.json` (private names given to
the recognizer), `words.json` and `corrections.json` (user configuration), `profiles.json` voice
samples, `speakers/voice/` and `speakers/recognition/` (biometric and match data), `screen/`
(OCR evidence; holos never adds it to anything automatically), `live.json` and `live-hints.json`
(transient), `status.json` (carries up to 200 characters of transcript in `lastPhrase`), the recorder
log, `events.jsonl`, and `eval/`.

## 8. Other producer profiles

Each producer below follows sections 3 to 5 unchanged; only the differences are stated. Sprava's own
producers write only into a local capture root (section 5.1). Each mints `source.ref` as a UUID when the
capture is made and keeps it with the draft, and uses the SHA-256 of `text` as `source.revision`, so a
retry after a crash writes the same triple and is recognized as the same capture (section 5.4).

### 8.1 In-app text (Sprava)

`source.app` is `sprava`, `kind` `text`. The device id is Sprava's own. `text` is what the person typed;
there is no `alt_text` and no media. `binder_hint` is set when the person typed inside a binder, and
then the clerk takes that binder without guessing (section 6.4). `captured_at` has millisecond
precision. `ended_at` is when the person saved the note. These events live in Sprava's own device folder under the capture root, so the same reader
code handles them.

### 8.2 Document drop with OCR (Sprava)

`kind` `document`. The dropped file is copied beside the event as `media[0]` (`kind` `pdf`, `image` or
`file`, with `mime`, `bytes`, `sha256`). `title` is the file name. `text` is the file's text layer when
it has one, else the text recognized on device by Vision; `extensions.sprava.text_source` says which
(`text-layer` or `ocr`) and `alt_text` is absent. Recognition is code, tier 0. OCR beyond short scans
is deferred (decisions.md M2). The clerk then reads the capture with the `document` variant of the
interpretation. `sensitivity` is `private` by default (section 9). A dropped file keeps its original
bytes, because the person chose that file; `extensions.sprava.original_bytes: true` says so.

### 8.3 Share sheet (Sprava)

`kind` `share`; `source.app` is `sprava` with `version` the extension's. `app_context.app` is the display
name of the sharing app. `sensitivity` follows what is shared: a share that carries a
PDF, an image or any other file, or that code routes to the `document` variant (6.4), is `private` by
default, like the same file dropped on the app; a shared text or URL alone is `unmarked`. `text` is the shared text or URL followed by any note the person added; an
image or file shared comes as media, with location and device data stripped (section 9). A shared URL
has known tracking parameters removed from `text`; the full URL is kept only in
`extensions.sprava.url`. The share extension may run sandboxed and write only into Sprava's own device
folder.

### 8.4 Email forward

Deferred (decisions.md M2). `kind` `email`; `title` is the subject; `text` is the body as plain text;
attachments are media; `people_hints` carry the display names from the From and To headers with
`kind` `mention` and an opaque `external_id`. A display name that is an address, or contains one
("A. Example <...>"), is cut to the name part, or replaced by "(sender)" or "(recipient)" when no name
part is left. The `external_id` is
`<source.app>:email:<HMAC-SHA256 of the lowercased address under a key made once per installation>`.
The address itself never appears in a hint. If a "reply owed" item needs it, it is kept under
`extensions.<source.app>` and never leaves the binder the capture is filed into. `sensitivity` is
`private` by default, because a mailbox is personal by nature.

### 8.5 Phone inbox

Deferred (decisions.md M2). A phone app is a producer with its own device id, writing `dictation` or
`text` events (and photos as `document` events) into a synced folder, encrypted as section 5.1
requires. It stamps with its own HLC and `captured_at` with the phone's offset at the capture instant.
It strips location and device data from photos before writing them (section 9). Speech recognition and
OCR run on the phone; if a phone producer ever uses a network recognizer, it sets
`source.processing: network` (section 9). A binder picker on the phone, which sets `binder_hint`, may
offer only the binders the person marked for the phone, never one whose `disclosure` is `none`, and
that list of names is an item in the inventory of what leaves the Mac (decisions.md A7). It cannot know whether
the Mac has read anything; how the phone may ever delete its copies is an open question (section 12).
Section 5.5 covers the transport.

## 9. Privacy

A capture event may never contain:

- a dictation refused at key-down, cancelled, empty, or ending while secure input (a password field)
  is on. This is a producer rule, whether or not the producer's own history records the dictation:
  holos's History happens to skip these, but the capture hook does not depend on History (7.7, item 3)
  and must apply the same conditions itself;
- voiceprints or any voice embedding, from `profiles.json` samples or `speakers/voice/`, and
  voice-match scores or distances (holos's `provenance` for an automatic match). holos never exports
  voiceprints, and a people hint is a name plus an opaque id;
- the recognizer's vocabulary (`vocabulary.json`), word lists or correction lists: configuration, not
  captures, and full of private names;
- a bundle identifier anywhere, in `app_context.app` or under `extensions`, including inside a longer
  string. holos stores `localizedName ?? bundleID` for keystroke targets, so a producer leaves
  `app_context.app` out when the value looks like one, and never copies holos's `outcome.reason`
  sentences, which embed the same name;
- "possible" speaker suggestions or automatic-match profile ids; an automatic match's name travels
  only with `confirmed: false`;
- an email address or other contact detail in a people hint;
- screen OCR text, unless a later version adds an explicit per-capture consent;
- another binder's content, in any field;
- in a retraction, any content at all (section 3.2).

Where text was made. Speech recognition and OCR run on the capturing device. A producer that used a
network service for either sets `source.processing: network`, and the consumer shows that on the card,
because the product's first promise is that nothing leaves the Mac by default (decisions.md A7).

`app_context` is kept in the app's capture store only. It is not copied into binders, not shown over
MCP, and not given to the model; the review card may show it. An app name can be personal on its own.

Audio. Recorded audio is the person's own voice, and others' in a meeting. It travels only when the
person turns copying on, separately for dictations and meetings, and both settings are off by default.
Voiceprints and embeddings never travel.

Scope. A dictation app writes into every app, including terminals and private messages. holos sends
no dictation until the person chooses which ones (section 7.7), and dictations into a terminal only
with a separate opt-in.

Images and files. A producer strips location and device identifiers from images (EXIF GPS tags,
maker-note serial numbers) before copying them, unless the person turns that off; `bytes` and `sha256`
describe the stripped file. A shared URL loses known tracking parameters (section 8.3). A document the
person drops on purpose keeps its original bytes (section 8.2).

Sensitivity defaults: `private` for meetings (they hold other people's words, and some of them never
agreed to be recorded), documents (tax forms, court papers, statements), email, and any share that
carries a PDF, an image or a file (the same papers arrive that way, section 8.3); `unmarked` for
dictations, typed text and a shared text or URL. Section 3.3 says what `private` means. Consumers never
lower an event's sensitivity.

People hints are names plus opaque external ids in the producer's namespace. They let the consumer
recognize the same person across captures; they do not carry contact details or biometrics.

Files. Device folders are 0700 and the files a producer creates are 0600. A sync client on another Mac
may not keep those modes, which is one reason synced roots are encrypted (section 5.1). The capture
folder is a transport. When a capture is filed, the consumer writes a filed copy into each binder that
received items, in the binder's visible `captures/` folder as `captures/<captured_at>_<id>.json` with
the media beside it, before any cleanup can remove the originals, and records it with a `file_document`
op (architecture.md, section 8, step 5). The filed copy is the capture event with `app_context`
removed, with `text` cut to the sentences that binder's items came from when the items went to more
than one binder, and with `extensions.sprava.filed_from` holding the original's id and SHA-256 (the
digest the original was checked against). Media are copied as they are, checked against `sha256`;
media reused with `of` are followed to the event that holds them, and that file is copied too. A filed
capture is history that cannot be rebuilt, so it does not go under `.sprava/`, where teka-v0 section
7.2 allows only the files its table lists and rebuildable ones. That is what backups cover (decisions.md
A6). The whole capture, and the full interpretation, stay only in the app's capture store. Whether and
when ingested files may be removed from the capture folder is an open question (section 12).

`device.name` is shown to people and never defaults to the system device name or the account name
(section 4.4).

## 10. JSON Schemas

The schemas use JSON Schema 2020-12 (decisions.md F10). The files live in `docs/spec/schemas/`:

- `capture-event.schema.json`, `derived-event.schema.json`, `interpretation.schema.json`: the strict
  producer schemas, quoted below, the same bytes as the files.
- `capture-event.reader.schema.json`, `derived-event.reader.schema.json`,
  `interpretation.reader.schema.json`: the reader schemas (section 3), generated from the strict ones
  by removing every `additionalProperties: false`, opening the closed lists that have a fallback (the
  table in section 3, "Versions"), and pointing references at the reader files. They are not quoted
  here.
- `interpretation.model.schema.json`, `interpretation.binder.model.schema.json` and
  `interpretation.document.model.schema.json`: the model-facing schemas (section 6.4), quoted at the
  end of 10.3.

The derived-event schemas refer to the others by relative path, so a validator needs the schema folder
as its base URI. With `check-jsonschema`:

```
cd docs/spec/schemas
uvx --from check-jsonschema check-jsonschema --check-metaschema *.schema.json
uvx --from check-jsonschema check-jsonschema --schemafile capture-event.schema.json <event.json>
uvx --from check-jsonschema check-jsonschema --base-uri "file://$PWD/" --schemafile derived-event.schema.json <derived.json>
uvx --from check-jsonschema check-jsonschema --schemafile interpretation.schema.json <interpretation.json>
```

### 10.1 capture-event.schema.json

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:capture-event-v0:capture-event",
  "title": "Sprava capture event, format version 0",
  "description": "One immutable record of something a person captured: a dictation, a meeting, typed text, a dropped document, a shared item or a forwarded email. Written once by a producer, never modified. This is the strict producer schema; readers use the reader schema, which ignores unknown keys. See docs/spec/capture-event-v0.md.",
  "type": "object",
  "additionalProperties": false,
  "required": ["format", "format_version", "id", "hlc", "device", "source", "captured_at", "locale", "text", "sensitivity"],
  "properties": {
    "format": {
      "const": "sprava-capture-event",
      "description": "Tells a reader what kind of file this is."
    },
    "format_version": {
      "const": "0",
      "description": "The version of this format. New optional fields do not change it; a change a reader must understand does. A reader defers a version it does not know."
    },
    "id": { "$ref": "#/$defs/uuid", "description": "The event's own identity. A UUID, version 7 recommended. Never reused." },
    "hlc": { "$ref": "#/$defs/hlc" },
    "device": { "$ref": "#/$defs/device" },
    "source": { "$ref": "#/$defs/source" },
    "captured_at": {
      "$ref": "#/$defs/timestamp",
      "description": "When the capture started, by the producer's clock, with the UTC offset in force at that instant in the producer's time zone."
    },
    "captured_at_estimated": {
      "type": "boolean",
      "description": "True when captured_at is not when the content was recorded, for example the time a recording was imported. Relative dates are then left unresolved. Absent means false."
    },
    "ended_at": {
      "$ref": "#/$defs/timestamp",
      "description": "Optional. When the capture ended, by the producer's clock, with the UTC offset in force at that instant: for a dictation, captured_at plus its length; for a typed note, when it was saved. A reader treats a value earlier than captured_at as absent. A superseding event copies it from the first event of its chain."
    },
    "locale": {
      "type": "string",
      "pattern": "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$",
      "description": "The language of the text as a BCP 47 tag with hyphens, such as en-CA or fr-CA, without @ keywords. Use und when unknown."
    },
    "title": {
      "type": "string",
      "minLength": 1,
      "maxLength": 500,
      "description": "A name the producer already had for the capture: a meeting's name, a document's file name, an email subject. Optional."
    },
    "text": {
      "type": "string",
      "description": "The capture as readable text: the dictation as recorded, the labelled transcript, the typed note, the extracted or recognized text of a document. Empty for a retraction, or for a document whose text could not be extracted."
    },
    "alt_text": {
      "type": "string",
      "description": "What was heard or seen before any fixes, when it differs from text. Optional."
    },
    "media": {
      "type": "array",
      "default": [],
      "items": { "$ref": "#/$defs/media" },
      "description": "Files copied beside this event, or reused from an earlier event of the same chain. Files the producer did not copy are not listed here."
    },
    "people_hints": {
      "type": "array",
      "default": [],
      "items": { "$ref": "#/$defs/person_hint" },
      "description": "People the producer already knows are involved, as names plus opaque ids. Never voice data or contact details."
    },
    "app_context": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "app": {
          "type": "string",
          "minLength": 1,
          "maxLength": 200,
          "not": { "pattern": "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+){2,}$" },
          "description": "The display name of the app the capture was made for or taken from. Never a bundle identifier; left out when only a bundle identifier is known."
        },
        "terminal": { "type": "boolean", "description": "True when the target was a terminal." }
      },
      "description": "Where the person was when they captured. Optional."
    },
    "sensitivity": {
      "type": "string",
      "enum": ["unmarked", "private"],
      "description": "unmarked: nothing decided. private: items filed from it are redacted by default, and its text is never returned over MCP unless the person allows it for the binder it is filed into."
    },
    "binder_hint": {
      "type": "string",
      "minLength": 1,
      "maxLength": 200,
      "description": "The binder name the producer believes this belongs to, when the person said so. A hint, not a filing."
    },
    "supersedes": {
      "$ref": "#/$defs/uuid",
      "description": "The id of an earlier event this one replaces, because the source changed after that event was written."
    },
    "retracted": {
      "type": "boolean",
      "description": "True when the person deleted the underlying thing in the producer. The event supersedes the last one for the same ref and carries no text, title, media, people, app context, binder hint or extensions."
    },
    "extensions": {
      "type": "object",
      "additionalProperties": { "type": "object" },
      "description": "Producer-specific data, keyed by producer name, for example extensions.holos. A reader ignores keys it does not know."
    }
  },
  "allOf": [
    {
      "if": { "properties": { "retracted": { "const": true } }, "required": ["retracted"] },
      "then": {
        "required": ["supersedes"],
        "properties": {
          "text": { "const": "" },
          "media": { "maxItems": 0 },
          "people_hints": { "maxItems": 0 }
        },
        "not": { "anyOf": [ { "required": ["alt_text"] }, { "required": ["title"] }, { "required": ["extensions"] }, { "required": ["app_context"] }, { "required": ["binder_hint"] } ] }
      }
    }
  ],
  "$defs": {
    "uuid": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
      "description": "A UUID in lowercase hyphenated form."
    },
    "sha256": {
      "type": "string",
      "pattern": "^[0-9a-f]{64}$",
      "description": "A SHA-256 digest as 64 lowercase hex characters."
    },
    "timestamp": {
      "type": "string",
      "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]{1,3})?[+-]((0[0-9]|1[0-3]):[0-5][0-9]|14:00)$",
      "not": { "pattern": "-00:00$" },
      "description": "ISO 8601 date and time with a numeric UTC offset, for example 2026-10-06T14:03:05+02:00. Use +00:00 for UTC, never Z or -00:00. The pattern bounds each part; a reader also checks that the value is a real instant (no 30 February)."
    },
    "hlc": {
      "type": "object",
      "additionalProperties": false,
      "required": ["wall_ms", "counter", "node"],
      "properties": {
        "wall_ms": { "type": "integer", "minimum": 1000000000000, "maximum": 9999999999999, "description": "The clock's logical time in milliseconds since 1970-01-01T00:00:00Z, always 13 digits. Never behind the wall clock when stamped." },
        "counter": { "type": "integer", "minimum": 0, "maximum": 65535, "description": "Breaks ties between events stamped in the same millisecond by the same clock." },
        "node": { "type": "string", "pattern": "^[0-9a-f]{32}$", "description": "The clock's identity: the device id with hyphens removed." }
      },
      "description": "A hybrid logical clock stamp. Its string form is wall_ms as 13 digits, a hyphen, counter as 4 hex digits, a hyphen, node."
    },
    "device": {
      "type": "object",
      "additionalProperties": false,
      "required": ["id"],
      "properties": {
        "id": { "$ref": "#/$defs/uuid", "description": "Generated once per producer installation and kept. Names the folder the producer writes into." },
        "name": { "type": "string", "minLength": 1, "maxLength": 200, "description": "A display name the person chose, such as Office Mac. Never defaulted from the system device name or the account name." }
      }
    },
    "source": {
      "type": "object",
      "additionalProperties": false,
      "required": ["app", "kind", "ref", "revision"],
      "properties": {
        "app": { "type": "string", "minLength": 1, "maxLength": 100, "pattern": "^[a-z0-9][a-z0-9.-]*$", "description": "The producer's name in lowercase, such as holos or sprava." },
        "kind": { "type": "string", "enum": ["dictation", "meeting", "text", "document", "share", "email"], "description": "What kind of capture this is." },
        "version": { "type": "string", "maxLength": 100, "description": "The producer's version string." },
        "ref": { "type": "string", "minLength": 1, "maxLength": 500, "description": "The producer's own identifier for the underlying thing, verbatim. A producer with no identifier of its own mints a UUID when the capture is made and stores it with the draft, so a retry after a crash reuses it. The same ref appears again when a later event supersedes this one." },
        "revision": { "type": "string", "minLength": 1, "maxLength": 1000, "description": "The producer's version key for the underlying thing at the time of writing. Opaque: compared only for equality. For a capture that is never edited, the SHA-256 of text is enough. Two events with the same app, ref and revision are the same capture, whatever device wrote them." },
        "processing": { "type": "string", "enum": ["on-device", "network"], "description": "Where the producer turned speech or images into text. network when any network service took part. Absent means on-device." }
      }
    },
    "media": {
      "type": "object",
      "additionalProperties": false,
      "required": ["kind", "sha256"],
      "oneOf": [
        { "required": ["path", "bytes"], "not": { "required": ["of"] } },
        { "required": ["of"], "not": { "required": ["path"] } }
      ],
      "properties": {
        "kind": { "type": "string", "enum": ["audio", "image", "pdf", "video", "file"] },
        "path": {
          "type": "string",
          "minLength": 1,
          "maxLength": 300,
          "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.[a-z][a-z0-9]*(-[0-9]+)?\\.[A-Za-z0-9]+$",
          "not": { "pattern": "\\.(json|tmp)$" },
          "description": "A copied file's name in the same folder as the event: <event-id>.<slot>.<extension>. The slot is audio, image-<n>, file-<n>, <track>-<n> or, in a synced root, m<n>. Must start with this event's own id (checked by the reader). Never ends in .json or .tmp."
        },
        "of": { "$ref": "#/$defs/uuid", "description": "Reuse: the id of an earlier event of the same chain whose media entry with this sha256 holds the file." },
        "sha256": { "$ref": "#/$defs/sha256" },
        "bytes": { "type": "integer", "minimum": 0 },
        "seconds": { "type": "number", "minimum": 0, "description": "Duration for audio and video." },
        "mime": { "type": "string", "maxLength": 100, "description": "The media type, such as audio/mp4." }
      }
    },
    "person_hint": {
      "type": "object",
      "additionalProperties": false,
      "anyOf": [
        { "required": ["name"] },
        { "required": ["kind"], "properties": { "kind": { "const": "self" } } }
      ],
      "properties": {
        "name": { "type": "string", "minLength": 1, "maxLength": 200, "description": "The name as the producer knows it, or a role such as the notary. May be absent only for the person capturing (kind self)." },
        "external_id": { "type": "string", "minLength": 1, "maxLength": 300, "description": "An opaque id in the producer's own namespace, prefixed with the producer name, such as holos:profile:<uuid>. Never an email address or other contact detail." },
        "kind": { "type": "string", "enum": ["speaker", "self", "mention"], "description": "speaker: spoke in the capture. self: the person capturing. mention: named in the text." },
        "confirmed": { "type": "boolean", "description": "false when the name is a guess, such as an automatic voice match the person never confirmed. Absent means confirmed." }
      }
    }
  }
}
```

### 10.2 derived-event.schema.json

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:capture-event-v0:derived-event",
  "title": "Sprava derived event, format version 0",
  "description": "Something computed from one or more capture events or other derived events: a typed interpretation by the clerk, a summary, a proposal built from an interpretation, or the record of a filing. Immutable. This is the strict producer schema; readers use the reader schema, which ignores unknown keys. See docs/spec/capture-event-v0.md section 6.",
  "type": "object",
  "additionalProperties": false,
  "required": ["format", "format_version", "id", "hlc", "device", "kind", "created_at", "inputs", "producer", "outcome", "sensitivity"],
  "properties": {
    "format": { "const": "sprava-derived-event" },
    "format_version": { "const": "0" },
    "id": { "$ref": "capture-event.schema.json#/$defs/uuid" },
    "hlc": { "$ref": "capture-event.schema.json#/$defs/hlc" },
    "device": { "$ref": "capture-event.schema.json#/$defs/device" },
    "kind": {
      "type": "string",
      "enum": ["interpretation", "summary", "proposal", "filing"],
      "description": "interpretation: the clerk's typed reading of one capture. summary: free-text title, summary, points and action items. proposal: an op batch built by code from an interpretation. filing: what was approved and applied."
    },
    "created_at": { "$ref": "capture-event.schema.json#/$defs/timestamp" },
    "sensitivity": {
      "type": "string",
      "enum": ["unmarked", "private"],
      "description": "private when any input is private, or when the event names or targets a binder whose disclosure is none. Otherwise unmarked. Governs the derived event exactly as it governs a capture event."
    },
    "inputs": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "format"],
        "properties": {
          "id": { "$ref": "capture-event.schema.json#/$defs/uuid" },
          "format": { "type": "string", "enum": ["sprava-capture-event", "sprava-derived-event"] },
          "sha256": { "$ref": "capture-event.schema.json#/$defs/sha256", "description": "Digest of the input file's bytes, when the producer checked them." }
        }
      },
      "description": "The events this one was computed from."
    },
    "producer": {
      "type": "object",
      "additionalProperties": false,
      "required": ["tier", "app"],
      "properties": {
        "tier": { "type": "integer", "enum": [0, 1, 2], "description": "0: code only, no model. 1: an on-device model. 2: a brain connected over MCP." },
        "app": { "type": "string", "minLength": 1, "maxLength": 100, "pattern": "^[a-z0-9][a-z0-9.-]*$", "description": "Who ran it: sprava, holos, or an MCP client's name." },
        "app_version": { "type": "string", "maxLength": 100 },
        "model": { "type": ["string", "null"], "maxLength": 200, "description": "The model's name, such as apple-on-device. Null for tier 0." },
        "variant": { "type": ["string", "null"], "maxLength": 100, "description": "The model variant, such as core3 or coreAdvanced3, when known." },
        "os_build": { "type": ["string", "null"], "maxLength": 50, "description": "The OS build the model ran on, such as 26A428, when known." },
        "prompt_version": { "type": ["string", "null"], "maxLength": 100, "description": "The producer's version tag for its instructions and schema." },
        "context_size": { "type": "integer", "minimum": 1, "description": "The model's context window in tokens at the time." }
      }
    },
    "outcome": {
      "type": "string",
      "enum": ["ok", "partial", "invalid_output", "context_exceeded", "guardrail", "unsupported_language", "refused", "rate_limited", "concurrent", "unavailable", "timeout", "error"],
      "description": "ok: content is complete. partial: some of the input was skipped. The rest name why there is no usable content."
    },
    "outcome_detail": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "error_code": { "type": "string", "maxLength": 100, "pattern": "^[a-z0-9_.-]+$", "description": "A short machine code for the error. Never capture text or model text." },
        "context_size": { "type": "integer", "minimum": 0 },
        "token_count": { "type": "integer", "minimum": 0 },
        "reset_at": { "$ref": "capture-event.schema.json#/$defs/timestamp" },
        "parts": { "type": "integer", "minimum": 0 },
        "skipped_parts": { "type": "integer", "minimum": 0 },
        "dropped_items": { "type": "integer", "minimum": 0, "description": "Items the code-side checks removed, for example a quote not found in the capture." },
        "retries": { "type": "integer", "minimum": 0, "description": "Windows retried after a refusal or a guardrail." },
        "truncated": { "type": "integer", "minimum": 0, "description": "Windows whose answer was cut off at the response token cap. Their text is listed in content.unfiled with reason truncated." }
      }
    },
    "binder": {
      "type": "string",
      "minLength": 1,
      "maxLength": 200,
      "description": "For a proposal or a filing: the binder its ops target (the binder's meta.name). Absent on a not-sure proposal and on other kinds."
    },
    "content": {
      "type": "object",
      "description": "Depends on kind. For interpretation it validates against interpretation.schema.json. For summary it is title, summary, points, actions and language. For proposal and filing it follows the teka op schema, one binder per event."
    },
    "supersedes": { "$ref": "capture-event.schema.json#/$defs/uuid" },
    "extensions": {
      "type": "object",
      "additionalProperties": { "type": "object" }
    }
  },
  "allOf": [
    {
      "if": { "properties": { "outcome": { "enum": ["ok", "partial"] } } },
      "then": { "required": ["content"] }
    },
    {
      "if": { "properties": { "kind": { "const": "interpretation" }, "outcome": { "enum": ["ok", "partial"] } }, "required": ["content"] },
      "then": { "properties": { "content": { "$ref": "interpretation.schema.json" } } }
    },
    {
      "if": { "properties": { "kind": { "const": "summary" }, "outcome": { "enum": ["ok", "partial"] } }, "required": ["content"] },
      "then": { "properties": { "content": { "$ref": "#/$defs/summary_content" } } }
    }
  ],
  "$defs": {
    "summary_content": {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "summary", "points", "actions"],
      "properties": {
        "title": { "type": "string", "minLength": 1, "maxLength": 200 },
        "summary": { "type": "string", "minLength": 1, "maxLength": 2000 },
        "points": { "type": "array", "items": { "type": "string", "minLength": 1 } },
        "actions": { "type": "array", "items": { "type": "string", "minLength": 1 }, "description": "Plain strings. No assignee or due date structure; that is the interpretation's job." },
        "language": { "type": "string", "pattern": "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$" }
      }
    }
  }
}
```

### 10.3 interpretation.schema.json

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:capture-event-v0:interpretation",
  "title": "Tier-1 interpretation of one capture, format version 0",
  "description": "What the clerk read in one capture after the code-side checks: the items it found (capture variant) or the facts of one short document (document variant). The model fills the fields marked model, through the separate model-facing schema; code fills the fields marked code. See docs/spec/capture-event-v0.md section 6.",
  "type": "object",
  "additionalProperties": false,
  "required": ["variant", "language"],
  "properties": {
    "variant": { "type": "string", "enum": ["capture", "document"], "description": "Code, from the capture's source.kind and media." },
    "language": { "type": "string", "pattern": "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", "description": "The capture's locale; titles are written in this language. Code." },
    "items": { "type": "array", "items": { "$ref": "#/$defs/item" }, "description": "Capture variant: one entry per separate thing to do, pay, send, wait for or note. May be empty." },
    "unfiled": { "type": "array", "items": { "$ref": "#/$defs/unfiled_span" }, "description": "Parts of the capture text that no accepted item covers but that look actionable, or that the model refused. Shown on the review card in the capture's own words. Code." },
    "document": { "$ref": "#/$defs/document", "description": "Document variant: the facts of one short document." }
  },
  "oneOf": [
    { "properties": { "variant": { "const": "capture" } }, "required": ["items"], "not": { "required": ["document"] } },
    { "properties": { "variant": { "const": "document" } }, "required": ["document"], "not": { "required": ["items"] } }
  ],
  "$defs": {
    "date": {
      "type": "string",
      "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    },
    "binder_guess": {
      "type": "object",
      "additionalProperties": false,
      "required": ["signals"],
      "dependentRequired": { "name": ["confidence_band"] },
      "properties": {
        "name": { "type": "string", "minLength": 1, "maxLength": 200, "description": "The binder chosen by the separate binder call from the names offered, or the binder named by binder_hint. Absent when the answer was not-sure. Model (binder call) or code (hint)." },
        "from_hint": { "type": "boolean", "description": "True when the name came from the capture's binder_hint and the model was not asked. Code." },
        "signals": {
          "type": "array",
          "uniqueItems": true,
          "items": { "type": "string", "enum": ["hint", "binder_call", "index_match", "neighbours"] },
          "description": "The signals that agree with name. hint: binder_hint names it. binder_call: the model picked it. index_match: a full-text match of the item's sentence in that binder's index. neighbours: the items around it went to the same binder. Empty when there is no name. Code."
        },
        "confidence_band": { "type": "string", "enum": ["high", "medium", "low"], "description": "Computed by code from signals with the fixed table in section 6.4. Never written by the model." }
      }
    },
    "amount": {
      "type": "object",
      "additionalProperties": false,
      "required": ["value", "text"],
      "properties": {
        "value": { "type": "number", "exclusiveMinimum": 0, "description": "The amount as a number, parsed by code from text. Code." },
        "currency": { "type": "string", "maxLength": 20, "description": "As spoken or printed, such as dollars or CAD. Code, from text." },
        "text": { "type": "string", "minLength": 1, "maxLength": 200, "description": "The amount exactly as spoken or printed. It occurs in the item's sentence, or for a document in the text that was read. Model, checked by code." }
      }
    },
    "source_span": {
      "type": "object",
      "additionalProperties": false,
      "required": ["quote", "anchored"],
      "properties": {
        "quote": { "type": "string", "minLength": 1, "maxLength": 2000, "description": "The opening words of the capture sentence this came from, as the model copied them. Model." },
        "anchored": { "type": "boolean", "description": "True when code found the quote in the capture text. Code." },
        "start": { "type": "integer", "minimum": 0, "description": "Offset of the start of the sentence that holds the quote, in Unicode scalar values. Code." },
        "end": { "type": "integer", "minimum": 0, "description": "Offset just past the end of that sentence. Code." }
      }
    },
    "unfiled_span": {
      "type": "object",
      "additionalProperties": false,
      "required": ["start", "end", "reason"],
      "properties": {
        "start": { "type": "integer", "minimum": 0 },
        "end": { "type": "integer", "minimum": 0 },
        "reason": { "type": "string", "enum": ["not_covered", "refused", "guardrail", "truncated"], "description": "not_covered: no item quotes this sentence, and it holds a time expression, an amount or an action verb. refused, guardrail: the model would not read this window. truncated: the answer for this window was cut off at the response token cap." }
      }
    },
    "match": {
      "type": "object",
      "additionalProperties": false,
      "required": ["candidate", "relation"],
      "properties": {
        "candidate": { "type": "string", "minLength": 1, "maxLength": 200, "description": "The id of one of the open items offered as candidates in this call. Model, through a per-call enum; code checks it." },
        "relation": { "type": "string", "enum": ["same", "done", "update"], "description": "same: nothing new. done: the capture says the item is finished. update: the capture changes it. Model." }
      }
    },
    "item": {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "action", "people", "binder_guess", "source_span"],
      "properties": {
        "title": { "type": "string", "minLength": 1, "maxLength": 200, "description": "A short title for the item, in the capture's language. Model." },
        "action": { "type": "string", "enum": ["call", "pay", "send", "review", "wait", "file", "meet", "decide", "note", "other"], "description": "What has to happen. Not the teka item kind; code maps it (section 6.5). Model." },
        "when_text": { "type": "string", "minLength": 1, "maxLength": 200, "description": "The time expression exactly as spoken; kept only when it occurs in the quote's sentence and matches a known time pattern. Model. Never a resolved date." },
        "when_role": { "type": "string", "enum": ["due", "expected", "follow_up"], "description": "Which teka date when_resolved fills, from the words around when_text (by, until, if not by). Code." },
        "when_resolved": { "$ref": "#/$defs/date", "description": "The date code resolved when_text to, from captured_at and locale. Never earlier than the capture date. Code." },
        "people": { "type": "array", "items": { "type": "string", "minLength": 1, "maxLength": 200 }, "description": "People named for this item, as spoken; a role such as the notary is fine. Each entry occurs in the capture text as whole words and is not a pronoun or an indefinite such as someone. Model, checked by code." },
        "speaker": { "type": "string", "minLength": 1, "maxLength": 200, "description": "Meetings only: the label of the turn that holds the item's sentence. Code." },
        "amount": { "$ref": "#/$defs/amount" },
        "binder_guess": { "$ref": "#/$defs/binder_guess" },
        "match": { "$ref": "#/$defs/match", "description": "Set when a second one-task call found that this item is an open item already in the binder. Absent otherwise." },
        "source_span": { "$ref": "#/$defs/source_span" }
      }
    },
    "party": {
      "type": "object",
      "additionalProperties": false,
      "required": ["name"],
      "properties": {
        "name": { "type": "string", "minLength": 1, "maxLength": 200, "description": "As printed; occurs in the text that was read. Model, checked by code." },
        "role": { "type": "string", "maxLength": 50, "description": "sender, recipient, payer, payee, or another short role word. Model." }
      }
    },
    "deadline": {
      "type": "object",
      "additionalProperties": false,
      "required": ["when_text", "label"],
      "properties": {
        "when_text": { "type": "string", "minLength": 1, "maxLength": 200, "description": "As printed; occurs in the text that was read. Model, checked by code." },
        "when_resolved": { "$ref": "#/$defs/date", "description": "Code only." },
        "label": { "type": "string", "minLength": 1, "maxLength": 200, "description": "What the deadline is for. Model." }
      }
    },
    "document": {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "kind", "parties", "amounts", "deadlines", "binder_guess"],
      "properties": {
        "title": { "type": "string", "minLength": 1, "maxLength": 200, "description": "A title for the document. Model." },
        "date_text": { "type": "string", "maxLength": 100, "description": "The document's date as printed. Model." },
        "date": { "$ref": "#/$defs/date", "description": "The document's date, normalized. Code only." },
        "kind": { "type": "string", "enum": ["invoice", "receipt", "letter", "notice", "statement", "contract", "form", "court", "tax", "other"], "description": "Model." },
        "parties": { "type": "array", "items": { "$ref": "#/$defs/party" } },
        "amounts": { "type": "array", "items": { "$ref": "#/$defs/amount" } },
        "deadlines": { "type": "array", "items": { "$ref": "#/$defs/deadline" } },
        "summary": { "type": "string", "maxLength": 400, "description": "One sentence on what the document is. Model." },
        "binder_guess": { "$ref": "#/$defs/binder_guess" }
      }
    }
  }
}
```

The model-facing schema for the capture variant, `interpretation.model.schema.json`. It has no binder
field: the binder is picked by a separate call (section 6.4, step 2). Its `minLength` and `maxLength`
are not enforced by guided generation; they document the limits code checks afterwards.

```json
{
  "title": "Interpretation",
  "description": "The items in one capture. Copy words from the capture; never work out a date or a number.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "items"
  ],
  "x-order": [
    "items"
  ],
  "properties": {
    "items": {
      "type": "array",
      "description": "One entry per separate thing to do, pay, send, wait for, meet about, decide or note. At most six.",
      "items": {
        "$ref": "#/$defs/Item"
      },
      "maxItems": 6
    }
  },
  "$defs": {
    "Item": {
      "title": "Item",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "quote",
        "title",
        "action",
        "when_text",
        "people",
        "amount_text"
      ],
      "x-order": [
        "quote",
        "title",
        "action",
        "when_text",
        "people",
        "amount_text"
      ],
      "properties": {
        "quote": {
          "type": "string",
          "minLength": 1,
          "maxLength": 200,
          "description": "The first words of the sentence of the capture this item comes from, copied exactly, at most twelve words."
        },
        "title": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120,
          "description": "A short title for the item."
        },
        "action": {
          "type": "string",
          "enum": [
            "call",
            "pay",
            "send",
            "review",
            "wait",
            "file",
            "meet",
            "decide",
            "note",
            "other"
          ],
          "description": "What has to happen: call, pay, send, review, wait for someone else, file, meet, decide, note, or other."
        },
        "when_text": {
          "type": "string",
          "maxLength": 120,
          "description": "The time words exactly as spoken, or an empty string when there are none."
        },
        "people": {
          "type": "array",
          "description": "People named for this item, exactly as spoken. Empty when none.",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 120
          }
        },
        "amount_text": {
          "type": "string",
          "maxLength": 120,
          "description": "The money amount exactly as spoken, or an empty string when there is none."
        }
      }
    }
  }
}
```

The binder call's schema, `interpretation.binder.model.schema.json`. The `binder` enum holds invented
example names; code replaces it in every call with the names offered plus `not-sure`.

```json
{
  "title": "BinderChoice",
  "description": "Which binder one item belongs to. Choose from the list, or not-sure.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "binder"
  ],
  "x-order": [
    "binder"
  ],
  "properties": {
    "binder": {
      "type": "string",
      "enum": [
        "estate-example",
        "kitchen-reno",
        "rental-elm-street",
        "tax-2026",
        "condo-board",
        "not-sure"
      ],
      "description": "The binder this item belongs to, or not-sure."
    }
  }
}
```

The document variant's schema, `interpretation.document.model.schema.json`. Code turns `amount_texts`
into `amounts` with parsed values, resolves the dates, and checks each string against the text that was
read (section 6.4).

```json
{
  "title": "Document",
  "description": "The facts printed at the start of one document. Copy words exactly; never work out a date or a number.",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "title",
    "date_text",
    "kind",
    "parties",
    "amount_texts",
    "deadlines",
    "summary"
  ],
  "x-order": [
    "title",
    "date_text",
    "kind",
    "parties",
    "amount_texts",
    "deadlines",
    "summary"
  ],
  "properties": {
    "title": {
      "type": "string",
      "minLength": 1,
      "maxLength": 120,
      "description": "A short title for the document."
    },
    "date_text": {
      "type": "string",
      "maxLength": 60,
      "description": "The document's date exactly as printed, or an empty string."
    },
    "kind": {
      "type": "string",
      "enum": [
        "invoice",
        "receipt",
        "letter",
        "notice",
        "statement",
        "contract",
        "form",
        "court",
        "tax",
        "other"
      ],
      "description": "What sort of document it is."
    },
    "parties": {
      "type": "array",
      "maxItems": 6,
      "description": "People or organizations named as sender, recipient, payer or payee, exactly as printed.",
      "items": {
        "$ref": "#/$defs/Party"
      }
    },
    "amount_texts": {
      "type": "array",
      "maxItems": 6,
      "description": "Money amounts exactly as printed.",
      "items": {
        "type": "string",
        "minLength": 1,
        "maxLength": 60
      }
    },
    "deadlines": {
      "type": "array",
      "maxItems": 6,
      "description": "Dates by which something must happen, exactly as printed.",
      "items": {
        "$ref": "#/$defs/Deadline"
      }
    },
    "summary": {
      "type": "string",
      "maxLength": 300,
      "description": "One short sentence on what the document is."
    }
  },
  "$defs": {
    "Party": {
      "title": "Party",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "name",
        "role"
      ],
      "x-order": [
        "name",
        "role"
      ],
      "properties": {
        "name": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120,
          "description": "The name exactly as printed."
        },
        "role": {
          "type": "string",
          "enum": [
            "sender",
            "recipient",
            "payer",
            "payee",
            "other"
          ],
          "description": "The party's role."
        }
      }
    },
    "Deadline": {
      "title": "Deadline",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "when_text",
        "label"
      ],
      "x-order": [
        "when_text",
        "label"
      ],
      "properties": {
        "when_text": {
          "type": "string",
          "minLength": 1,
          "maxLength": 60,
          "description": "The date or time limit exactly as printed."
        },
        "label": {
          "type": "string",
          "minLength": 1,
          "maxLength": 120,
          "description": "What is due by then, in a few words."
        }
      }
    }
  }
}
```

### 10.4 Samples

Invented samples were written and validated with `check-jsonschema` 0.38.2 on 2026-10-06, after the
second revision:

- passing, against the strict schemas: one holos dictation event (with audio copying turned on), one
  holos meeting event (a normal recording: chunks without digests under `extensions.holos.session`, an
  automatic voice match shown as "B. Example (auto)" in the text and as a hint with
  `confirmed: false`, a default-labelled speaker with no hint, a gap reported on two tracks printed
  once, speakers kept without `provenance`), a dictation retraction, a superseding dictation event that
  reuses the first event's audio with `of`, a Sprava typed note with a minted `ref` and the digest of
  its text as `revision`, holos's summary derived event, Sprava's interpretation derived event (taking
  both the capture and the summary as inputs, each with its real digest, with `speaker`, `signals` and
  `confidence_band` on every item), an interpretation whose second window was cut off (`partial`,
  `outcome_detail.truncated` 1, an unfiled span with reason `truncated`), and one standalone
  interpretation in the document variant;
- passing against the reader schema and failing against the strict one: a phone event that adds one
  optional field to a media entry, and an event with an unknown media `kind` and an unknown
  `sensitivity`, which a reader maps to `file` and `private`;
- failing, as they should: a copied media entry without `bytes`, a media `path` ending in `.json`, a
  media `path` ending in `.tmp`, a media entry with neither `path` nor `of`, a bundle identifier in
  `app_context.app`, a `-00:00` offset, an `ended_at` without an offset (added with the field, when the
  dictation and typed-note samples gained `ended_at`), an impossible `captured_at` (`2026-02-30T25:61:61+19:99`), an
  HLC `wall_ms` of 0, a retraction that still has text, a retraction that carries `extensions` (with
  dictated text), `app_context` and `binder_hint`, a typed note without `source.ref` and
  `source.revision`, a speaker hint without a name, an interpretation item with an `action` outside the
  list, an amount with value 0, a binder guess with a model-written `confidence`, and a derived event
  without `sensitivity`. Of these, the retraction with `extensions`, the typed note without `ref` and
the impossible `captured_at` were also checked against the reader schema, and fail it too;
- the meeting sample's `source.revision` follows 7.3 (four parts joined with `|`). The dictation
  sample's revision is the real SHA-256 of its invented record's canonical form. Its audio digest and
  byte count agree with each other but describe a placeholder (81,342 zero bytes), not real audio.
- the skeptic's adversarial files now fail where they should: two typed notes without `ref` (missing
  `revision`), a retraction without `ref` (impossible `captured_at`), and a media entry that names
  another event's `.tmp` file. A dictation whose `outcome.reason` holds a bundle identifier inside a
  sentence still passes the schema; the mapping no longer copies `reason` (7.1), and CH-19 tests it.

The samples are not yet in the repository (they are drafts in the session's scratch folder); the
author decides whether they become `docs/spec/samples/`.

### 10.5 The on-device model against the interpretation schema

Checks that the interpretation is a shape the real clerk can fill. The `fm` CLI is a developer tool,
never part of the product (decisions.md P3); the product uses the same guided generation through the
Swift framework. All runs used invented text, greedy sampling, and this machine: macOS 27.0 (build
26A428), Apple M5, 16 GB, model variant AFM 3 Core Advanced, context size 8,192.

First run (the draft's own schema, a 60-word dictation about calling a notary on Thursday and a 1,200
dollar invoice). Two greedy runs gave identical content: three items with a title, kind, people, a
verbatim quote and a binder guess. The answer was 330 tokens and took about 6 s. Flaws: sentinels in
optional fields (`amount` with `value` 0 and `text` "none"), "at the end of the month" copied into an
item whose quote has none, a quote that differed only in capitalization, and the rental item guessed
into `estate-example` with confidence 0.7. The `fm` form of that schema was hand-made and differed from
10.3 (`kind` was a free string), which is why the model-facing schema is now published.

Skeptic runs (the same item shape in `fm` form, with retrieved facts in the instructions):

- Recall. An invented 538-word dictation with 18 actionable items gave 12 entries, 11 distinct, and
  silently missed 7, among them a payment instalment and its due date, a decision "until the
  fifteenth", a meeting "on the third" and a list due "by Friday". All 12 had binder confidence 1,
  including four wrong binders. Paragraph-sized calls recovered several missed items.
- Tokens and time for that capture: instructions 253, capture 612, the schema as text 655 minified,
  the answer 1,271 tokens for 12 items (about 106 per item), 2,801 for the whole saved session, and
  40.9 s wall-clock.
- The model turned two retrieved facts into new items with quotes taken from the facts.
- Sentinels: amounts "none", "", "as spoken", "no rush", "no money", "just a note", always with value 0;
  `when_text` "none", "now" and "not to the tenant"; people "someone" and "not specified". On one
  paragraph the model wrote `amount.text` "" four times although the schema it was given said
  `minLength: 1`, so guided generation does not enforce `minLength`.
- A 97-word tax paragraph was refused under guided generation, with and without permissive
  guardrails and without the retrieved facts; it was answered without a schema, and inside the longer
  capture.
- The draft's 10.3 schema given to `fm` directly fails to load ("The data couldn't be read because it is
  missing"); section 6.4 lists the rules that made it load.

Revision run (`interpretation.model.schema.json` exactly as published, apart from the test's binder
list, with instructions of 48 tokens and no retrieved facts). The schema is 412 tokens minified. The
60-word dictation gave three items in 2.6 to 3.8 s: "Thursday" and "one thousand two hundred dollars"
were copied into the right items, the furnace question was answered `not-sure`, and after code added
its fields the result validated against `interpretation.schema.json`. A first try with `when_text` and
`amount_text` optional left both out of the notary item, which is why they are required and may be
empty. A 125-word rental paragraph gave four items in 4.7 s with a 266-token answer, about 66 tokens
per item with shortened quotes; two of its four binders were `not-sure` where the right binder was
plain to a person, and its "send" items carried "the tenant" as a person, which the people check keeps
because the tenant is named in the text.

Second skeptic runs (the published schema of the first revision, with a `binder` field, on five
invented paragraphs of 100 to 140 words):

- Lengths. A saved transcript shows the schema `fm` actually used, with every `minLength` and
  `maxLength` removed and `maxItems` and `minItems` kept. One quote came back at 271 characters and 52
  words against `maxLength: 200` and "at most twelve words"; others ran 29, 17, 15 and 13 words.
- Binders, picked in the same call as the split: of 16 items, 7 right, 1 wrong (a passport renewal
  filed to `condo-board`) and 8 `not-sure`, among them every item of a paragraph that opened "Third,
  taxes." The first revision's own run saw 2 of 4 `not-sure`. This is why the binder is now a separate
  call.
- People: "someone" (the text said "someone has to be home"), "me" and a cut-off "A" all occur in the
  text, so the plain substring check kept them; check 4 now drops them.
- Time: 3.1 to 6.5 seconds per window.
- A waiting item with a bare date and no `follow_up_at`, as the first revision's table built it, fails
  `item.schema.json` ("'follow_up_at' is a required property"); 6.5 now derives it.
- Tokens, measured with `fm count-tokens`: instructions of 147 words 281 tokens, the schema as text 412,
  and a saved transcript of one window 1,174 tokens (446 instructions and text, 315 answer, about 413
  schema).

Second revision runs (this draft's schemas exactly as published, apart from the test's binder list):

- `interpretation.model.schema.json` with `maxItems: 6` and the new actions loaded and answered an
  invented 53-word paragraph in 4.4 seconds with four items: a `wait` on the property manager "next
  week", a `pay` of "four hundred and fifty dollars" with "Friday", a `meet` with "third", and a
  `decide`. The `when_text` values left out "by" and "on the", which is why prefixes are matched in the
  words before `when_text` (6.6).
- `interpretation.binder.model.schema.json` with five binders described in one line each answered in
  0.9 seconds.
- `interpretation.document.model.schema.json` on an invented seven-line invoice answered in 2.4
  seconds with the kind, both parties, the date as printed, the amount as printed and the deadline
  "30 days of the invoice date". It titled the document with the letterhead, as the skeptic's own
  document run did, so a title check (for example, not all capitals) is worth adding once fixtures
  exist.

What is not measured. Every number above comes from the 20B-sparse Core Advanced model with 8,192
tokens. The design target is the 3B Core model with 4,096 tokens on M1 and M2 Macs (decisions.md P2);
its recall, token use and latency are unmeasured. Measuring them on fixtures is a gate before the
MVP's clerk ships, because decisions.md M3 asks for a proposal within a minute of a capture landing.

## 11. Conformance checks

Each check is numbered so a test can cite it. "Must" means a failing implementation is not conformant.
CE-5 to CE-10 are checked by producer tests; a consumer shows their failures as warnings and still
ingests the file (section 5.3), except the media id prefix in CE-7, which blocks.

Capture events (CE):

1. CE-1: the file validates against `capture-event.schema.json` when a producer writes it, and against `capture-event.reader.schema.json` when a consumer reads it.
2. CE-2: `id` is a lowercase UUID; it equals the file's base name; no two files in a capture root share it.
3. CE-3: `hlc.node` equals `device.id` with hyphens removed, and `device.id` equals the name of the folder the file is in.
4. CE-4: the HLC string form of the file is 51 characters and sorts, as text, in the same order as the tuple (`wall_ms`, `counter`, `node`).
5. CE-5: `hlc.wall_ms` is not more than 60,000 ms ahead of the producer's wall clock at the time of writing, unless the producer recorded a clock skew at launch (section 4.2).
6. CE-6: `captured_at` carries a numeric offset other than `-00:00`, is the offset in force at that instant, and is not later than `hlc.wall_ms` by more than 60 seconds.
7. CE-7: every copied `media[].path` starts with the event id (a reader also blocks on this, section 5.3, check 3), names a file in the same folder, and that file's size equals `bytes` and its digest equals `sha256`; every reused entry's `of` names an earlier event of the same chain with a copied entry of the same `sha256`.
8. CE-8: an event with `supersedes` has the same `source.app`, `source.kind` and `source.ref` as the event it names, comes from the same device, has a different `id`, and has a later HLC.
9. CE-9: `app_context.app`, when present, is a display name and never matches the reverse-DNS pattern `^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}$`; no value under `extensions` matches it either.
10. CE-10: `people_hints[].external_id`, when present, starts with `source.app` followed by a colon and holds no email address, and no `people_hints[].name` is or contains an email address.
11. CE-11: `sensitivity` is `private` for every `kind` `meeting`, `document` and `email` event, and for every `share` event with media, unless the person changed that default.
12. CE-12: the producer never modifies, truncates or deletes a file after the rename in 5.2 (a test watches the folder for a change of size, mtime or inode of an ingested file).
13. CE-13: a retraction (`retracted: true`) supersedes the last event of its chain and has empty `text`, no media, no people hints, no `title`, no `alt_text`, no `app_context`, no `binder_hint` and no `extensions`.
14. CE-14: a superseding event's `captured_at` equals the first event's of its chain.
15. CE-15: `device.name` is absent or was set by the person; it never equals the system's computer name or the account name by default.
16. CE-16: no `media` entry of `kind` `image` keeps GPS tags while stripping is on.
17. CE-17: a producer's HLC never decreases across events, restarts and processes, including after a clock set back at launch, after its state file rolled back, and after the counter passes 65535 (which never makes the producer wait).
18. CE-18: an event whose text came from speech recognition or OCR that used a network service has `source.processing: network`.
19. CE-19: every event has `source.ref` and `source.revision`; a producer that retries a write after a crash reuses the same ref and revision.

Transport (CT):

1. CT-1: every file is published by an exclusive rename from a dot-prefixed temporary name in the same folder; on the producer's disk a reader never sees a partial JSON file.
2. CT-2: media files are complete before their event file appears.
3. CT-3: the consumer reads the same file twice and changes nothing the second time.
4. CT-4: the consumer ingests files in any arrival order, including an event that arrives before its media (pending, then complete) and a derived event that arrives before its input.
5. CT-5: the consumer never creates, modifies or deletes anything inside a device folder it did not produce.
6. CT-6: a file that fails schema validation or check 3 of section 5.3 is quarantined and shown on the health page, never deleted, kept out of the ingested set, and examined again when it changes and after an upgrade.
7. CT-7: a consumer restarted with an empty cursor rebuilds it from its derived events and the binders' provenance, and makes no new interpretation or proposal for any capture that already has one.
8. CT-8: device folders the producer creates are 0700, and files it creates locally are 0600 on creation.
9. CT-9: a file whose HLC and name sort below every file already ingested is still ingested.
10. CT-10: a JSON file that grows from truncated to complete while the consumer watches is ingested exactly once; a file with an unknown `format_version` is deferred, not quarantined.
11. CT-11: a capture root outside the Mac's own disk holds only encrypted files, and Sprava's own producers never write into one.
12. CT-12: two typed notes with the same text and different `ref`s are both ingested.
13. CT-13: a producer launched while another of its processes is writing a temporary file does not remove that file; only temporary files older than one hour are removed.
14. CT-14: an event that becomes the current event of a chain with filed items is handled as a change to review, whether or not it carries `supersedes`; an `approx:` event never becomes current once a producer event exists for its ref.
15. CT-15: in an encrypted root, check 4 finds `<path>.age` and checks `bytes` and `sha256` after decryption; producers there use version 4 ids and `m<n>` slots.

Derived events (CD):

1. CD-1: the file validates against `derived-event.schema.json`, with the schema folder as base URI.
2. CD-2: every `inputs[].id` names an event the consumer has, or the derived event is held as pending until it does. Its HLC is later than each input's HLC, unless that input was flagged for clock skew. Causal order comes from `inputs`, never from stamps alone.
3. CD-3: `content` is present exactly when `outcome` is `ok` or `partial`.
4. CD-4: for `kind: interpretation`, `content` validates against `interpretation.schema.json`.
5. CD-5: when a superseding capture arrives, every proposal built from the older capture that is still waiting is withdrawn and rebuilt, and ops already filed from it get a change proposal; a superseding capture with the same text produces no new interpretation.
6. CD-6: `producer.tier` is 1 or 2 whenever `producer.model` is not null, and 0 when it is.
7. CD-7: `sensitivity` is `private` whenever any input is `private`, and whenever the event names or targets a binder whose `disclosure` is `none`.
8. CD-8: `outcome_detail` and `extensions` hold no capture text, no model text and no binder content beyond what `content` holds.
9. CD-9: a retracted capture leaves no proposal waiting in the queue, and every item filed from it is offered for removal.
10. CD-10: after a retraction, the consumer holds no copy of the chain's text or media in its capture store or in any binder's `captures/`, its own derived events for the chain hold only tombstones, and the card lists what remains elsewhere.
11. CD-11: a raise of sensitivity on a chain with filed items marks the stored copies private at once and produces a change proposal that sets `redact: true` and a `kind` on each filed item.
12. CD-12: every proposal and filing event targets one binder, named in `binder`, and a binder receives no other binder's items, titles, quotes or people.

Interpretation (CI):

1. CI-1: the schemas given to the model are the three published model schemas with only the per-call enums replaced; none contains `when_resolved`, `when_role`, `date`, `anchored`, `start`, `end`, `signals`, `confidence_band`, `confidence` or any `pattern`, and the extraction schema has no binder field.
2. CI-2: after the code-side pass, every `when_resolved` and `date` is a real calendar date derived from `captured_at` and `locale` by the rules in 6.6; a fixed table of (`when_text`, `captured_at`, `locale`) to date is part of the test suite, with `en-CA` and `fr-CA` rows and a capture that crosses a daylight-saving change.
3. CI-3: every `source_span` with `anchored: true` matches the capture text at `start` and `end`, case-insensitively with whitespace collapsed, and contains the quote.
4. CI-4: every `when_text` occurs inside its item's sentence and matches a time pattern; no `when_resolved` is earlier than the capture date.
5. CI-5: every `binder_guess.name` is one of the names offered; `confidence_band` follows the table in 6.4 from `signals`; the model never wrote a confidence.
6. CI-6: no `amount` has `value` 0, every `amount.text` occurs in the capture text, and every `people` entry occurs there as whole words and is not on the locale's list of pronouns and indefinites; the observed sentinels in 10.5 ("someone", "me", "A", "not specified") are fixtures.
7. CI-7: a `capture` variant has `items` and no `document`; a `document` variant the reverse.
8. CI-8: model output plus the code fields validates against `interpretation.schema.json`; a single bad item never discards the others.
9. CI-9: no proposal is built from an item whose quote is not in the capture text.
10. CI-10: every prompt contains content from at most one binder.
11. CI-11: a window refused after the retries reaches the queue word for word as an unfiled span.
12. CI-12: an actionable sentence that no item covers appears in `unfiled` and makes the outcome `partial`.
13. CI-13: an item filed from a `private` capture has `redact: true` and a teka `kind`, unless the person changed that on the card, which the filing event records; the filed copy of a `private` capture is a document record with `redact: true`, and `read_document`, `search` and resources never return its text unless the person allowed it for that binder.
14. CI-14: every `add_item` that code builds validates against `item.schema.json`, including a waiting item with a bare date (it gets `expected_by` and a derived `follow_up_at`).
15. CI-15: a window whose answer was cut off keeps its complete items, lists the rest of its text in `unfiled` with reason `truncated`, counts it in `outcome_detail.truncated`, and makes the outcome `partial`.
16. CI-16: a second private capture about an item already filed from a private capture finds it as a duplicate candidate.
17. CI-17: in a meeting, an item said by another speaker with action `call`, `send`, `pay` or `review` becomes a waiting item on that speaker; turn headers, gap lines and marker lines never appear in `unfiled` or as time expressions.
18. CI-18: in the document variant, every deadline `when_text`, amount `text` and party `name` occurs in the text that was read.
19. CI-19: a redacted item never gets kind `other` when the table in 6.5 gives a closer kind.
20. CI-20: `source_span` offsets count Unicode scalar values; a fixture with a combining accent checks it.

holos producer (CH):

1. CH-1: a dictation refused at key-down, cancelled, empty, or ending while secure input is on produces no event, with History on and with History off.
2. CH-2: a dictation event's `text` equals the record's `text`; `extensions.holos.unwritten` equals `unwritten` when present; `extensions.holos.outcome` holds `kind` and `partial` only; `alt_text` equals `heard` unless equal to `text`; `locale` equals the normalized `language`; `app_context.app` equals `app` unless `app` matches the CE-9 pattern, in which case it is absent; `source.ref` equals the record id verbatim; `source.revision` equals the canonical-form digest of 7.1.
3. CH-3: when audio copying is on and History keeps audio, a dictation event's media file has the same bytes as the finished `History/audio/<ID>.m4a` right after the store's append; when copying is off, or History is off, no media entry has a `path`.
4. CH-4: an Update History edit produces exactly one superseding event with a new `source.revision`; Delete and Clear History produce one retraction per record.
5. CH-5: a meeting event is written only from inside a regenerate, when `filesState` reports the exports current, and its `source.revision` is the key of the document that regenerate rendered (7.3); after a crash between the edit and the export, or a people-store rename, the reconcile pass regenerates and writes an event whose key and text agree.
6. CH-6: each change of the key, title or names produces exactly one superseding event; a regeneration that changes none of them produces none; a rename alone produces one with the same key and the new title.
7. CH-7: `people_hints` contains an `external_id` only for speakers whose exported `profileID` is not null, a hint for an automatic match carries `confirmed: false`, default labels produce no hint, and a suggestion never appears.
8. CH-8: for each distinct `summary.json` (by `createdAtMilliseconds`) that was current and had no `exportsPending` when the producer wrote, there is one summary derived event, and its `inputs[0].id` is the meeting event with that `transcriptID` and names digest; Summarize Again gives a second one that supersedes the first.
9. CH-9: `extensions.holos` contains none of the files listed in 7.9, no bundle identifier and no speaker `provenance`.
10. CH-10: the developer importer runs only the four commands listed in 7.8 and never a writing command.
11. CH-11: with the capture folder on and History off, a dictation within the scope setting still produces an event; with the capture folder off, none does.
12. CH-12: two holos processes writing events at the same time never produce the same HLC stamp or two events superseding the same one.
13. CH-13: an imported meeting's event has `captured_at_estimated: true`, and with a default name its `title` is "Imported meeting".
14. CH-14: after a kill between the event's rename and the per-ref table update, the next launch finds the event on disk and records it; the table never records an event that is not on disk.
15. CH-15: a dictation finished within 5 seconds of quitting holos, and one finished while the capture root is offline, each produce exactly one event later; with History on, the launch reconcile writes them before the retention sweep.
16. CH-16: `voiceislocal history clear`, `voiceislocal session delete` and a `.holos` folder moved to the Trash in the Finder each produce retractions; a folder put back produces a new event that supersedes the retraction; `voiceislocal session import` produces an event.
17. CH-17: a record encoded by the app and the same record read back with `history list --json` give the same `source.revision`.
18. CH-18: a `transcriptionIncomplete` meeting with a readable transcript produces an event marked `partialTranscript`; in a labelled meeting, a turn with no speaker is rendered "Unknown speaker", never "Microphone".
19. CH-19: no string under `extensions.holos` contains the target app's name or bundle identifier, including for a dictation whose holos `outcome.reason` names it.

## 12. Open questions

1. Is adding the capture folder feature to holos in scope now, and who writes it? Section 7.7 is the
   work list. Until then only the developer importer exists, with a sweep deadline.
2. Fixtures. No holos data exists on the drafting Mac, so no real `dictations.jsonl` line, `.holos`
   folder or export was checked. A few sanitized or synthetic fixtures from the author (dictation lines,
   one meeting folder's exports, a people file without voiceprints) would turn 7.1 to 7.5 from code
   reading into tests.
3. Where the capture root lives by default, and whether several roots (local plus synced) are watched
   from day one.
4. Cleanup. The producer never deletes. May the consumer offer "remove ingested captures older than N
   days" from the capture folder, with consent, once their copies are in the binders, and should the
   folder be excluded from Time Machine as holos excludes its people store?
5. Meeting audio: not copied (this draft), or copy a 16 kHz render when the user asks, at the cost of
   backup size? Is a way to request audio from the producer later wanted at all?
6. The call plan, with architecture.md 5.3. The window size is settled: both documents use windows of
   about 100 to 150 words. Long meetings are still open: read turns in windows with `partial`
   outcomes (this draft's default for any capture above about 150 words), or read the producer's action
   items one at a time with the turns around them and file the transcript as a document? architecture.md
   5.3 takes the second option, with the first 6 windows marked `partial` when holos supplies no action
   items. Measure both on fixtures, on the 3B model, against the 60-second budget.
7. The "next week" rule and the first day of the week per locale; `en-CA` calendars start on Sunday,
   this draft says Monday. The French rule table in 6.6 needs a French speaker's check.
8. Should `amount` become structured enough for a ledger, or stay a note on the op until `ledger/`
   has a JSON form (decisions.md F7 leaves it opaque)?
9. `heard` as `alt_text`: useful for fixing misrecognitions in the queue, but it is the rawest text
   holos has. Keep, or drop to shrink what travels?
10. Ukrainian and other unsupported locales produce `unsupported_language` outcomes until the
    open-model fallback exists (decisions.md P8). Does that change the MVP?
11. Should Sprava's own derived events ever be written into the capture folder (for a second
    consumer, or for the author's terminal agents), or only into Sprava's own store and the binders?
12. Does the consumer verify media digests on every ingest, or only when asked? Hashing a copied audio
    file is cheap; a copied hour-long video is not.
13. Fields added beyond decisions.md C1: `title`, `captured_at_estimated`, `ended_at` (added for the MVP's one-minute measure), `retracted`, `source.ref`
    and `source.revision` (both required, so that the dedupe triple in 5.4 never compares absent
    values), `source.processing`, a `confirmed` flag on people hints, a reuse form for media (`of`),
    and `sensitivity` and `binder` on derived events. A second real producer (the phone app) will test whether `extensions` is enough beyond
    these. Should C1 be updated to list them?
14. Decisions.md C4 says dictation audio is copied before the retention sweep. This draft keeps that
    timing but makes copying an opt-in that is off by default, because audio is voice data and the
    clerk reads only text. The author should confirm or override.
15. Decisions.md C4 fixes the meeting version as (transcriptID, runID, edits generation, names
    digest). This draft keeps the four parts, takes the names digest from the document holos just
    rendered (never computed live), and writes the edits generation as a byte length. Two changes were
    proposed. A skeptic proposed the shorter key `<transcriptID>:<namesDigest>`, with run and edits as
    information only, because two of the four parts can change while the text stays the same. A second
    skeptic proposed a fifth part, the SHA-256 of the rendered `text`, so that "same key, same text"
    holds by construction rather than by where the key is computed. Should C4 be narrowed, widened, or
    kept?
16. Decisions.md C2 says the producer never deletes. After a retraction, the earlier event files of the
    chain, with their text, and the copied audio stay in the capture folder until cleanup (question 4).
    Should a producer be allowed to delete the event files and media of a chain it retracted, as the
    only exception to CE-12? The consumer already forgets its own copies and turns its own derived
    events for the chain into tombstones (section 3.2), a narrow exception to the immutability of
    derived events (decisions.md C3) that the author should confirm.
17. Decisions.md P7 names two importer commands. The importer also needs `session list` (to find
    meetings) and `people list` (for `isSelf`), and reads `History/audio/` when audio copying is on.
    Log these as a decision, or drop them and accept a weaker importer?
18. Synced roots: the per-file encryption framing (one age file per event or medium, the recipient's
    key management, what the phone holds), and whether a phone may delete its copies once the Mac has
    filed them. That needs an acknowledgement file the Mac writes, which is a scoped exception to CT-5,
    or a separate acknowledgement folder.
19. `when_role` is computed by code from prefixes. A model field for it, or a second `follow_up_text`,
    might read "if not by the end of the month, chase them" better. Measure on the 3B model before
    adding one.
20. Should holos gain a per-dictation and per-meeting "private" toggle (section 7.7, item 7), and
    should a person be able to lower the meeting and document defaults to `unmarked`?
21. Crypto-shredding. After a retraction the text still survives in the capture folder, in each binder's
    op log as titles, and in backups until they are pruned (section 3.2). Encrypting each capture's text
    under its own key, and deleting the key on retraction, would make every remaining copy unreadable,
    a pattern the research describes ("Encrypt personal data in events by using a per-subject key.
    Delete the key to render the data unrecoverable"). It touches decisions.md A6 (per-binder keys are
    designed and deferred) and C2. Worth designing now, or with per-binder keys?
22. Span units. Settled: this draft counts `source_span` offsets in Unicode scalar values, and teka-v0
    section 6.5 and its `op-batch.schema.json` now count `spans` the same way, half-open.
23. Settled in `docs/architecture.md`: its section 8, step 5, its file table in section 2.3 and its
    open question 8 now follow section 9, a per-binder copy in the visible `captures/` folder without
    `app_context` and with only that binder's sentences. `docs/mvp.md` defers that copy for the MVP
    (its section 4 and section 8, question 9).
24. Changes the sibling documents ask of this draft, not yet made here:
    - The duplicate call's relation gains `related` (an `add_item` linked to the candidate), and code
      accepts `update` and `done` only on stated evidence (architecture.md 5.3, section 8 step 4, open
      question 41). `interpretation.schema.json` still allows only `same`, `done` and `update`.
    - Two more code checks in 6.4: a time-word check and a number check (architecture.md 5.3, open
      question 37). Also the six-item rerun rule, the first-block rule for documents with code
      scanning the rest, and the meeting bound (open question 41).
    - Section 6.5 copies a dropped document into the binder's `intake/` before proposing it, where a
      terminal agent's digest could file it unapproved. architecture.md 7.3 and open question 42 ask to
      hold the file in the app's capture store until approval.
    - The private marker on a filed capture. Section 3.3 and CI-13 record the filed copy as a document
      with `redact: true`, but teka-v0 section 4.3 gives documents no `redact` field. architecture.md
      7.3 and open question 10 ask teka-v0 for `documents[].sensitivity: private` instead. One name
      must be chosen for both drafts.
    - Audio of a capture whose items went to more than one binder. architecture.md section 8, step 5,
      keeps it in the app's capture store and copies it into no binder; section 9 here copies media
      as they are.
    - The developer importer. `docs/mvp.md` runs it every minute from the installed app's runtime,
      behind a hidden developer setting, with an absolute path to `voiceislocal`; section 7.8 says a
      developer build with `voiceislocal` on the `PATH` (mvp.md section 8, question 9).
