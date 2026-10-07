# teka v0: the open binder format

Status: v0 draft of 2026-10-06, revised twice the same day after two design-skeptic reviews. Nothing here is final. The draft follows `docs/decisions.md` and cites its entries, for example "(decisions.md F3)". Where it adds a rule that no decision covers, it says so, and section 12 lists those additions for the author. Every example in this document is invented.

## 1. Scope, status and versioning

### 1.1 What this document covers

A teka is one folder on disk that holds everything about one episode of a person's life: an estate to settle, a kitchen renovation, a tax year, a rental property. This document says what must be inside that folder for a program to read it, change it safely and hand parts of it to other programs. It covers:

- the folder layout (section 3);
- `catalog.json`, the one file that states what is true now, and how to write it safely (section 4);
- the meaning of the fields: deadlines, waiting, nudges, recurrence, redaction, ids and closing (section 5);
- the typed operations ("ops") through which every change is made, the log that records them, undo and forgetting (section 6);
- the files that are derived from the catalog (section 7);
- an optional federation profile for sharing a redacted summary of a teka with a cross-binder view (section 8);
- how an existing teka made with lifeproj is adopted without loss, and what lifeproj must change to coexist (section 9);
- JSON Schemas (section 10), conformance checks (section 11) and open questions (section 12).

The format was extracted from lifeproj, the Python command-line tool the author has used for months (lifeproj v0.12.0; its 149 tests passed on Python 3.14.7 on 2026-10-06). lifeproj is public, so every lifeproj reference below names a file and a function or test in its repository. lifeproj enforces less than its prose says. Only the rules that lifeproj's code checks are treated as proven; the rest of this document adds rules and says so where it does.

Two implementations are expected: Sprava, the Mac app, and lifeproj, which becomes the second implementation of this format rather than a dependency of Sprava (HANDOFF.md, "Constraints to plan around"). Today lifeproj writes no op log and knows none of the v0 additions. In the terms of section 1.6 it is a catalog writer, and section 9.8 lists what it must change before it can safely share a teka with a full implementation.

### 1.2 Status

This is a v0 draft. A draft may change in ways that are not backward compatible until v0 is declared final. The date in the status line identifies which draft a file was written against. A catalog written by this draft carries `meta.format_version: "0"`. When v0 is final, files written by earlier drafts may need a `migrate` op (section 6.3), and the op records what changed.

### 1.3 How versions evolve

- The version lives in `meta.format_version` of `catalog.json` as a string of digits (decisions.md F6). lifeproj's `meta.schema_version` (the integer 2) stays beside it, because lifeproj's checker reads that key and nothing else (section 9).
- Within one version, changes are additive only. A later writer of version 0 may add optional fields, optional arrays and new optional files under `.sprava/`. It may not remove a field, change a field's type or meaning, or add a value to a closed list.
- Closed lists are frozen within a version. A closed list is every `enum` in the schemas of section 10: among them `status`, `priority`, the item's `kind`, `disclosure`, actor kinds, op types, proposal states, `id_scheme`, `recurrence.freq`, `lifecycle` and the closure actions `done` and `dropped`. Adding a value to one, a new op type included, is a version bump. The value `other` in the item's `kind` is the escape hatch for that list.
- Slices and outbox files (section 8) are versioned on their own, in their own `format_version`. lifeproj's unversioned files count as version 0 of those, and this document defines version 1. So a v0 catalog publishes a v1 slice.
- Readers preserve what they do not understand. Every writer that rewrites `catalog.json` writes back every field and every top-level array it did not understand, unchanged, in the order it found them (decisions.md F2, F10).

### 1.4 What a reader does with a newer version

- `catalog.json` with a `format_version` the reader does not know: the reader may display the catalog and must not write to the teka, not even `DASHBOARD.md`. It tells the user that a newer implementation is needed.
- `catalog.json` at an unknown catalog level (section 9.6): the same.
- A slice or an outbox file (section 8) with a `format_version` the reader does not know: the reader uses only the frozen lifeproj fields and ignores everything else. Those files are additive by rule.
- An op log (section 6) that contains an op type the reader does not know: the log was written by a newer version, because op types are a closed list. The reader stops replaying at that op, does not append to the log, and reports the op type. History cannot be skipped.

### 1.5 Licence of this document (proposed)

The author has not decided the licences (decisions.md L1, L2). The recommendation this draft follows: the prose of the specification under CC-BY-4.0; the JSON Schemas, validators and conformance tests under Apache-2.0; and an explicit note that no trademark rights in the names "Sprava" or "teka" are granted (decisions.md L2). The repository is LGPL-2.1 today.

### 1.6 Conformance classes

An implementation claims one of three nested classes, and may add the optional federation profile. Each check in section 11 is tagged with the class it applies to. The words "must" and "never" state requirements. "Should" states a recommendation that an implementation may depart from for a stated reason. "May" states a permission.

- **Reader** `[R]`: parses catalogs at every catalog level, classifies the teka's state (section 9.6), computes buckets (section 5.2) and writes nothing inside the teka. A view of a teka is a reader.
- **Catalog writer** `[W]`: a reader that also rewrites `catalog.json`. It follows the preservation rule (section 4.7), the JSON conventions (section 4.8) and the write protocol with its lock (section 4.9). It keeps no op log. When a full implementation manages the same teka, every write by a catalog writer is recorded there as an external edit (section 6.7). A catalog writer claims `[W]` for the catalog levels it supports. To claim it for v0, it must keep the v0 record rules whenever it edits a stamped v0 catalog; checks tagged `[W, v0]` apply only to that claim. Today's lifeproj is a catalog writer for lifeproj v1 and v2 catalogs only. It implements the pre-v0 federation behaviour that section 8 extends, and section 9.8 lists what it needs before it can share a v0 teka.
- **Full implementation** `[F]`: a catalog writer that makes every change as an op, keeps the op log (section 6), absorbs external edits, handles proposals, renders `DASHBOARD.md` (section 7.1) and adopts lifeproj tekas (section 9). Sprava is a full implementation.
- **Federation profile** `[P]`: optional for a catalog writer or a full implementation. It publishes slices and drains outboxes as section 8 says.
- **Slice reader** `[H]`: a program outside every teka that reads slices and writes completions, such as the hub or an app's cross-binder view. It never writes inside a teka. Section 8.4 states its rules.

A check tagged `[R]` applies to readers, catalog writers and full implementations. One tagged `[W]` applies to full implementations too. `[P]` and `[H]` stand apart from the three nested classes.

## 2. Terms

Each term is defined once here and used with that meaning everywhere below.

- **teka**: one folder for one life episode, laid out as this document describes. The word is the lowercase format term; it is never an app name (decisions.md P11).
- **binder**: the same thing as a teka, in product language. The app shows "binders". Normative text in this document says "teka".
- **catalog**: the file `catalog.json` at the root of a teka. It states what is true now: which documents exist, which items are open, and the processing log of what happened. It is the truth of state (decisions.md F1).
- **catalog level**: which set of rules a catalog follows. There are three: lifeproj v1 (`meta.schema_version: 1`, loose items), lifeproj v2 (`schema_version: 2`, lifeproj's strict item rules) and teka v0 (`meta.format: "teka"`, this document). Section 9.6 says how the level is read.
- **checker version**: which copy of lifeproj's validator `catalog_check.py` a teka holds: gen1, gen2 or gen3 (section 9.2). It is unrelated to the catalog level.
- **item**: one entry of the catalog's `open_items[]`: a thing to do, decide, pay, send or wait for.
- **document**: one entry of the catalog's `documents[]`, pointing at a file inside the teka.
- **processing log**: the catalog's array `processing_log[]`. It is append-only. One entry of it is a **log entry**.
- **op**: a typed, validated change to the catalog, for example "add this item" or "close that item". A full implementation makes every change to a catalog as an op. Ops are recorded in the op log, which is the truth of history (decisions.md F1).
- **op log**: the file `.sprava/ops.ndjson`, one applied op per line. NDJSON means newline-delimited JSON: each line is one complete JSON object. The op log and the processing log are different things; this document never says "the log" alone.
- **content hash**: the SHA-256 digest of a catalog's canonical form (section 4.8). Two catalogs that hold the same JSON value have the same content hash, however they are indented.
- **date**: a calendar day written `YYYY-MM-DD`, for example `2026-10-06`. Dates in this format carry no time zone.
- **timestamp**: a moment written `YYYY-MM-DDTHH:MM:SSZ`, an RFC 3339 date-time in UTC with the `Z` suffix and no fraction, for example `2026-10-06T14:03:11Z`. Every timestamp a v0 implementation writes has this form. A timestamp becomes a local date by converting it to the user's time zone and taking the date part.
- **transaction guard**: the check a full implementation runs before it applies an op: it applies the op to a copy of the catalog and refuses it if it would add a rule violation (section 6.3).
- **proposal**: a batch of ops that someone or something suggests and that the user has not yet approved. A proposal is applied as a whole or not at all.
- **review queue**: the list of proposals waiting for the user. Each is shown as a **review card** with approve, edit and reject (decisions.md A5).
- **actor**: who made or proposed an op: the user, the on-device clerk, an add-on brain, the implementation's own bookkeeping, or something outside the implementation.
- **Tier 0, Tier 1, Tier 2**: the app with no model, with the on-device clerk, and with an optional brain (decisions.md P1).
- **clerk**: the on-device model that proposes small changes from one capture at a time (Tier 1). A **brain** is an optional outside agent that connects over MCP, the Model Context Protocol through which outside agents talk to local tools (Tier 2). Both only propose.
- **capture event**: one immutable record of something the user captured, such as a dictation, in the separate capture-event format (decisions.md C1).
- **interpretation**: the clerk's typed reading of one capture event, from which code builds a proposal (decisions.md C3).
- **digest**: a working session in which pending intake is filed and the catalog is brought up to date, by a person, a terminal agent or the clerk. The term comes from lifeproj's manuals.
- **survey**: the read-only inspection of a teka that starts adoption. It records counts and kinds of problems, never personal values (section 9.2).
- **registry** and **fleet commands**: lifeproj keeps a list of the tekas it manages, its registry. Its fleet commands, such as `lifeproj drain --all`, act on every teka in that list.
- **doctor**: a check an implementation runs on demand over its tekas and reports on, without changing anything (decisions.md A9).
- **derived file**: a file computed from the catalog: `DASHBOARD.md`, the index, the cursors.
- **Now page**: the app's view of one teka's buckets (section 5.2). The **roll-up** is the cross-binder view of several tekas at once.
- **slice**: the redacted summary of a teka's open items that the teka publishes for a cross-binder view, as `inbox/<teka>.agenda.json` on the spool.
- **spool**: a shared folder outside every teka through which tekas and the cross-binder view exchange slices and completions. Neither side reads the other's files; they read the spool.
- **completion**: a note from the hub that an item was done or dropped, left in the outbox on the spool. To **drain** is to apply the waiting completions to the catalog (section 8.3).
- **alias**: a neutral id published in a slice in place of an item id that could spell out the item's subject (section 5.6).
- **external change**: any op whose actor is `external`: an edit of `catalog.json` by another program, recorded afterwards, or a completion drained from the hub. The app shows each one so the user can undo it. An **external edit** is the first kind only (section 6.7).
- **hub**: the existing cross-binder view that reads slices from the spool and writes completions back. Its codename is not a public product name (decisions.md P11). This document says "the hub" except where it quotes lifeproj's file names, environment variables and wire values, such as `osavul.py` and `$OSAVUL_SPOOL`.
- **federation profile**: the optional part of this format (section 8) that an implementation supports when it publishes slices and drains completions. A teka that never publishes is still a valid teka.
- **implementation**: any program that reads or writes tekas according to this document, in one of the classes of section 1.6. Sprava and lifeproj are the two expected ones.
- **module**: an optional part of a teka that adds folders, files or catalog arrays, such as `chapters` or `ledger` (section 3.3).
- **disclosure**: the setting in `meta` that says how much of a teka a reader outside it may receive: everything, titles, only kinds, or nothing. Section 5.5 defines it for slices. decisions.md A4 also uses it to bound what an MCP call may return; how it combines with per-client scope is for the architecture document. `DASHBOARD.md` and `.sprava/` are never served over MCP.
- **kind**: a word from a short closed list that says what type of thing an item is without saying what it is about, so a redacted item can still be triaged. This document writes "the item's `kind`" for that field and "disclosure level `kind`" for the disclosure setting of the same name.
- **teka states**: ready, needs migration, needs attention, corrupt, unknown level and not a teka. Section 9.6 defines them.
- **today**: the local calendar date in the user's time zone at the moment a rule is evaluated.

## 3. The folder spine

### 3.1 Required files

A folder is a teka when it contains a file named `catalog.json`. This is lifeproj's own test: its fleet commands skip a registered folder without `catalog.json` as "not a lifeproj teka" and report a broken one as an error (`osavul.py`, `_drain_teka`; tests `test_drain_all_skips_unmigrated`, `test_drain_all_errors_on_broken_catalog`). The file must parse as a JSON object; otherwise the teka is corrupt (section 9.6). An object without a `meta` object, or whose `meta` has no `schema_version`, is still a teka: it is a pre-lifeproj catalog that needs migration (section 9.6). lifeproj's `publish` and `drain` read such a file too, and fall back to the folder name for the teka's name (`osavul.py`, `teka_name`). lifeproj's manual says the format grew out of a hand-made catalog that predates lifeproj (`docs/DESIGN.md`), so such files exist.

The teka's name is `meta.name`, and it must equal the folder's basename (decisions.md F6). The comparison is byte equality after both are normalized to Unicode NFC, and it is case-sensitive. lifeproj accepts any name except an empty one, `.`, `..` or one containing `/` (`cli.py`, `cmd_new`), so spaces occur. A v0 implementation that creates a teka uses only lowercase ASCII letters, digits and hyphens, starting with a letter or a digit (`^[a-z0-9][a-z0-9-]*$`), because the name becomes a prefix of ids and a file name on the spool. A name found at adoption that does not have this shape is accepted and reported. New ids in such a teka use a cleaned-up form of the name (section 5.6).

When the folder's basename and `meta.name` differ, for example after the folder was renamed in Finder, the teka needs attention (section 9.6). It stays readable and accepts ops, but it publishes and drains nothing until the user applies a `rename_teka` op, a direct action in the app (sections 6.3 and 6.5). Publishing and draining also require the name to be unique among the tekas an implementation knows, after case folding and NFC. The comparison includes every unexpired former name of those tekas (`meta.former_names`, section 8.3): a teka may not be created with, or renamed to, a name another teka still drains under. APFS volumes are case-insensitive by default, so `Tax-2026` and `tax-2026` would share one spool file.

When an implementation creates or adopts a teka, it reports whether the folder lies in a place a sync service uploads (section 9.2 step 14).

### 3.2 Optional files and folders with a defined meaning

| Path | Meaning | Who writes it |
| ---- | ------- | ------------- |
| `catalog.json` | The catalog (section 4). Required. | Writers, under the write protocol (section 4.9). |
| `DASHBOARD.md` | Current truth rendered for reading (section 7.1). Its Notes section, from the line `## Notes` to the end, is kept as written. | A full implementation, once the user has approved the switch from a hand-kept dashboard. |
| `.teka.lock` | The lock file of the write protocol (section 4.9). Empty. | Created by the first writer; never deleted. |
| `.sprava/` | The op log, proposals, index, cursors and saved copies (section 7.2). | Owned by the full implementation that adopted the teka. Its files are untrusted when read (section 7.2). |
| `intake/` | A transient drop zone. A file in it means "not yet filed". Empty after a digest. The exception is the old email-intake layout of section 3.3: `.env` and `state.json` under `intake/mail/` are never filed. | People and capture tools put files in; filing moves them out. |
| `intake/_converted/` | Text extracted from dropped scans and PDFs. Regenerable. | An implementation. May be cleared at any time. |
| `README.md` | A human "start here" page. Informative. | A person. Never touched by an implementation. |
| `CLAUDE.md`, `AGENTS.md` | Operating manuals for terminal agents. Informative, not format (decisions.md F9). | A person or a terminal agent. Never touched by an implementation. |
| Document folders | Any other folder that holds filed documents, for example `documents/`, `correspondence/`, `quotes/`. Names are free. | Filing creates new files in them. No implementation changes or removes a file already there. |

Section 9.7 is the one statement of what an implementation may write.

### 3.3 Module folders and files

lifeproj adds these on request (`modules.py`). `meta.modules[]` lists which ones a teka uses (section 4.2). `ledger/`, `timeline.md` and `chapters/` are folder conventions in v0: described here, left opaque and never written by an implementation (decisions.md F7). This draft leaves `entities/` and `sources/` alone too (section 9.7). `correspondence/` is a document folder: filing may create new files in it.

| Module | Adds | State kept where |
| ------ | ---- | ---------------- |
| `email-intake` | `intake/mail/`, `scripts/mail/` (a mail puller's configuration and sync state), `correspondence/` | Filed threads under `correspondence/<thread>/`. |
| `docs-intake` | `intake/_converted/` | Nothing in the catalog. |
| `github-source` | `sources/` with `sources/github.toml` | Pulled metadata under `sources/`. |
| `timeline` | `timeline.md` | A Markdown table `Date, Event, Source, Notes`, newest last. |
| `ledger` | `ledger/` with `ledger/README.md` | Typed transactions as files under `ledger/`; the file format is the teka's own. |
| `chapters` | `chapters/`, `chapters/_past/` | One subfolder per finite episode (for example a tenancy); the active ones are listed in `meta.active_chapters`. |
| `entities` | `entities/` and the catalog array `entities[]` | One row per comparable thing (a candidate, a unit, a vendor bid) plus a subfolder. |

The old email-intake layout. Tekas made by lifeproj 0.1.0 (commit `b950006`) keep the mail puller's credentials at `intake/mail/.env` and its sync watermark at `intake/mail/state.json`, because that release's manual ran the puller from inside `intake/mail/`. A later commit (`7d625cf`) moved both to `scripts/mail/`, so a routine clearing of the intake would not lose them, and no lifeproj command migrates an old teka. An implementation therefore never files, indexes, shows to a model or clears a `.env` or `state.json` under `intake/mail/`. The survey reports them (section 9.2 step 12).

### 3.4 What is format and what is not

The following may be present and must be tolerated, ignored and never executed by an implementation (decisions.md F9):

- `CLAUDE.md` and `AGENTS.md` (manuals; informative);
- `.claude/` and `.agents/` (terminal-agent configuration, skills and hooks);
- `catalog_check.py` (lifeproj's copied-in validator; three checker versions exist, section 9.2);
- `scripts/` (bespoke automation);
- `.git/` (tolerated and ignored; whether git history counts as provenance is open, decisions.md F12);
- any file an implementation does not recognise.

An implementation never runs a hook, a script or a validator found inside a teka. It validates with its own rules (section 10).

Running is only one way a file can act, so an implementation also follows these rules:

- It reads as data only `catalog.json`, the files that `documents[]` names, `intake/` and `DASHBOARD.md`. Indexing, search, a model's context and MCP reads never cover `scripts/`, `.claude/`, `.agents/`, `.git/`, `.sprava/`, a file named `.env`, `.env.*` or `state.json` under `intake/mail/`, or a key file. A key file is any file whose name matches `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`, `id_ecdsa*`, `id_ed25519*`, `*.age`, `age-identity*`, `.netrc`, `credentials*`, `token*.json` or `*.keychain*`. A match is excluded even when `documents[]` names the file. The email-intake module keeps a mail puller's configuration and state in `scripts/mail/` (`modules.py`), so credentials can sit inside a teka.
- Text from a teka is data for any model, never instructions. That covers `CLAUDE.md`, `AGENTS.md`, filed emails and item titles.
- It never hands a file that can launch something to the system's default handler without a warning. The test uses the file's type as macOS sees it (its uniform type identifier), never the extension alone: anything that conforms to `public.executable`, an application bundle, a script, an installer package, a disk image, a shortcut or a location file (`.webloc`, `.fileloc`), and any file with the executable bit set, which Terminal would run.
- Any view of teka content, a filed email or a Markdown document included, loads no remote resource: it renders without network access or blocks every `http` and `https` load. It never follows a link on its own. A remote link is shown as text the user can choose to open. A remote image in a filed email would otherwise tell the sender that the mail was read, and from which address.
- Filing keeps a file's extended attributes, including `com.apple.quarantine`, which Gatekeeper relies on.
- If git history is ever read (decisions.md F12), it is read without running the repository's configuration or hooks, for example with a read-only library.

An implementation never deletes an original. Filing moves files out of `intake/`; nothing else moves or removes a file, except that `intake/_converted/` may be cleared.

### 3.5 An invented example tree

```
~/binders/estate-example/
  catalog.json
  DASHBOARD.md
  README.md
  CLAUDE.md                    manual for terminal agents (informative)
  AGENTS.md                    bridge for another agent (informative)
  catalog_check.py             lifeproj's validator (ignored, never run)
  .teka.lock                   lock file of the write protocol (empty)
  .sprava/
    ops.ndjson                 the op log
    proposals/
      019a0f53-0a1b-7c2d-8e3f-4a5b6c7d8e9f.json
    adopted/
      catalog.json             the catalog as found at adoption, byte for byte
      DASHBOARD.md             the dashboard as found at adoption
    snapshot.json              catalog as of the last op (rebuildable)
    cursors.json               cursors (rebuildable)
    index.sqlite               search index (rebuildable)
  intake/
  intake/_converted/
  documents/
    2026-08-20_will-certified-copy.pdf
  correspondence/
    notary/
      2026-09-28_inventory-request.pdf
  ledger/
    README.md
    2026-09_estate-account.csv
  timeline.md
  .claude/                     terminal-agent configuration (ignored)
  .agents/                     terminal-agent configuration (ignored)
  scripts/                     bespoke scripts (ignored, never run)
```

### 3.6 Containment

Every path in this format is relative to the teka folder and must stay inside it. A relative path can still leave the folder through a symbolic link (a symlink: a file that points at another path). So an implementation:

- resolves the real path before it reads, hashes, indexes, serves or moves a file, and refuses anything that resolves outside the teka;
- opens files without following symlinks where macOS allows it (`O_NOFOLLOW`, or `O_NOFOLLOW_ANY` for every part of the path);
- treats the teka as needing attention when `catalog.json`, `DASHBOARD.md`, `.teka.lock` or `.sprava/` is a symlink, or is not a regular file or folder, and writes nothing until that is fixed;
- creates temporary files exclusively (`O_CREAT|O_EXCL`) under a random name that starts with `.` and ends with `.tmp`, never at a fixed name. The dot keeps a temporary file on the spool from being read as a slice. lifeproj's fixed `.catalog.json.tmp` is a known gap (section 9.8).

## 4. catalog.json

### 4.1 Top-level shape

`catalog.json` is a JSON object. A fresh lifeproj teka has exactly four keys, `meta`, `documents`, `open_items` and `processing_log`, plus `entities` when the entities module is on (`scaffold.py`, `build`). Any other top-level key is allowed and must be preserved. In a lifeproj catalog a missing core array means "empty"; lifeproj's checker fills a missing one with `[]` rather than reporting it (`templates.py`, `CATALOG_CHECK`). In a stamped v0 catalog the three core arrays are required, and a missing one is a rule failure that a proposal repairs. A core key that holds something other than an array, for example `documents` as an object keyed by id, which lifeproj's checker skips, makes the catalog need migration (section 9.6).

Every top-level array of objects obeys one generic rule: among entries that carry an `id`, ids are unique within the array (`templates.py`, `main`). An entry without an `id` is unconstrained by this rule, and lifeproj's checker skips an array that holds anything other than objects. Two ids are the same when they have the same JSON type and the same value (section 5.6). A duplicate in `open_items[]`, `documents[]` or `processing_log[]` is a rule failure (section 9.6). A duplicate in an array this document does not define is reported and never blocks reading or writing.

### 4.2 `meta`

| Field | Type | Required | Rule |
| ----- | ---- | -------- | ---- |
| `schema_version` | integer | yes | lifeproj's level marker. `2` means lifeproj's strict item rules apply; `1` is legacy (section 9). A v0 catalog has exactly the integer `2`. lifeproj's checker tests for an integer, so it reads a digit string such as `"2"`, or `2.0`, as legacy. Writers never write either. |
| `name` | string | yes in v0 | Equals the folder basename (section 3.1). lifeproj falls back to the folder name when `name` is absent; the adoption migration adds it. Changed only by `rename_teka`. |
| `domain` | string | no | Free text. lifeproj's starter offers `general`, `legal`, `tenancy`, `condo`, `product`, `tax`. Default `general`. |
| `lifecycle` | `ongoing` or `finite` | no | Whether the episode ends on a deliverable. Carried into the slice. |
| `created` | date | no | `YYYY-MM-DD`, the day the teka was made. |
| `next_doc_id`, `next_item_id` | integer | no | Stamped by lifeproj, never read or incremented by any lifeproj code. Preserved, never trusted (section 5.6). |
| `profile` | object | no | Stamped as `{}` by lifeproj, never read. Preserved. |
| `active_chapters` | array of strings | no | The active chapters (0, 1 or many). lifeproj also accepts a bare string and reads `current_chapters` as a fallback; `active_chapter` (string or null) is the single-chapter legacy form. Writers emit the array. |
| `format` | the string `teka` | yes in v0 | Declares that the catalog follows this document (decisions.md F6). |
| `format_version` | string of digits | yes in v0 | `"0"` for this document. |
| `modules` | array of strings | no | Which modules the teka uses, from the names in section 3.3; other names are allowed. No name twice. |
| `disclosure` | `full`, `title`, `kind` or `none` | yes in v0 | What a reader outside the teka may receive (section 5.5). A teka that a v0 implementation creates starts at `none`. Changed only by `set_disclosure`, which only the user applies (section 6.3). |
| `id_scheme` | `teka-year-seq` or `opaque` | no | How ids are minted (section 5.6). |
| `former_names` | array of `{name, until}` | no | Names the teka had before a `rename_teka`, kept so the outbox under an old name is still drained until the date `until` (section 8.3). `until` is always present; the `rename_teka` op carries it (section 6.3). Added by this draft. |

Anything else in `meta` is preserved. lifeproj validates none of these fields except `schema_version`. The types in this table are enforced once `format` is `teka`; on a lifeproj catalog they are reported, never enforced (section 10).

A catalog is stamped `format: "teka"` only when the whole catalog satisfies the v0 schema and the conformance checks. The `migrate` op that the user approves at section 9.4 step 6 does the stamping. When a found value under a v0 field name has another type or meaning, the old value is kept under a sibling key first (section 9.5). A full implementation never writes a stamped catalog that breaks a v0 rule, apart from violations it found there and has not yet repaired (section 6.3). A catalog writer that edits a stamped catalog can still break a rule; a full implementation then records the edit and proposes a repair (section 6.7).

### 4.3 `documents[]` (decisions.md F7)

lifeproj defines no fields for documents; only the generic unique-id rule applies (`templates.py`, `CATALOG_CHECK` and `main`). The real shapes exist only in private tekas and have not been surveyed (decisions.md F11). v0 defines a minimal record:

| Field | Type | Required | Rule |
| ----- | ---- | -------- | ---- |
| `id` | string or integer | yes | A non-empty string, or a non-zero integer found at adoption. Unique within `documents[]`. An id found at adoption is kept as it is. A v0 implementation mints ASCII ids, recommended form `<prefix>-doc-<YYYY>-<NNN>` (section 5.6). |
| `title` | string | yes | One line, non-empty. |
| `path` | string | yes | Relative to the teka folder (section 3.6). A path written by `file_document` or `update_document` follows the path rules below. A path found at adoption is kept as it is and reported when it breaks them, except that a path under `chapters/` or `entities/` is not reported; a foreign absolute path is never opened. |
| `date` | date | no | The document's own date, when known. |
| `kind` | string | no | Free text, for example `letter`, `invoice`, `statement`, `notice`, `contract`, `scan`, `email-thread`, `photo`, `note`. Not the closed item kind. |
| `source` | string | no | Where it came from: `intake/`, `intake/mail`, a capture tool, a scan. |
| `sha256` | string | on records from `file_document` | Lowercase hex digest of the file's bytes at filing time, so a moved or edited file can be noticed. |
| `provenance` | object | no | Who proposed and approved the record, which capture events it came from (section 5.8). |

Anything else is preserved.

The path rules. A path written by a v0 implementation is in Unicode NFC and uses `/` between segments. No segment is empty, and no segment starts with `.` or `~`. It holds no backslash and no character of the Unicode general categories Cc and Cf. Those are the control and format characters, among them U+0080 to U+009F, the zero-width characters U+200B to U+200F, the bidirectional controls U+202A to U+202E and U+2066 to U+2069, and U+FEFF. A bidirectional override can make `invoice` followed by U+202E and `fdp.command` display as a PDF name, and email intake brings file names that outsiders chose.

A path is also not reserved. Names are compared after NFC and Unicode case folding, because APFS volumes compare names without regard to case by default: `Intake/` is the same folder as `intake/`. The reserved names are:

- the files `catalog.json`, `DASHBOARD.md`, `README.md`, `catalog_check.py` and `timeline.md` at the root;
- an agent manual in any segment: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`, and any other manual name the implementation knows, so a filed attachment can never become instructions that a terminal agent loads;
- anything under `intake/`, `scripts/`, `ledger/`, `sources/`, `chapters/` or `entities/`.

`update_document` moves nothing, so the path it records may lie under `chapters/` or `entities/`; the other rules apply. `file_document` never creates a file there (decisions.md F7; section 12 asks whether it should). Dot folders such as `.sprava/`, `.claude/` and `.git/` are excluded by the segment rule. After symlinks are resolved the path lies inside the teka (section 3.6), and the reserved-name test runs on that resolved path. The file must exist at that path when `file_document`, or an `update_document` that sets `path`, is applied. Later ops do not check it, and replay never does.

Legacy records that lack `id`, `title` or `path` are reported at adoption. A `migrate` op adds the missing v0 keys beside the legacy ones and never removes a legacy key (section 9.5).

### 4.4 `open_items[]` (decisions.md F2, F3)

The rules lifeproj's code enforces (`templates.py`, `check_open_items`; duplicated in `osavul.py`, `validate_open_items`) are the core. The v0 additions are marked, and so are the fields this draft adds beyond decisions.md.

| Field | Type | Required | Rule |
| ----- | ---- | -------- | ---- |
| `id` | string or integer | yes | A non-empty string, or a non-zero integer. lifeproj accepts any present value that is not empty, false or zero; in a v0 catalog an id of another type, such as a boolean or an object, is reported and blocks stamping, because ids are never rewritten. Unique within `open_items[]`. Never equal to the `id` of any processing log entry: an id in the processing log is closed, and a closed id is never reused. Equality is by JSON type and value, so `7` and `"7"` are different ids (section 5.6). A v0 implementation mints ASCII string ids (section 5.6); ids found at adoption are kept as they are. |
| `title` | string | yes | Non-empty. One line in practice; lifeproj allows a paragraph. |
| `status` | `open`, `waiting`, `blocked` | yes | lifeproj also allows `done`. A v0 implementation never writes `done` (decisions.md F5); an adopted lifeproj catalog may hold it, and adoption tolerates it (section 9.4). |
| `priority` | `high`, `normal`, `low` | yes | |
| `due` | date | one of the two | `YYYY-MM-DD` strictly, and a real calendar date (decisions.md F2). lifeproj's checker also accepts `20260705` and `2026-W27-1`, because it uses Python's `date.fromisoformat`. Adoption rewrites those forms (section 9.4 step 3). |
| `no_deadline` | boolean | one of the two | Exactly one of `due` and `no_deadline: true` is present. Only the value `true` counts; `false` is the same as absent. In a lifeproj catalog an empty or `null` `due` counts as absent. A v0 writer omits a key it has no value for and never writes `null`. |
| `waiting_on` | string | when waiting or blocked | Non-empty free text naming the party. |
| `tags` | array of strings | no | Functional labels. At disclosure level `full` they pass through per-item redaction unchanged, as in lifeproj. They are emptied for a redacted item at disclosure level `title`, and for every item at disclosure level `kind` (section 5.5). A tag should not carry the subject of a redacted item; when an op sets `redact: true`, the review card lists the tags that stay published. |
| `link` | string | no | A path inside the teka, optionally with a `#fragment`, for example `DASHBOARD.md#tax-2026-2026-001`. lifeproj does not validate it. A link is only read, so its rules are lighter than the filing rules of section 4.3: it is relative, in NFC, `/`-separated, with no empty or `..` segment and no control character, and it lies inside the teka after symlinks are resolved. It may name a folder or a reserved file such as `timeline.md`. The app refuses to open a link whose target is under `.sprava/`, `.git/`, `.claude/`, `.agents/` or `scripts/`, or is a `.env` or key file (section 3.4). Any other value, such as a URL or an absolute path, is inert text: shown, never opened or resolved, and reported by the survey (section 9.2). |
| `redact` | boolean | no | `true` means the slice shows a generic title and a masked party (section 5.5). |
| `slice_title` | string | no | A sanitized replacement title for the slice. Non-empty when present. |
| `follow_up_at` | date | v0: when waiting or blocked | The day to chase the party if nothing has arrived (section 5.3). On adoption a missing value is derived and marked. |
| `expected_by` | date | no (v0) | The day the other party said it would act. |
| `kind` | closed list | v0: when `redact` is true | One of `legal-deadline`, `payment`, `reply-owed`, `filing`, `appointment`, `document-request`, `decision`, `other` (section 5.5). Optional otherwise. |
| `recurrence` | object | no (v0) | `{"freq": "monthly", "day": 14}` or `{"freq": "yearly", "month": 7, "day": 30}`. Requires `due`, which holds the next occurrence (section 5.4). |
| `contexts` | array of strings | no | GTD contexts as `@` tags, for example `@calls`, `@online`, `@errands` (section 5.9). Added by this draft; not yet in decisions.md. |
| `estimate_min` | integer ≥ 0 | no | Planning estimate in minutes. Added by this draft; not yet in decisions.md. |
| `dismissed` | boolean | no | `true` hides the item from views and slices without closing it (section 5.7). Added by this draft; not yet in decisions.md. |
| `created_at`, `updated_at` | timestamp | no (v0) | Timestamps (section 2). Both are set to the op's `at` by the ops section 6.3 lists. |
| `provenance` | object | no (v0) | Source capture events, who proposed, who approved, which op (section 5.8). |
| `derived` | array of strings | no | Names of fields an implementation filled without the user, for example `["follow_up_at"]` (section 5.3). Never empty: when the last name goes, the key goes. Added by this draft; not yet in decisions.md. |

Anything else is preserved. Every reader must accept unknown fields (decisions.md F2).

Writers emit the keys of a new item in the order of the table above and keep the order of existing keys on rewrite (decisions.md F10).

### 4.5 `processing_log[]` (decisions.md F5, F7)

The processing log is append-only. lifeproj's only code that writes to it is `drain`, which appends `{id, title, action, closed_at, source, via}` (`osavul.py`, `_drain_teka`). Entries written by agents by hand have no defined shape.

The rules below apply to entries a v0 implementation writes, which always carry `op_id`. An entry without `op_id` is legacy: accepted as it is and never rewritten. lifeproj's closure rule holds for every entry: an entry that carries `id` closes that item, whatever its `action`. Fields marked "added" are not in decisions.md F5 or F7; section 12 question 18 lists them.

| Field | Type | Required | Rule |
| ----- | ---- | -------- | ---- |
| `action` | string | yes | What happened. Closures use `done` or `dropped`. A v0 implementation also writes `occurrence`, `reopened`, `filed` and `closed-duplicate` (section 6.8), and `add_log_entry` may use any other value. |
| `id` | string or integer | closures only | The closed item's id, exactly as it appears in the catalog and with the same JSON type, never slice-prefixed. |
| `item` | string or integer | no | An item the entry is about without closing it: a recurrence occurrence, a reopened item, or an item whose id was already closed (`closed-duplicate`). Added. |
| `document` | string or integer | no | A document the entry is about, for example a filing. Added. |
| `title` | string | closures | The item's title at closure if it is a non-empty string, else `""`, copied so the entry reads on its own. |
| `at` | timestamp | yes | When the entry was written: the op's `at`. |
| `closed_at` | string or null | closures | When the item was closed. A v0 implementation writes a timestamp, except that a drained completion's `at` is copied as it is when it is a string, and is null otherwise (section 8.3). |
| `source` | string | closures | Where the closing came from, for example `user`, `import`, `google-tasks-via-osavul`. lifeproj's drain defaults it to `osavul`. |
| `via` | string | yes | The program and version that wrote the entry, for example `sprava/0.1`. lifeproj writes `lifeproj drain`. |
| `op_id` | string | yes | The op that produced the entry (section 6.8). Added. |
| `kind` | closed list | no | On a closure, copied from the item, so the slice's `closed[]` can show it. |
| `final` | object | closures | Every field of the item as it was except `id`, `title` and `kind`, which sit beside it, unknown fields included (section 5.10). Added. |
| `due`, `next_due` | date | occurrences | The occurrence that was completed and the next one (section 5.4). `next_due` is added. |
| `reopened_from` | string or integer | reopenings | The closed id an item was reopened from, with its JSON type (section 6.10). Added. |
| `note` | string | no | Free text. |

decisions.md F7 asks for `at` (or `closed_at`) and `action` on every entry. This draft requires both on entries a v0 implementation writes and exempts legacy entries, because hand-written entries such as `{date, action, what}` carry neither and the processing log may not be rewritten. Section 12 asks the author to confirm the deviation.

### 4.6 Module arrays

- `entities[]`: each row has `id` and `status` (a lifecycle word; free text), plus any comparable attributes (decisions.md F7). lifeproj enforces only unique ids, so rows without `status` are likely. The v0 requirement applies once the catalog is stamped, and adoption proposes a `migrate` that adds `status` to each row that lacks one (section 9.4). v0 has no op that adds or changes an entity row. After adoption, rows change only through external edits, which are recorded as such (section 6.7). Section 12 asks whether entity ops belong in v0.
- `ledger/`, `timeline.md`, `chapters/`: folder and Markdown conventions, not catalog arrays (section 3.3). v0 describes them and leaves them opaque. An implementation reads `meta.active_chapters` and nothing else about chapters.

### 4.7 The unknown-field preservation rule

An implementation that rewrites `catalog.json`:

1. parses the whole file with a parser that keeps key order (Swift's `JSONSerialization` does not, so it is not enough on its own);
2. applies its change to the parsed value;
3. writes the whole value back, keeping every key it did not change, in its original position, including keys and arrays it does not understand;
4. appends new keys of an existing object at the end of that object.

The same rule applies to slices and outbox files that an implementation rewrites. JSON Schemas in section 10 therefore set `additionalProperties: true` everywhere (decisions.md F2).

### 4.8 JSON conventions (decisions.md F10)

- I-JSON. Every catalog, slice, outbox file and op line a v0 implementation writes is I-JSON (RFC 7493, section 2.2): no duplicate member names, no lone surrogate escapes such as `\ud800`, and every integer within -(2^53)+1 to 2^53-1. A number with a fraction, such as `19.99` or `0.1`, is allowed; it is read and hashed as the nearest IEEE double, as RFC 8785 does. A reader that finds a duplicate member name, a lone surrogate or an integer out of that range in a catalog never picks one reading silently: parsers disagree on which duplicate wins, and a large integer loses digits in a double. The teka then needs attention (section 9.6), and nothing is written until the user approves a repair. A number too large for a double at all is treated the same way. The repair keeps every value as written in the file: the other values of a duplicate member go under `legacy_<name>` keys (section 9.5), and an out-of-range number becomes a string of the same digits. The implementation then records the difference from the expected state as an `external_edit` whose `hint` says the file held unsafe JSON. At adoption, the import snapshot holds the repaired catalog, and the byte copy in `.sprava/adopted/` keeps the original (section 9.4).
- Encoding UTF-8. Non-ASCII text is written as is, never as `\uXXXX` escapes. lifeproj escapes non-ASCII when it rewrites a catalog after a drain; a reader must accept both forms, since they are the same JSON value.
- Two-space indentation, one key per line, a trailing newline. Objects inside arrays follow the same indentation.
- Key order preserved on rewrite; new records use the documented order.
- Numbers. Every number a v0 implementation writes in a field this document defines is an integer. A number in a field the writer does not own, such as a price in an entity row, is preserved as parsed; a reader never rejects or truncates a fraction. The canonical form writes `2.0` as `2`, so the content hash cannot tell them apart. Where the difference matters, in `meta.schema_version` (section 9.6), the reader keeps the number as written in the file.
- Canonical form only for hashing. The content hash of a catalog is SHA-256 over the RFC 8785 canonical serialization (JSON Canonicalization Scheme) of the parsed value, written as `sha256:` followed by 64 lowercase hex digits. Canonicalization removes whitespace, so indentation, key order and `\u` escaping never change a hash. RFC 8785 sorts object keys by their UTF-16 code units and writes numbers as ECMAScript's `Number.prototype.toString` does. An implementation therefore uses a strict RFC 8785 library and never its JSON library's sorted output: Python's `json.dumps(sort_keys=True)` sorts by code point and writes `1e+16` where RFC 8785 writes `10000000000000000`. Section 11 (check 63) gives test vectors. The canonical form is never written to disk.
- JSON Schema dialect 2020-12. Conforming validation asserts the `date` and `date-time` formats; many validators treat `format` as a note unless told otherwise.

### 4.9 The write protocol

An atomic rename prevents a torn file. It does not prevent a lost update. If two programs read the catalog, change it and rename their versions into place, the second rename erases the first program's change. lifeproj's drain shows the cost: it writes the catalog, then deletes the applied completions from the outbox, so a closure erased by a later rename is lost everywhere and the item comes back open. Every writer therefore follows this protocol, lifeproj included (section 9.8):

1. Open `<teka>/.teka.lock`, creating it if it is missing (it is never deleted), and take an exclusive advisory lock on it with `flock`. Hold the lock until the last step.
2. Read and parse `catalog.json` and compute its content hash.
3. A full implementation absorbs any external edit now (section 6.7), then builds its ops and runs the transaction guard (section 6.3).
4. Apply the change and write the result to a new temporary file next to the catalog, created exclusively under a random name (section 3.6). Flush it to stable storage with `fcntl(F_FULLFSYNC)`. On macOS, `fsync` alone does not force data to stable storage; Apple's manual page for `fsync` points to `F_FULLFSYNC`.
5. Read `catalog.json` again and hash it. If the hash differs from step 2, someone changed the file without taking the lock: delete the temporary file and go back to step 2, still holding the lock. This step narrows the window for programs that skip the lock, such as a person in a text editor. It cannot close it.
6. A full implementation now appends its op lines to the op log, flushes them with `F_FULLFSYNC`, and moves a filed document into place (section 6.9).
7. Rename the temporary file over `catalog.json`, then flush the teka folder itself (open it and `fsync` it) so the rename survives a power loss. A full implementation updates `.sprava/snapshot.json`. Release the lock.

The same lock covers every other file the change writes inside the teka, such as a filed document. A drain holds it until the outbox is acknowledged (section 8.3). A writer holds the lock for one change only, never while it waits for the user. The lock covers nothing outside the teka: the hub writes the outbox on the spool without it (section 8.3).

## 5. Semantics

### 5.1 The honesty rules

These rules are what make a catalog trustworthy. The schemas check the ones a schema can check; the conformance list (section 11) covers the rest.

1. Nothing is silently dateless. An item has a `due` date or says `no_deadline: true`.
2. Waiting is explicit. A `waiting` or `blocked` item names the party in `waiting_on` and, in v0, says when to chase in `follow_up_at`.
3. Ids are never reused. A closed id stays in the processing log forever; a dropped item does not free its id. Reopening an item gives it a new id (section 6.10).
4. `open_items[]` and `documents[]` state the present; the processing log and the op log record the past. A derived file is never edited by hand, and a hand edit of the catalog is recorded, never silently absorbed (section 6.7).
5. Every change is an op with an actor. Nothing a clerk or a brain proposes is applied without the user's approval. Section 6.5 lists the changes that need no proposal. Two paths close items without an approval step: draining completions from the hub's outbox (section 8.3), which keeps lifeproj's semantics (decisions.md F8), and a direct edit of `catalog.json` by another program, which is recorded afterwards as an `external_edit` (section 6.7). The app shows both as external changes the user can undo.
6. Redaction hides, it never lies. A redacted item still says what kind of thing it is and keeps its dates and status. Redaction does not hide everything: section 5.5 lists what a cross-binder view still receives.
7. Absence means absence. A missing optional field is unknown; a missing slice means the teka chose not to publish; neither is an error.

### 5.2 Status and buckets (decisions.md F4)

One bucket taxonomy serves the Now page, the roll-up and any brief: Overdue, Today, Next 7 days, Later, No deadline, Nudge, Waiting, Recently closed. It replaces the four buckets of lifeproj's starter dashboard and the six of `lifeproj brief`.

A valid `due`, for bucketing, is a string in one of the forms that Python 3.11's `date.fromisoformat` accepts, naming a real calendar date: `YYYY-MM-DD`, `YYYYMMDD`, `YYYY-Www`, `YYYYWww`, `YYYY-Www-D` and `YYYYWwwD`. A week date names an ISO week, and a missing weekday counts as Monday (`D` = 1). lifeproj's `brief` buckets with that function, so a reader that accepted only `YYYY-MM-DD` would drop lifeproj's compact dates into No deadline while lifeproj shows them as overdue. A `due` that is not a string, or names no real date, is not valid. A v0 writer still writes only `YYYY-MM-DD` (section 4.4), and adoption rewrites the other forms with this same table (section 9.4 step 3).

For an item with a valid `due`, `delta` is the number of calendar days from today to `due`, negative when the date has passed. It is a difference of dates, never seconds divided by 86,400. Evaluate in this order:

1. If `status` is `done` (a lifeproj catalog, section 9.4): the item is shown in Recently closed and nowhere else.
2. If `dismissed` is `true`: the item is hidden. It is in no bucket; views show only a count of hidden items.
3. If `status` is `waiting` or `blocked`: if `follow_up_at` is today or earlier, or missing (a lifeproj catalog before adoption), the item is in Nudge; otherwise it is in Waiting. `due` does not bucket a waiting item (decisions.md F3); views may mark a passed `due` on it, and `lifeproj brief` makes the same choice (test `test_waiting_wins_over_the_date_bucket`).
4. If the item has a valid `due`: `delta < 0` is Overdue; `delta = 0` is Today; `1 ≤ delta ≤ 7` is Next 7 days; `delta > 7` is Later.
5. Otherwise: No deadline.

Loose items from a lifeproj v1 catalog follow the same steps: a missing or unknown status counts as `open`, and a `due` that is not a valid date counts as absent, so such an item lands in No deadline and is never dropped from view. `lifeproj brief` does the same for an unparseable `due` (test `test_unparseable_due_is_undated_never_dropped`).

Recently closed lists closure entries (those with an `id`) whose closing date is today or one of the 6 days before it, so the bucket covers 7 calendar days (decisions.md F4). The closing date is found in this order:

1. `closed_at`, when it parses as an RFC 3339 date-time: converted to the user's time zone and cut to its date;
2. else `closed_at`, when it is a `YYYY-MM-DD` date: that local date;
3. else `at`, when it parses as an RFC 3339 date-time, converted the same way. A v0 implementation always writes `at`, so a drained closure whose hub value is unusable still shows.

An entry with none of these is left out of Recently closed and out of the slice's `closed[]`. A closing date later than today, which a wrong clock can produce, counts as today.

A `done` item still in `open_items[]` (an unadopted lifeproj catalog) has no closing date. It is listed in Recently closed after every dated entry, as `done (date unknown)`, and is not counted in `<closed7>` (section 7.1).

Order within a bucket: `due` ascending (undated last), then priority `high`, `normal`, `low`, then any other or missing priority, then title, then `id`. In Nudge and Waiting: `follow_up_at` ascending (missing first), then priority, then title, then `id`. In No deadline: priority, then title, then `id`. In Recently closed: closing date, newest first, then `id`, then the undated `done` items by title and `id`. Titles and ids are compared by Unicode code point after NFC normalization, so Swift and Python agree. A title or id that is not a string is compared by its canonical JSON text (section 4.8), so the integer `7` sorts as the text `7`. This is `lifeproj brief`'s sort key with `follow_up_at` and a final tie-break added (`brief.py`, `_sort_key`).

### 5.3 Nudge, `follow_up_at` and `expected_by` (decisions.md F3)

The problem these solve: items waiting on someone else kept their old `due` dates and showed up as overdue, so the user could not tell "I am late" from "they are late" (HANDOFF.md, "Staleness looked like lateness").

- `due` is the matter's real deadline. It survives when an item starts waiting. Overdue applies only to `open` items.
- `follow_up_at` is the day to chase the party if nothing has arrived. It is required on every waiting or blocked item written by a v0 implementation. When it is today or earlier the item is in Nudge. Chasing does not change `due`; it sets a new `follow_up_at`.
- `expected_by` is the date the other party gave. It is informative.
- One formula gives a default `follow_up_at`, at adoption or whenever an item starts waiting without one: `follow_up_at = max(today, min(base, due))`. Here `base` is `expected_by` plus one day when `expected_by` is present, else today plus 7 days, and `min` with `due` applies only when `due` is present. So the default is never in the past, and never later than a deadline that is still ahead.
- A value an implementation fills in without the user is marked: the item's `derived` array gets the field's name, so the user can see the date was not theirs. A date the user confirms or changes is theirs. The exact rule, which every op follows:
  - an op that supplies `derived` (`set.derived` in `update_item`, `args.derived` in `set_status`, or the item of `add_item` and `reopen`) gives the whole new array, and whoever builds the op appends a new name at the end of the existing ones;
  - otherwise, `derived` loses the name of every field the op sets or removes;
  - an empty `derived` is removed, never written as `[]`.
- A Nudge card offers: a new `follow_up_at` (chased, waiting again), `set_status` to `open` (it arrived; now act), or `complete`. A clerk may draft a one-line follow-up message for the card (decisions.md P5). The draft is never sent by the implementation.
- Setting `status` to `open` removes `waiting_on`, `follow_up_at` and `expected_by` unless the op supplies them.

### 5.4 Recurrence (decisions.md F3)

`recurrence` is `{"freq": "monthly", "day": D}` or `{"freq": "yearly", "month": M, "day": D}` with `1 ≤ D ≤ 31` and `1 ≤ M ≤ 12`. `month` is ignored when `freq` is `monthly`. The rules are the hub's rules today, moved into the teka:

- A recurring item requires `due`, and `due` always holds the next occurrence.
- `next_after(d)` is the first date strictly after date `d` that matches the rule, with month-length clamping: for a month with fewer days than `D`, the occurrence falls on that month's last day (so `day: 31` gives 30 April and 28 or 29 February; `month: 2, day: 29` gives 28 February in a common year).
- `complete` on a recurring item does not close it. The applied op carries `occurrence_due` (the `due` being completed) and `next_due`, which is `next_after(max(due, today))` on the day the op is applied. That date is strictly later than both, so the next date never lands in the past. Applying the op sets `due` to `next_due` and appends an `occurrence` entry with `item` (never `id`), `due` and `next_due`. The item stays open. Because the op records `next_due`, replaying it on a later day gives the same result.
- The transaction guard refuses a `complete` without `next_due` on an item that has `recurrence`, and a `complete` with `next_due` on an item that has none. So `complete` never closes a recurring item; ending a series is `drop`.
- decisions.md F3 says that dismissing a recurring item ends it, as the hub does today. Section 5.7 says how the hub's "dismiss" maps onto teka ops. The teka op `dismiss` is a reversible hide. Nothing advances an item on its own, so a dismissed recurring item simply keeps its `due` until it is undismissed. `complete` and `drop` work on a dismissed item as on any other.
- Removing `recurrence` (an `update_item` with `unset`) turns the item into a one-off due on its current `due`.
- A completion drained from the hub for a recurring item advances it the same way. Section 8.3 says how a repeated completion is recognised and skipped.

### 5.5 Disclosure and redaction (decisions.md F6, F8)

Two levels of control exist. `meta.disclosure` sets the teka's ceiling; per-item `redact` and `slice_title` tighten within it. An item can be more hidden than the teka's level, never less.

Disclosure is enforced by the publisher. Only a publisher that reads `meta.disclosure` and `dismissed` can publish a slice safely. Today's lifeproj reads neither. It republishes after every fleet drain, and the manual it stamps into each teka tells terminal agents to run `lifeproj publish` in every digest. Section 8.1 therefore limits what a teka that lifeproj can still reach may use, until lifeproj implements this section (section 9.8).

`kind` is the closed list `legal-deadline`, `payment`, `reply-owed`, `filing`, `appointment`, `document-request`, `decision`, `other`. The words describe the type of obligation without its subject:

- `legal-deadline`: a date set by law, a court, a contract or an authority;
- `payment`: money to send;
- `reply-owed`: a reply is owed; `status` says by whom (`open` means the user owes it; `waiting` means the other side does);
- `filing`: a form or document to submit;
- `appointment`: a meeting or visit on a date;
- `document-request`: a document to obtain from someone;
- `decision`: something to decide;
- `other`: none of the above.

The item's `kind` is required when its `redact` is `true`, and the publisher substitutes `other` for a missing kind at disclosure level `kind`. It is optional otherwise, and a clerk may propose it for every item because it helps views sort work.

The published title, stated once: `slice_title` when present; else `[redacted]` when `redact` is `true`; else the item's title.

What each disclosure level publishes (section 8.2 has the exact projection):

| Disclosure level | Title | `waiting_on` | `tags` | `link` | `id` | The item's `kind`, dates, status, priority | Chapters |
| ---------------- | ----- | ------------ | ------ | ------ | ---- | ------------------------------------------ | -------- |
| `full` | the published title | as is; `[party]` when `redact` | as is | as is; null when `redact` | prefixed; an alias when `redact` and the id is not in the recommended form (section 5.6) | as is | as is |
| `title` | the published title | `[party]` when `waiting_on` is a non-empty string, else null | as is; `[]` when `redact` | null | prefixed; an alias when the id is not in the recommended form | as is | `active_chapter` null, `active_chapters` `[]` |
| `kind` | `[redacted]` for every item | as at `title` | `[]` | null | as at `title` | as is; a missing kind becomes `other` | as at `title` |
| `none` | nothing is published; an existing slice file is removed | | | | | | |

Disclosure level `full` is lifeproj's projection (`osavul.py`, `project_slice`; test `test_redaction_projection`), including its `[party]` for a redacted item that has no party, kept for byte compatibility. It has two deliberate departures for redacted items. `link` becomes null, because a file path tends to name the subject. An id that is not in the recommended form is replaced by an alias, because a hand-made id can spell the subject out. A slice item already allows a null `link`, so lifeproj readers are unaffected. Disclosure levels `title` and `kind` have no lifeproj counterpart, so they mask more: chapters, because a chapter name tends to be a counterpart's name; the tags of redacted items; and every id that is not in the recommended form, redacted or not, because at those levels a hand-made id would show what the masked title hides.

What stays visible at every level except `none`: the teka's name (the slice's `teka` key, which is also the spool file name), each item's kind, dates, status, priority and published id, and the tags at `full` and, for items that are not redacted, at `title`. A sensitive teka should therefore have a neutral name, and the clerk never proposes a tag for a redacted item.

The review card marks as a privacy change every op that loosens what the hub may receive: `set_disclosure` to a higher level, `redact` changed from `true` to `false`, `slice_title` removed or changed, a tag added to a redacted item, or the item's `kind` removed from a redacted item. Only the user can apply `set_disclosure` (section 6.3). An implementation may refuse the other loosening ops when a brain proposes them.

The catalog always keeps the natural text; redaction happens only at the slice boundary. The slice carries its `disclosure` (section 8.2), so a hub can check what it receives.

Lowering disclosure stops future publication. It does not erase what the hub or its mirrors, such as Google Tasks, already hold. The review card for `set_disclosure` says so.

### 5.6 Ids (decisions.md F6)

- An id is stable for the life of the teka and never reused. lifeproj requires only that it be present and not empty.
- Types and equality. A v0 id is a non-empty string or a non-zero integer. Two ids are the same when they have the same JSON type and the same value: `7` and `"7"` are different ids, and `true` is never an id. Every copy of an id, in a closure entry, an op or `provenance`, keeps its JSON type. Python treats `1`, `1.0` and `true` as equal and Swift does not, so an implementation compares the type first.
- Minted ids. A v0 implementation mints string ids that match `^[A-Za-z0-9][A-Za-z0-9._-]*$`: ASCII letters, digits, dots, underscores and hyphens, starting with a letter or a digit. This rule is added by this draft. ASCII rules out look-alike letters and invisible characters such as U+200B, which a "no whitespace" pattern lets through. Ids found at adoption are kept as they are; the survey reports any that are not strings, hold whitespace, non-ASCII, format or control characters, or are not in the recommended form and contain a run of four or more letters, which may name the subject (section 9.2).
- The mint prefix. New ids start with the mint prefix: `meta.name` when it matches `^[a-z0-9][a-z0-9-]*$`; otherwise the name cleaned up in this order: Unicode NFKD, characters outside ASCII removed, lowercase, every run of other characters than `a-z` and `0-9` turned into one `-`, and `-` trimmed from both ends; and when that leaves nothing, the word `item`. So a teka adopted as `Estate of A. Example` mints `estate-of-a-example-2026-001`.
- The recommended form. An item id is in the recommended form when it matches `^<prefix>-\d{4}-\d{3,}$`, where `<prefix>` is the current mint prefix with every regular-expression metacharacter escaped. For example `estate-example-2026-007`: a four-digit year and a zero-padded number of at least three digits that increments within the year. It says nothing about the item's subject. The recommended document form is `<prefix>-doc-<YYYY>-<NNN>`, tested the same way. This one test decides aliases, `meta.id_scheme` and check 66. An id minted under a former name of the teka is not in the recommended form, so it is aliased where section 5.5 says.
- Minting happens when an op is applied, never when it is proposed. A proposal names a new record with a placeholder such as `"$new:1"`, which later ops in the same proposal may reference. The applier replaces each placeholder with a real id before it writes the op lines, so applied ops never hold placeholders and two pending proposals can never claim the same number. The next number is one more than the largest `NNN` already used for that year, read with the anchored pattern `^<prefix>-(\d{4})-(\d{3,})$` (with `-doc` for documents) from the ids in `open_items[]` (or `documents[]`), the closure ids and `item` values in the processing log, and the op log. `YYYY` is the local calendar year of the op's `at`. `meta.next_item_id` and `meta.next_doc_id` are never read for this purpose: `scaffold.py` stamps them and no lifeproj code reads or increments them.
- Bare ids such as `item-0001` are accepted; both forms are legal input today (lifeproj's test fixtures use bare ids; its manual shows prefixed ones). An implementation never rewrites an existing id.
- At the slice boundary an id is prefixed with `<teka>-` unless it already starts with that string. The test is a plain string prefix, as lifeproj does (test `test_id_prefix_is_idempotent`). An integer id is written in decimal first, as lifeproj's `str()` does, so the id `7` in a teka named `tax-2026` publishes as `tax-2026-7`. Two ids can then project to the same slice id: in a teka named `estate-example`, the ids `estate-example-2026-007` and `2026-007` both publish as `estate-example-2026-007`, and a drain would close the wrong one. So the projected ids of a teka must be unique. `add_item`, `reopen` and minting reject an id whose projection collides with an existing one, and publishing fails, as it does on a validation error, when a collision is found. The same can happen across tekas whose names are hyphen prefixes of each other (`tax` and `tax-2026`); the survey and a doctor check flag such pairs.
- Aliases. Where section 5.5 calls for one, an id is published as `<teka>-r-` followed by the first 12 hex digits of HMAC-SHA-256 of the id's canonical JSON text (section 4.8; so `7` and `"7"` give different aliases), keyed with 32 random bytes kept in `.sprava/slice-key` and made on first publish. Losing the key changes the aliases, which the hub sees as items replaced.
- Published ids are remembered. `.sprava/cursors.json` keeps, for each item, the id it was last published under. A drain resolves a completion against that map as well as against the rules of section 8.3, and a closed item appears in the slice's `closed[]` under the id the hub last saw (section 8.2).
- `meta.id_scheme` records which convention the teka follows: `teka-year-seq` when every item id is in the recommended form, `opaque` otherwise. New ids use the recommended form in both cases.

### 5.7 Dismiss

`dismiss` sets `dismissed: true`. The item keeps its status, dates and party; it leaves every bucket, the dashboard lists and the published slice. `undismiss` removes the flag. Both are lossless and reversible. Closing an item for real is `complete` or `drop`, and ending a recurring series is `drop` (section 5.4). `dismissed` and these two ops are added by this draft; they are not yet in decisions.md.

The hub's "dismiss" maps onto teka ops by this table, and nowhere else in this document:

| The hub dismisses | Teka op |
| ----------------- | ------- |
| a binder item that does not recur | `dismiss`, a reversible hide, like the hub's mute today |
| a binder item that recurs | `drop`, which ends the series, as decisions.md F3 says ("dismissing ends it") |
| one of its own items that belongs to no binder | none; it stays in the hub |

If the author prefers that a hub dismiss of a recurring item only hides it, the second row becomes `dismiss` (section 12, question 18). Today's outbox carries only `done` and `dropped` (section 8.3), so a hub dismiss reaches a teka only through a future outbox version or an app that replaces the hub.

### 5.8 Provenance

`provenance` on an item or a document is an object with optional `events` (ids of the capture events it came from), `proposed_by` (an actor, section 6.2), `approved_by` (`"user"` in a single-user teka, or a random id the app mints for each person, never the macOS login name, a full name, a numeric user id or an email address), `op` (the op that created the record), `proposal` (the proposal it came from) and `reopened_from` (on a reopened item, the closed id). Other keys are allowed. Provenance holds references such as ids and offsets, never copied source text. The op log holds the complete history; `provenance` is the summary a view can show without reading it.

### 5.9 Contexts

`contexts` holds GTD contexts (from the Getting Things Done method: the place or tool a task needs) as `@` tags: the universal ones `@anywhere`, `@online`, `@calls`, `@phone`, `@computer`, and place-bound ones such as `@errands` or `@office`. Resolution when a view asks "what can I do right here": an explicit tag on the item, else the teka's default (an open question, section 12), else `@anywhere`. Contexts are planning metadata; they never affect buckets or publication. They are added by this draft and are not yet in decisions.md.

### 5.10 Closing (decisions.md F5)

Closing is mechanical. A `complete` or `drop` op removes the item from `open_items[]` and appends a closure entry to the processing log with `id`, `title`, `action` (`done` or `dropped`), `at`, `closed_at`, `source`, `via`, `op_id`, `kind` when the item has one, `note` when the op has one, and `final`. `title` is the item's title when that is a non-empty string, else `""`. `final` holds every field of the item except `id`, `title` and `kind`, which sit beside it, unknown fields included. So nothing the catalog held is lost when an item closes, and lifeproj, terminal agents and a reopen can read it without the op log (decisions.md F2). lifeproj's drain keeps only six fields; the entries it wrote stay as they are. When the item's id already closes an earlier entry, the entry is written without `id` (section 6.8).

The slice carries closures of the last 7 days in `closed[]`, so a cross-binder view learns of them (section 8.2).

lifeproj's "done appears once then drops from the next slice" was a manual rule, not code (`templates.py`, `CLAUDE_HEADER`: drop the item "once it has shown as `done` once"). v0 makes it mechanical by never writing `done` into `open_items[]`.

## 6. Ops and the op log

### 6.1 Principle (decisions.md F1, A2)

`catalog.json` is the truth of state. The op log is the truth of history. Every change a full implementation makes to the catalog is one op; every op records the catalog's content hash before and after. The chain of hashes is how an implementation knows that nobody else edited the file in between. When the chain breaks, the implementation records what it found as an `external_edit` op (section 6.7) and carries on. Undo appends a compensating op (section 6.10). Nothing is ever removed from the op log, except by the expunge procedure of section 6.11.

### 6.2 The op envelope

An applied op is one line of `.sprava/ops.ndjson`. Its fields:

| Field | Type | Required | Rule |
| ----- | ---- | -------- | ---- |
| `id` | UUID string, lowercase | yes | A universally unique identifier in its standard 36-character form. Version 7 recommended (time-ordered), the same choice as capture events (decisions.md C1). Unique in the op log. |
| `at` | timestamp | yes | When the op was applied (section 4.4). |
| `hlc` | object | no | `{wall_ms, counter, node}`, a hybrid logical clock stamp, the same shape as capture events (decisions.md C1). Reserved for merging logs from several devices; not needed on one Mac. `node` is a random opaque id, never a computer or device name. Other keys are allowed. |
| `actor` | object | yes | `{kind, client?, origin?, model?}`. `kind` is `user` (a person acting in the app), `clerk` (Tier 1), `brain` (Tier 2 over MCP), `import` (the implementation's own bookkeeping: adoption, migration and crash recovery) or `external` (a change that came from outside this implementation: a hand edit found after the fact, or a completion drained from the hub). `client` is the `program/version` of the implementation that applied the op, for example `sprava/0.1`, whatever the kind. It is required on every op that writes a log entry (`complete`, `drop`, `reopen`, `file_document`, `add_log_entry`), because the entry's `via` is copied from it. `origin` says, for kind `external`, where the change came from when that is known: `spool-outbox`, `lifeproj` or `unknown`. `model` names the model for `clerk` and `brain`. |
| `proposal` | UUID | for `clerk` and `brain` | The proposal the op came from. |
| `batch` | UUID | no | Ops written together share a batch id. For a proposal it is the proposal id. |
| `seq` | integer | with `batch` | The op's position in its batch, from 0. |
| `batch_size` | integer | with `batch` | How many ops the batch has, so a reader can tell a complete batch from one cut short by a crash (section 6.9). |
| `approved_by` | string or null | for `clerk` and `brain` | Who approved: `"user"`, or a random id the app mints for each person (section 5.8). Required and non-empty for every op whose actor is a clerk or a brain (decisions.md A5). |
| `before_hash` | `sha256:<hex>` | yes | Content hash of the catalog before the op (section 4.8). |
| `after_hash` | `sha256:<hex>` | yes | Content hash after the op. |
| `compensates` | UUID | no | Set on an undo: the op this one reverses (section 6.10). |
| `op` | closed list | yes | The op type (section 6.3). |
| `args` | object | yes | The op's payload, by type. |
| `note` | string | no | Free text, for example how a relative date was resolved. |

Chain rule: for every op after the first, `before_hash` equals the `after_hash` of the previous op that took effect. Ops named by an `abort` never took effect and are skipped (section 6.9). The first line of every op log is an `import_snapshot` whose `before_hash` and `after_hash` are equal: adoption changes nothing, and the snapshot writes nothing into the catalog (section 6.8). A later `import_snapshot` is a re-base point, and the chain starts again from it (section 6.6).

### 6.3 The op vocabulary

Applying an op is a pure function of the catalog and the op. An applied op therefore carries every value its effect needs: dates computed from `today`, a recurring item's next date, the end of a former name's drain window, a file's digest and the ids of new records. Timestamps an op sets are the op's `at`. The effects in the table below are exact: a new key goes at the end of its object (section 4.7), a removed key leaves no `null` or empty value behind, and section 5.3 gives the rule for `derived`. Two implementations that replay the same op log get the same catalogs, with the same content hashes. The reference applier of section 10.9 follows this table.

The transaction guard (decisions.md A2) runs before an op is written to the op log. It applies the op to a copy of the parsed catalog and validates the result against section 10's rules for the catalog's level. The op is accepted when it adds no new violation and every record it creates or changes is valid afterwards. Violations that were already there, in records the op does not touch, are carried over and reported; they do not block the op. So a catalog with two broken items can be repaired one item at a time. Records a v0 implementation creates (with `add_item`, `reopen` or `file_document`) always follow the v0 record rules, whatever the catalog's level. A rejected op leaves everything untouched.

"New violation" has an exact meaning, so that two guards accept the same ops. A violation is identified by three things: the array that holds the record (or `meta`), the record's key, and the rule. The record's key is its `id` when that id is unique in the array, else the SHA-256 of the record's canonical form (section 4.8). The rule is the number of the conformance check in section 11 that the record fails, or `schema` for a failure the JSON Schema reports. A violation is new when it is present after the op and absent before it under the same three things. Array positions play no part, so removing one item never makes another item's old violation look new.

| Op | `args` | Effect |
| -- | ------ | ------ |
| `add_item` | `{item}` | Appends a complete v0 item. Its id is minted (section 5.6): never seen in `open_items[]`, the processing log or the op log, and its slice projection is unique. `created_at` and `updated_at` equal the op's `at`. |
| `update_item` | `{id, set?, unset?}` | Field-level change. Removes the fields in `unset`, then sets the fields in `set`, a changed field keeping its place and a new one going at the end; a field may not appear in both. Neither touches `id`, `status`, `dismissed`, `created_at` or `updated_at`, and `unset` may not remove `title` or `priority`. Updates `derived` (section 5.3). |
| `set_status` | `{id, status, waiting_on?, follow_up_at?, expected_by?, derived?}` | Changes status among `open`, `waiting`, `blocked`. For `waiting` or `blocked` the op carries `waiting_on` and `follow_up_at`. For `open` it removes the three waiting fields unless supplied (section 5.3). When the implementation filled `follow_up_at` by the formula of section 5.3, the op carries `derived` with that name. Updates `derived` (section 5.3). |
| `complete` | `{id, closed_at, source, note?, occurrence_due?, next_due?}` | Without `next_due`: closes with `done` (section 5.10). With `occurrence_due` and `next_due`: advances a recurring item (section 5.4). The guard refuses `next_due` on an item without `recurrence`, and its absence on an item with one. `closed_at` is a timestamp, usually the op's `at`; for a drained completion it is the hub's value, or null (section 8.3). `source` names where the closing came from, for example `user` or `import`. |
| `drop` | `{id, closed_at, source, reason?}` | Closes with `dropped`. On a recurring item it ends the series. |
| `reopen` | `{id, item}` | Undoes a closure (section 6.10). `id` is the closed id, with its JSON type. `item` is a new item with a newly minted id, its `title` and `kind` taken from the closure entry and its other fields from the entry's `final` (or from the op log, or chosen by the user, section 6.10), `provenance.reopened_from` set to the closed id, and `created_at` and `updated_at` equal to the op's `at`. The closure entry stays. Added by this draft. |
| `dismiss`, `undismiss` | `{id}` | Sets or clears `dismissed` (section 5.7). |
| `file_document` | `{document, from?}` | Appends a document record with a minted id, a `path` that follows section 4.3, and the file's `sha256`. When `from` (a path under `intake/`) is given, applying the op first moves that file to `document.path`. The move never replaces an existing file; section 6.9 gives the order of the steps. |
| `update_document` | `{id, set?, unset?}` | Field-level change to a document record; never `id`, and `unset` never removes `title` or `path`. A new `path` follows section 4.3, and the file must be there. Changing `path` moves nothing; it records that the file was moved outside. |
| `add_log_entry` | `{entry}` | Appends a free log entry and sets its `at`, `via` and `op_id`, replacing any values the entry carried. The entry must not carry `id`, because closures go through `complete` and `drop` (section 6.8). |
| `set_meta` | `{set?, unset?}` | Changes `meta` fields such as `domain`, `lifecycle`, `active_chapters`, `modules`, `id_scheme`. Never `name`, `schema_version`, `format`, `format_version`, `disclosure` or `former_names`, in `set` or in `unset`. |
| `set_disclosure` | `{disclosure}` | The only op that changes `meta.disclosure` after adoption. Applied by the user in the app, never proposed, so neither a clerk nor a brain can raise what the hub receives. Applying it republishes or removes the slice when the federation profile is on. |
| `rename_teka` | `{name, former, until}` | Applied by the user in the app, never proposed. After the folder was renamed, sets `meta.name` to the folder's new basename (`name`) and appends `{name: former, until}` to `meta.former_names`. `until` is the local date of the op's `at` plus 30 days, unless the user chose another date; the applied op always carries it. Section 8.3 says what happens on the spool. Added by this draft. |
| `external_edit` | `{patch, detected_at?, hint?}` | Recorded by the implementation, never proposed. `patch` is an RFC 6902 JSON Patch made of `add`, `remove` and `replace` steps, each `add` and `replace` with a `value`, from the expected catalog to the catalog as found (section 6.7). The actor kind is `external`. |
| `import_snapshot` | `{catalog, survey}` | The first op of an op log: the catalog as found at adoption, verbatim, plus the survey results (section 9.2). Also a re-base point when a log fails replay (section 6.6). Actor kind `import`. Changes nothing. |
| `migrate` | `{from, to, patch}` | Records a format migration as a JSON Patch of `add` and `replace` steps: stamping the v0 keys, adding v0 keys beside legacy ones, keeping a colliding legacy value under a sibling key first (section 9.5), and adding `status` to entity rows. Never removes a key. Actor kind `import`. |
| `abort` | `{ops, reason}` | Marks logged ops that never took effect after a crash (section 6.9). Changes nothing. Actor kind `import`. Added by this draft. |
| `expunge` | `{replaced, rewrote, reason?}` | Records that a text was forgotten (section 6.11): how many values were replaced in each place, and which op lines were rewritten. It never holds the text or a digest of it. Changes nothing, so its two hashes are equal. Applied by the user in the app, never proposed. Added by this draft. |

These ops set `updated_at` to the op's `at` on the item they change: `add_item` and `reopen` (with `created_at`), `update_item`, `set_status`, `dismiss`, `undismiss`, and `complete` when it advances a recurring item. No other op sets it.

Ops for the hub's own vocabulary that have no teka meaning (`add_context`, which creates a global `@label`) are not teka ops. Hub annotations `contexts` and `estimate_min` map onto `update_item`; the hub's dismiss maps as the table in section 5.7 says.

### 6.4 Examples: two op lines and one log entry

Op lines are shown indented for reading. On disk each is one compact line (section 6.9).

A closure proposed by the importer and approved by the user, the first op of a two-op adoption batch:

```json
{
  "id": "019a2000-0000-7000-8000-000000000004",
  "at": "2026-10-06T14:03:11Z",
  "actor": { "kind": "import", "client": "sprava/0.1" },
  "proposal": "019a2000-0000-7000-8000-000000000003",
  "batch": "019a2000-0000-7000-8000-000000000003",
  "seq": 0,
  "batch_size": 2,
  "approved_by": "user",
  "before_hash": "sha256:18f0c93fba9fe5b1d215ea890697b3125071e55571467ea93791d94712a977b7",
  "after_hash": "sha256:c99879393fafdc1a2b8d9afc86824043ae8af8551d22a6a8ed290387d6e8b7ce",
  "op": "complete",
  "args": {
    "id": "item-0005",
    "closed_at": "2026-10-06T14:03:11Z",
    "source": "import",
    "note": "status was done in open_items at adoption"
  }
}
```

The closure entry it writes into the processing log. `after_hash` above covers this entry:

```json
{
  "id": "item-0005",
  "title": "Renew the insurance policy",
  "action": "done",
  "at": "2026-10-06T14:03:11Z",
  "closed_at": "2026-10-06T14:03:11Z",
  "source": "import",
  "via": "sprava/0.1",
  "op_id": "019a2000-0000-7000-8000-000000000004",
  "note": "status was done in open_items at adoption",
  "final": { "status": "done", "priority": "normal", "due": "2026-09-15" }
}
```

An external edit: a terminal agent raised an item's priority by hand. The patch goes from the catalog the implementation expected to the catalog it found.

```json
{
  "id": "019a2000-0000-7000-8000-000000000010",
  "at": "2026-10-06T17:25:00Z",
  "actor": { "kind": "external", "client": "sprava/0.1", "origin": "unknown" },
  "before_hash": "sha256:f3d2272c42df913a996062ee75a3b0b3d75a6e06bc5ea5361bb7e7fe2fc72265",
  "after_hash": "sha256:88d1e08f9a2c1af780fb7c13c5d4211c0d9b152cb51a2662ef2cb3114289a857",
  "op": "external_edit",
  "args": {
    "patch": [{ "op": "replace", "path": "/open_items/2/priority", "value": "normal" }],
    "detected_at": "2026-10-06T17:25:00Z"
  }
}
```

### 6.5 Batches and proposal states (decisions.md A5)

A proposal is a batch of op bodies with a header. Each op body has `op` and `args`, and optionally `note`, `confidence` and source `spans`. A span is `{event, start, end}`, counted in Unicode scalar values of the capture event's `text` and half-open, as in the capture-event format: `start` is the first scalar and `end` the one after the last, so `end` is never less than `start`, which the guard checks. The header requires `id`, `format_version`, `created_at`, `actor`, `state` and `ops`. It may add a one-line `title`, a `confidence` between 0 and 1, and `provenance` (capture event ids, the clerk's interpretation id, the producer). New records carry placeholder ids (section 5.6). A proposal is stored as `.sprava/proposals/<id>.json` and rewritten on each state change. A proposal file the implementation did not create is never shown as the clerk's or a brain's work (section 7.2).

States:

- `proposed`: waiting for the user. The review card shows the provenance, the confidence and the spans of source text each op came from.
- `approved`: the user accepted it, possibly after editing the ops on the card. Transient: the implementation applies it at once.
- `applied`: every op was applied, in order, as one batch. The applied ops carry `proposal` and `batch` set to the proposal id, `seq` from 0, `batch_size` and `approved_by`. The proposal records `applied_at` and `applied_ops`.
- `rejected`: the user declined; `rejected_at` and an optional `rejected_reason` are kept. Nothing was applied. A rejected proposal is deleted after 90 days unless the user keeps it (a proposed default; section 12 asks).
- `superseded`: a newer proposal replaced it before a decision, for example a re-interpretation of the same capture after a correction in the source. `superseded_by` points at the newer one.

A batch is applied as a whole: if the transaction guard rejects any op, none is applied, the proposal stays `proposed`, and the card shows the reason. Tier 1 and Tier 2 proposals look identical (decisions.md A5). A drain is the one exception: each completion is guarded on its own, and the accepted ones form the batch (section 8.3).

The complete list of changes applied without a proposal:

- the user's own direct actions in the app (actor `user`), among them `set_disclosure`, `rename_teka` and `expunge`, which only the user can apply;
- mechanical, lossless adoption steps (actor `import`, section 9.4 step 3), shown together on one card the user can undo;
- `import_snapshot`, `external_edit` and `abort`, which record facts and decide nothing;
- completions drained from the hub's outbox (actor `external`, section 8.3).

Anything that closes an item at adoption, and the `migrate` that stamps the catalog (section 9.4 step 6), goes through a proposal.

### 6.6 Replay

The op log is self-contained. State 0 is `import_snapshot.args.catalog`. Applying each later op in order, skipping aborted ones, yields a sequence of states; the content hash of each must equal that op's `after_hash`. An `external_edit` is applied by applying its patch. Replay rebuilds the catalog only: it never moves a file or checks that one exists. A reader that meets a hash mismatch reports the op and stops. Replay is how `.sprava/snapshot.json` and the cursors are rebuilt (section 7.2). A conformance check replays the sample op log of section 10.9 and reproduces every `after_hash`.

A log that fails replay, for example because two implementations once disagreed on an effect, is not stuck forever. With the user's consent, the implementation appends a new `import_snapshot` that holds the catalog as it is now, with both hashes equal to its hash and a survey that says why. Replay then starts again from the latest `import_snapshot`, and ops before it stay in the file as history that is no longer checked.

### 6.7 How direct edits are absorbed (decisions.md F1)

Terminal agents and lifeproj edit `catalog.json` directly today, and the author wants that to keep working. Under the lock (section 4.9), before applying anything, a full implementation compares four values:

- `H`, the content hash of the catalog as found;
- `a`, the `after_hash` of the last op in the op log;
- `b`, the `before_hash` of the first op of the trailing write, which is the last complete batch, or the last single op;
- `S`, the content hash of `.sprava/snapshot.json`.

The snapshot is rewritten only after a catalog rename has succeeded (section 6.9). So `S = a` means the trailing write reached the disk, and `S = b` means it did not, or that a crash came between the rename and the snapshot update. Then the implementation:

1. parses the file. If it does not parse or is not a JSON object, the teka is corrupt (section 9.6): the implementation stops writing to it and tells the user. It never repairs the file on its own. When the op log replays to a consistent state, or the snapshot is usable, it offers to restore the catalog from that state, and the user decides. This covers a catalog left empty or torn by a power loss. A duplicate key, a lone surrogate or an out-of-range integer puts the teka in needs attention instead (section 4.8).
2. If `H = a`, nothing changed outside. If also `S ≠ a`, a crash came after the rename and before the snapshot update, and the implementation rewrites the snapshot from the catalog.
3. If `H = b` and `S = b`, a write was cut short by a crash: it was logged but never renamed into place. The implementation rolls it forward. It applies those ops again, which gives the same `after_hash` because ops are pure, and finishes a logged file move as section 6.9 says. No external edit is recorded. If rolling forward is impossible, for example because a filed file is missing from both places, it appends an `abort` that names those ops, and the teka needs attention.
4. If `H = b` and `S = a`, the write reached the disk and someone then put the catalog back as it was, for example with `git checkout` or a restore from backup. The implementation does not roll forward. It records the revert as an `external_edit` (step 5) and shows the card of step 6. When the snapshot is missing and `H = b`, the two cases cannot be told apart, and a card asks the user whether to apply the logged change again or to record that it was undone.
5. Otherwise, someone edited the file. The expected state is the snapshot when `S = a`. When `S = b`, the trailing write never took effect: an `abort` names its ops first, and the expected state is the snapshot. When the snapshot is missing, or `S` is neither value, the expected state is the state after the last op, rebuilt by replay, and nothing is aborted. Then the implementation computes an RFC 6902 patch from the expected state to the parsed value and appends an `external_edit` op with `before_hash` equal to the expected state's hash and `after_hash` equal to `H`. It updates the snapshot. The `external_edit` writes nothing into the catalog, so the next read finds a match.
6. checks whether the external edit undid the user's own change. When the patch puts back, on every path the last batch changed, the value that path had before that batch, another program has overwritten that change. That is what happens when a program that skips the lock reads the catalog before the implementation writes and renames its own copy over it afterwards, as today's lifeproj can (section 9.8). The app labels the edit "a change of yours was overwritten by another program" and offers a card that applies the lost ops again, as new ops by the user. The loss is never absorbed silently.
7. validates the found catalog. Records that break their level's rules put the teka in the needs-attention state for those records only: ops that touch them are refused, other ops proceed, and the dashboard is still regenerated with a warning. A repair proposal is offered. When an edit put `status: done` into a v0 catalog, the repair is a `complete`, because lifeproj's manual tells agents to mark items done (section 9.8). A compact or week date gets a proposal that rewrites it.

One case stays ambiguous: a crash after the rename and before the snapshot update, followed by an outside edit before the next read. Step 5 then aborts a write that did take effect, and its effect shows up inside the `external_edit`. The catalog is right; only the attribution of that change is lost.

A `hint` may name the likely editor when the patch makes it obvious, for example a closure entry whose `via` is `lifeproj drain`.

### 6.8 Projection from ops to `processing_log[]`

lifeproj's closure rule is that any processing log entry with an `id` closes that item, and its checker reports an open item whose id appears in the processing log as "reused" (`templates.py`, `check_open_items`; test `test_validate_flags_each_rule`). The projection keeps that rule true. Only the ops below write a log entry, and every value in the entry comes from the op and the catalog before it:

| Op | Log entry written |
| -- | ----------------- |
| `complete` (closing), `drop` | `{id, title, action: done or dropped, at, closed_at, source, via, op_id, kind?, note?, final}`; `note` comes from the op's `note` or `reason`, and `title`, `kind` and `final` from the item as section 5.10 says |
| `complete` or `drop` of an item whose id already closes an earlier entry | `{item, title, action: "closed-duplicate", at, closed_at, source, via, op_id, kind?, note?, final}`, the same entry without `id`, so no closed id repeats |
| `complete` (advancing a recurring item) | `{item, action: "occurrence", at, due, next_due, source, via, op_id, note?}`, with `due` from `occurrence_due`; no `id`, so the item stays open |
| `reopen` | `{item, reopened_from, action: "reopened", at, source, via, op_id}`, with `item` the new id and `source` the actor kind |
| `file_document` | `{document, action: "filed", at, source, via, op_id}`, with `source` from the document's `source`, else the actor kind |
| `add_log_entry` | the entry as given, with `at`, `via` and `op_id` set, replacing any values it carried |
| every other op, including `import_snapshot`, `migrate`, `external_edit` and `abort` | nothing; the op log alone records it |

`at` is the op's `at`, and `via` is the actor's `client`, the program and version of the implementation that applied the op (section 6.2). A `migrate` that should leave a log entry includes the entry in its own patch, so its `after_hash` covers it. Only closure entries carry `id`. An op id is never written as `id`.

The `closed-duplicate` row repairs a state that lifeproj's manual produces. The manual tells agents to log completed work in the processing log and to drop the item only "once it has shown as `done` once" (`templates.py`, `CLAUDE_HEADER`). An agent that logs a closure with the item's id before it removes the item leaves an open item whose id is already closed, which lifeproj's checker reports as reused. Without this row the item could never leave `open_items[]`: ids are never rewritten, the processing log is never rewritten, and a second entry with the same `id` would be a new duplicate. Adoption proposes a `complete` for each such item (section 9.4 step 4).

### 6.9 `.sprava/ops.ndjson`

- One op per line, UTF-8, newline-terminated, compact JSON (no indentation inside a line).
- Append-only, apart from the expunge procedure (section 6.11).
- One change is written in this order, under the lock (section 4.9):
  1. Build the ops, mint ids, run the guard and compute every `after_hash`.
  2. Write the new catalog to a temporary file, flush it with `F_FULLFSYNC`, and check that `catalog.json` has not changed since it was read (section 4.9 steps 4 and 5).
  3. Append all the lines of the change in one write: a single op, or a batch whose lines carry `batch`, `seq` and `batch_size`. Then flush the op log with `fcntl(F_FULLFSYNC)`; plain `fsync` does not reach stable storage on macOS.
  4. For a `file_document` with `from`, move the file with a rename that fails when the destination exists (on macOS, `renamex_np` with `RENAME_EXCL`). The guard has already refused a destination that exists.
  5. Rename the temporary file over `catalog.json`, then `fsync` the teka folder.
  6. Update `.sprava/snapshot.json`.
- A crash between steps 3 and 5 leaves ops in the op log that the catalog does not show yet. Section 6.7 step 3 rolls them forward on the next read and never mistakes them for an external edit. A crash between steps 5 and 6 leaves a stale snapshot, which section 6.7 step 2 rewrites. A logged `file_document` is rolled forward like this: if the source is still in `intake/` and the destination is free, move it, then write the catalog; if the source is gone and the destination holds a file with the recorded `sha256`, write the catalog only; in any other case, `abort` and needs attention.
- A torn last line (no trailing newline), and a trailing batch with fewer lines than its `batch_size`, never took effect: the catalog is written only after the whole change is in the op log. A reader ignores them, and the next append first truncates them, after copying them to `.sprava/torn/<timestamp>.ndjson`, where `<timestamp>` is the time of the copy written without colons (section 7.2).
- The first line is an `import_snapshot`. For a teka created by an implementation, that snapshot is the freshly scaffolded catalog.
- The op log is private to the teka and lives inside it, so a backup of the folder carries history too.

### 6.10 Undo (decisions.md A2, A5)

Undo is a new op that reverses an earlier one and names it in `compensates`. The op log keeps both.

| To undo | Append |
| ------- | ------ |
| `add_item` | `drop` with the reason "undo" |
| `update_item` | `update_item` that restores the earlier values: `set` for fields that changed or were removed, `unset` for fields that were added |
| `set_status` | `set_status` back, with the earlier waiting fields |
| `complete` or `drop` that closed an item | `reopen`: a new id, the title and kind from the closure entry and the other fields from its `final`. An entry without `final`, such as one lifeproj's drain wrote, takes the item's last state from the op log instead: the snapshot, or a replay up to the op that closed it. Only when the op log has no state for the item does the user fill in the fields. |
| `complete` that advanced a recurring item | `update_item` that sets `due` back to `occurrence_due`; the occurrence entry stays |
| `dismiss`, `undismiss` | the other one |
| `file_document` | `update_document` to correct the record. The file stays where it is; no op moves a file back. |
| `update_document`, `set_meta` | the same op, restoring the earlier values |
| `set_disclosure` | `set_disclosure` back. What the hub already received is not recalled (section 5.5). |
| `rename_teka` | No op undoes it. Rename the folder back and apply `rename_teka` again. |
| `add_log_entry`, `external_edit`, `import_snapshot`, `migrate`, `abort`, `expunge` | Cannot be undone; they record facts. The change an external edit made can be reversed with ordinary ops. |

Reopening gives the item a new id, because a closed id is never reused (section 5.1). The hub therefore sees a new item, and the old id stays in the slice's `closed[]` until it ages out. A completion drained from the hub by mistake is undone the same way.

### 6.11 Forgetting a text (expunge)

Dictated captures can hold things that should not be kept, such as an account number or a health detail. Undo removes a value from the present, but the op log, the import snapshot, older proposals and the search index still hold it. Without a way to forget, the format would keep it forever.

`expunge` is applied by the user in the app and is never proposed. The user names a text to forget, at least 4 characters long.

What it rewrites: free text only, never structure. A string is free text when the key that holds it is `title`, `slice_title`, `waiting_on`, `note`, `reason`, `rejected_reason`, `hint` or `tags` (each entry of `tags`). The rule applies wherever such a key sits: in items and their `final`, in log entries, in document records, in op `args` (`item`, `entry`, `document`, `set`) and in proposals. A JSON Patch step counts by the last segment of its `path`, so a step that replaces `/open_items/2/title` holds free text. A string under a key this document does not define is rewritten only when the user confirms that match on the card. Nothing else is touched. Object keys, ids, op and proposal UUIDs, hashes, `sha256`, dates, timestamps, `path`, `link`, `meta.name`, `contexts` and closed-list values keep their bytes. Rewriting them would break the ids that closures and the hub refer to, the records that point at files, and the hash chain. A year such as `2026`, or four digits that happen to occur inside a hash, therefore changes nothing structural.

Before anything is written, the confirmation card shows every match by place. When the text also occurs where expunge cannot reach it, the card lists those places and says what the user can do by hand: a file name to rename, an id that cannot change, a capture event. Those matches stay.

Under the lock, the implementation:

1. builds rewritten copies of `catalog.json`, every op line (the import snapshot included), every proposal, `snapshot.json`, the Notes section of `DASHBOARD.md`, the saved copies under `.sprava/adopted/` and the torn-line copies under `.sprava/torn/`. In each, every occurrence of the text inside a free-text string becomes `[expunged]`. A saved copy is parsed, rewritten and written back, so it is no longer byte-exact; a saved dashboard is rewritten as text.
2. re-stamps the hashes. It replays the rewritten op log from its import snapshot and sets each op's `before_hash` and `after_hash` from that replay. The whole log then verifies again, and it holds no hash of a state that contained the text. The replayed state must equal the rewritten catalog, and the transaction guard must accept that catalog; otherwise the expunge stops before anything is written.
3. adds an `expunge` op whose two hashes equal the new head. It records how many values were replaced in each place, the ids of the rewritten op lines and an optional reason. It never records the text or a digest of it: a short secret such as a 4-digit code or an account number can be recovered from its SHA-256 in seconds by trying every candidate.
4. writes the files, each through a temporary file and a rename, with `catalog.json` last. Before the first rename it creates an empty marker, `.sprava/expunge-pending`, and removes it after the last. While the marker exists, the implementation reads nothing else in the teka: it asks the user to enter the text again and repeats the expunge, which leaves files already rewritten as they are.
5. clears `intake/_converted/`, which can be regenerated. It builds a new `index.sqlite` with SQLite's `secure_delete` on, then deletes the old file with its `-wal`, `-shm` and `-journal` files. It clears the slice hash in `.sprava/cursors.json` and, with the federation profile on, republishes the slice at once, or removes it at disclosure level `none`.

What stays. Expunge works on the teka's own files. It cannot reach the capture folder and the clerk's interpretations, which are immutable by design (decisions.md C1, C2, C3) and which the review card's spans point into; file names and the contents of filed documents; backups made earlier (the backup keeps an archive of replaced blobs, decisions.md A6); APFS local snapshots and Time Machine; and the hub and its mirrors, such as Google Tasks. The confirmation card lists each of these. On a copy-on-write volume, rewriting a file makes the old text unreadable through that file; the old blocks can survive on the disk until they are reused. Whether expunge belongs in v0 is an open question (section 12).

## 7. Derived files

### 7.1 `DASHBOARD.md`

lifeproj seeds the dashboard once and has no renderer; people and agents keep it by hand (`scaffold.py` writes it from `templates.py`, `DASHBOARD_TMPL`, and no command rewrites it). lifeproj's module manuals tell agents to keep facts there that are in no catalog field: a ledger's running balance, a chapter's key facts, a comparison table of entities, and hard deadlines at the top (`modules.py`). A renderer that overwrote the file would erase them. So:

- At adoption, the survey records the file's SHA-256 and copies its bytes to `.sprava/adopted/DASHBOARD.md` before anything else is written (section 9.2).
- A full implementation never overwrites a `DASHBOARD.md` that it did not render until the user approves the switch on a review card. Until then the app shows the rendered dashboard in its own window. The approved switch moves the old text into the Notes section of the new file, below the `## Notes` line, with every heading in it demoted one level (`#` becomes `##`, and so on, `######` staying as it is), so the old dashboard's own sections stay inside Notes.
- The Notes section is everything from the first line that is exactly `## Notes` to the end of the file. It is copied unchanged, byte for byte, into each new rendering. That is where hand-kept facts belong. Headings inside it do not end it.
- A rendered file starts with a marker line, `<!-- teka-dashboard v0 sha256:<hex> -->`. The hash is SHA-256 over the UTF-8 bytes from the first byte after the marker line's line feed up to, and not including, the line `## Notes`, written as 64 lowercase hex digits. The file uses LF line endings only. Before it renders again, the renderer recomputes that hash. If it differs, someone edited the file outside the Notes section: the renderer first saves the edited file as `.sprava/adopted/DASHBOARD-<timestamp>.md` and tells the user. An edit inside Notes changes no hash and saves nothing.

Rules:

- The file is regenerated whenever the catalog's hash changes and at least once per calendar day.
- Its inputs are the catalog, `today`, the user's time zone (Recently closed depends on it, section 5.2), whether `CLAUDE.md` exists, and the Notes section. The same inputs give the same bytes.
- Two implementations produce the same bytes apart from the header line, which names the implementation, and the marker line, whose hash covers the header line. A cross-implementation comparison ignores those two lines.
- Redaction does not apply; the file is inside the teka.
- Hidden items are counted, not listed.
- Lines never carry a time of day. The only date that is not in the catalog is `today`.

Template (angle brackets are placeholders; `<impl>` is the implementation's `program/version`):

```markdown
<!-- teka-dashboard v0 sha256:<hex> -->
# <meta.name>: dashboard

_Current truth as of <today>, regenerated from `catalog.json` by <impl>. Edit only the Notes section; the rest is overwritten._

## At a glance

- <n> open items: <overdue> overdue, <today_count> due today, <waiting> waiting or blocked (<nudge> to chase), <hidden> hidden
- <documents> documents on file, <closed7> closed in the last 7 days
- Active chapters: <a>, <b>          (only when meta.active_chapters is non-empty)

## Overdue
## Today
## Next 7 days
## Later
## No deadline
## Nudge
## Waiting
## Recently closed

## Where things live

- Modules: <meta.modules joined by ", ">   (or "none")
- Manual: `CLAUDE.md`                          (only when the file exists)

## Notes

<kept as written>
```

The counts: `<n>` is every item in `open_items[]` that is not `done` and not dismissed, waiting ones included. `<overdue>` and `<today_count>` are the sizes of those buckets. `<waiting>` is Nudge plus Waiting, and `<nudge>` is Nudge alone. `<hidden>` is the dismissed items. `<documents>` is the entries of `documents[]`, and `<closed7>` is the dated entries of Recently closed; a `done` item with no date is listed there but not counted.

Each bucket section lists its items, one per line, in the order of section 5.2, or the single line `_None._` when empty. The line formats:

- dated buckets: `` - `<id>` <title> · due <YYYY-MM-DD> (<rel>) · <priority><ctx><tags> ``;
- No deadline: `` - `<id>` <title> · no deadline · <priority><ctx><tags> ``;
- Nudge and Waiting: `` - `<id>` <title> · waiting on <waiting_on> · follow up <YYYY-MM-DD or "not set"> (<rel>) · due <YYYY-MM-DD or "none"> · <priority><ctx><tags> ``;
- Recently closed: `` - `<id>` <title> · <action> <YYYY-MM-DD> ``, with the entry's `action` as written (`done`, `dropped`, or a legacy value such as `completed`) and the local closing date, and `(no title)` when the entry has none. A `done` item still in `open_items[]` reads `` - `<id>` <title> · done (date unknown) ``.

The id is written as a code span. Its fence is a run of backticks one longer than the longest run of backticks inside the id, with a space inside each fence when the id starts or ends with a backtick, as CommonMark specifies. Backslash escapes do not work inside a code span, so the id is not escaped further. An id that is not a string is written as its canonical JSON text.

`<rel>` is `today`, `tomorrow`, `yesterday`, `in N days` or `N days ago`, with N of 2 or more. `<ctx>` is ` · ` followed by the contexts joined by spaces when the item has any; `<tags>` is ` · ` followed by the tags joined by spaces when it has any.

Every string from the catalog is escaped before it is written. Newlines and tabs become spaces. Control characters (C0 and C1) and the bidirectional controls U+202A to U+202E and U+2066 to U+2069 are removed. Each of the characters `` \ ` * _ [ ] ( ) < > ! # | `` gets a backslash in front. The file never holds raw HTML from the catalog. So a title such as `![x](https://tracker.example/p.png)` shows as plain text and makes no network request when the file is previewed by Quick Look, an editor or a git host. The same escaping applies to catalog strings in any Markdown or HTML view an implementation renders. A filed document is not escaped, since that would ruin it; a view of it follows the no-remote-resource rule of section 3.4 instead.

### 7.2 `.sprava/`

The folder belongs to the full implementation that adopted the teka (decisions.md F1). It is created with mode 0700 and its files with mode 0600, and the survey reports wider modes, because the op log holds history and `slice-key` ties aliases back to raw ids. Its contents:

| File | What it holds | Rebuildable? |
| ---- | ------------- | ------------ |
| `ops.ndjson` | The op log (section 6.9). | No. It is history. Losing it loses history, never state, because the catalog is the truth of state and closure entries keep the closed items (section 5.10). |
| `proposals/<id>.json` | Proposals and their states (section 6.5). | No. Losing them loses the provenance detail of proposals that were never applied; applied ops still carry their proposal id. |
| `adopted/` | `catalog.json` and `DASHBOARD.md` as found at adoption, byte for byte, and any hand-edited dashboard saved before a new rendering (section 7.1). | No. |
| `torn/` | Op lines cut off by a crash, copied before they are truncated (section 6.9). | No, and nothing needs them. |
| `slice-key` | The key for aliases (section 5.6). | No. Losing it changes the aliases. |
| `snapshot.json` | The catalog as of the last catalog write that succeeded, used to tell a crash from a hand edit and to compute external-edit patches (section 6.7). | Yes, by replay (section 6.6). |
| `cursors.json` | Cursors: the last op id and hash; the capture events consumed per capture folder (decisions.md C2), keyed by the folder's path written as `~/...`; the last published slice's hash, `generated` stamp, each recurring item's published `due`, and the id each item was last published under (section 5.6); the last drain. | Yes: from the op log, the proposals' provenance, the slice key, `meta.former_names` and the spool. |
| `index.sqlite` | The per-teka full-text index (decisions.md A3), covering only what section 3.4 allows. | Yes, from the catalog and the documents. |
| `expunge-pending` | An empty marker that exists only while an expunge is being written (section 6.11). | Not applicable. |

Any other file an implementation keeps there must be rebuildable, and a second implementation must ignore files it does not know.

Files under `.sprava/` are untrusted when read. Any program that can write the teka can plant one there: a terminal agent misled by a filed email (section 3.4), a restored backup, or a teka received from someone else. So:

- every file is validated against its schema when it is read;
- the implementation keeps, outside the teka, a list of the proposal ids it created. A proposal file not on that list is shown as "found in the folder, origin unknown", never as the clerk's or a brain's work, and is never applied without the user editing or confirming each op;
- `index.sqlite` is opened only when this installation created it, and always with SQLite's defensive settings (`SQLITE_DBCONFIG_DEFENSIVE` on, `trusted_schema` off). Otherwise it is rebuilt;
- a `slice-key` that this installation did not make is reported before it is used, since it would change the published aliases. Paths stored under `.sprava/`, or in the survey, are relative to the teka or start with `~/`; they never contain a user name. The runtime's single-instance lease and heartbeat are not kept inside a teka (decisions.md A1).

## 8. The federation profile (optional)

An implementation that publishes slices and drains completions follows this profile, because the existing hub reads them today and must keep working while tekas move over one at a time (decisions.md A8). The hub never reads inside a teka; a teka never reads the hub's files. Both read the spool.

### 8.1 The spool

- Root: `$OSAVUL_SPOOL` when set; else `$XDG_DATA_HOME/osavul` when `XDG_DATA_HOME` is set; else `~/.local/share/osavul` (`osavul.py`, `spool_root`).
- Layout: `inbox/<teka>.agenda.json` (the teka writes, the hub reads), `outbox/<teka>.intake.json` (the hub writes, the teka drains), `state/` (the hub's own; never touched by a teka).
- The user turns the spool on by creating its root folder. A publisher never creates the root. When the root is absent, publishing is a quiet no-op: a one-line hint, success, nothing written (test `test_publish_noop_when_spool_absent`). The publisher creates `inbox/` under an existing root.
- Ownership. The root, `inbox/` and `outbox/` must belong to the user and must not be writable by group or others. A publisher creates folders with mode 0700 and files with mode 0600, and refuses an `inbox/` or `outbox/` that is a symlink. `$OSAVUL_SPOOL` can point anywhere; an implementation warns when the root lies inside a folder that a sync service uploads, such as iCloud Drive, because slices would then leave the Mac (decisions.md A7).
- Registration is the slice file appearing. There is no registry call.
- A teka at disclosure level `none`, or one that never publishes, is invisible to the hub by design, never an error.
- One publisher and one drainer per teka. A teka whose `meta.format` is `teka` is published and drained only by an implementation of this profile that reads `meta.disclosure`, `dismissed` and `recurrence` and takes the lock of section 4.9. Today's lifeproj does none of this. It projects every item at full disclosure, dismissed ones included, with real ids in place of aliases; it closes a recurring item for good, with a closure entry that has no `final`; and its fleet drain republishes every teka it drained (`osavul.py`, `project_slice`, `_drain_teka`, `drain_all`).
- lifeproj can reach a teka without its registry. The manual lifeproj stamps into each teka tells terminal agents to run `lifeproj drain` first and `lifeproj publish` last in every digest (`templates.py`, `CLAUDE_HEADER` and `CLAUDE_OSAVUL`), and both commands work on the current folder whether or not it is registered (`osavul.py`, `publish` and `drain`). So a teka counts as reachable by lifeproj when it is in lifeproj's registry, holds lifeproj's `catalog_check.py`, or has a `CLAUDE.md` or `AGENTS.md` that mentions `lifeproj publish` or `lifeproj drain`. Until the change of section 9.8 ships and the user confirms that the lifeproj they use has it, an adopted teka that lifeproj can reach keeps disclosure level `full`: the app offers no other level, refuses `dismiss` and `recurrence` on it, and says why. The manual addendum of section 9.8 is a precondition for anything stricter, because an agent following the old manual would undo it.
- A publish by someone else is noticed. Before it publishes, and when it drains, an implementation compares the slice on the spool with the hash of the slice it last wrote (`.sprava/cursors.json`). When they differ, another program published the teka: the implementation republishes at once, or removes the slice at disclosure level `none`, and tells the user which teka was affected.

### 8.2 Agenda slice v1

The slice is lifeproj's frozen contract plus additive fields (decisions.md F8 names four; this draft adds a fifth, `disclosure`). The file is JSON with two-space indentation and a trailing newline, written to a temporary file in `inbox/` created exclusively under a random name that starts with `.` and ends with `.tmp` (section 3.6), then renamed into place. A hub never reads a name that starts with `.`. lifeproj writes `json.dumps(obj, indent=2)` to a fixed temporary name (`osavul.py`, `publish`); that byte form is informative, and a reader accepts any valid JSON.

Top level, in this order: `teka` (`meta.name`, else the folder basename), `lifecycle` (`meta.lifecycle`, null when absent, not validated), `active_chapter`, `active_chapters`, `generated`, `items`, then the v1 additions `format_version` (`"1"`), `disclosure` (the teka's level) and `closed`.

- `active_chapters`: `meta.active_chapters`, falling back to `meta.current_chapters` when the former is absent; a bare string becomes a one-element list; empty strings are dropped; default `[]`. `active_chapter`: `meta.active_chapter` as is; when it is null and exactly one chapter is active, that chapter; else null (test `test_active_chapters_projection`). At disclosure levels `title` and `kind` both are masked (section 5.5).
- `generated`: a timestamp, `YYYY-MM-DDTHH:MM:SSZ`. The hub derives staleness from it; a reader also tolerates an offset form.
- `items`: one object per item of `open_items[]` that is not `dismissed`, in catalog order. Each has exactly these nine keys in this order, then the v1 additions: `id`, `title`, `status`, `priority`, `due`, `no_deadline`, `tags`, `waiting_on`, `link`, then `kind` and `follow_up_at` when the item has them. Defaults at projection: `due` null, `no_deadline` the boolean value of the field (absent is `false`), `tags` `[]`, `waiting_on` null, `link` null (test `test_project_slice_shape`). Every other catalog field is dropped and does not reach the hub.
- Ids: prefixed, checked for collisions and aliased as sections 5.5 and 5.6 say.
- Redaction: as section 5.5 says, per disclosure level.
- Items whose `status` is `done` (an unadopted lifeproj catalog) are published as lifeproj publishes them; readers skip `done` (`brief.py`, `collect`; test `test_items_land_in_urgency_buckets`). A v0 implementation never has them.
- Validation before publishing: every item is validated against lifeproj's v2 item rules regardless of `schema_version`, and the projected ids must be unique. On any error nothing is written and the command fails (tests `test_publish_rejects_invalid_open_items`, `test_publish_writes_valid_slice`). A v0 publisher writes `due` as `YYYY-MM-DD`; the slice schema of section 10.7 describes what a v0 publisher writes.
- `closed`: closure entries of the processing log in the Recently closed window (section 5.2), each as `{id, action, closed_at, kind?}`, with `action` `done` or `dropped`; entries with other actions are left out. Titles are never published in `closed[]`. A hub that does not know the field ignores it.
  - The id is the id the hub last saw for that item, from the map in `.sprava/cursors.json` (section 5.6). When the map has none, the id is projected like an item id under the rules of section 5.5, reading `redact` from the entry's `final`. An entry without `final` (one lifeproj's drain wrote) is aliased below disclosure level `full` when its id is not in the recommended form, and prefixed at `full`, as lifeproj would.
  - `closed_at` is the closing date of section 5.2. At disclosure level `full` it is the closing moment converted to UTC, with any fraction of a second dropped. Below `full` it is the local closing date written as `<date>T00:00:00Z`, so the hub learns the day and not the hour at which the user works on a matter. A closing value that is only a date is written the same way at every level. A closing date later than today is written as today.

### 8.3 Outbox v1 and drain

The outbox file is `outbox/<meta.name>.intake.json`. lifeproj's drain semantics are kept (`osavul.py`, `_drain_teka`; decisions.md F8):

- Read only `completions` (default `[]`). `items[]` is preserved untouched. `teka` and `generated` are ignored. The v1 `format_version` is ignored too.
- A completion has `id` (required), `action` (`done` or `dropped`; anything else is skipped), optional `at` (copied into `closed_at`) and optional `source` (default `osavul`). Outbox v1 adds an optional `due`: the due date the hub showed when the item was checked off. A hub that does not know the field leaves it out.
- Matching: the id is resolved against, in this order, the raw catalog id; `<teka>-<raw id>`, an integer id written in decimal; the alias of any open item, whether or not it is redacted now; and the id each item was last published under (section 5.6). The first match wins (test `test_drain_resolves_prefixed_slice_id`).
- Per completion: skip when the id is missing, the action is unknown, the id is unknown, or the item is already gone; otherwise close it.
- The catalog is written first, under the lock and atomically, and only when something was applied. Then the outbox is acknowledged by removing the applied completions. Unknown completions linger forever (tests `test_drain_applies_done_and_dropped`, `test_drain_idempotent_and_preserves_items`).
- Re-running is a no-op. A drain never republishes by itself; a digest, or an implementation's next publish, does.
- Exit behaviour: spool absent, hint and success; no outbox, "nothing to drain" and success; invalid outbox JSON, failure; no `catalog.json`, "not a teka" and success; invalid `catalog.json`, failure.

After a rename. With the federation profile on, applying `rename_teka` removes `inbox/<former name>.agenda.json` and publishes under the new name at once. Every published id changes with the name: prefixed ids carry the new name, and ids minted under the former name are aliased where section 5.5 says. The hub therefore sees every item replaced by a new one, and the rename card says so before the user applies it. Until each former name's `until` date, the drain also reads `outbox/<former name>.intake.json`, and there it also resolves `<former name>-<raw id>` and aliases made with the former name.

Acknowledging without losing the hub's writes. The hub writes the outbox without the teka's lock, which covers only files inside the teka (section 4.9). lifeproj's drain rewrites the outbox from the copy it read before applying anything, so a completion the hub adds in between is erased everywhere, and its item stays open. An implementation of this profile acknowledges like this instead:

1. Just before acknowledging, read the outbox again and hash its bytes.
2. From that fresh copy, remove only the completions that were applied, matched by `id` and `at`; one with the same id and a different `at` is new and stays. Also remove a completion that an earlier drain applied but could not acknowledge because it crashed: its item is already closed by a drained closure entry with the same id and a `closed_at` equal to its `at`.
3. Write the result to a temporary file (section 3.6), read the outbox once more, and rename only when its hash has not changed since step 1. Otherwise go back to step 1.
4. Delete the file, instead of writing it, only when the fresh copy holds no completion, no `items` and no key this document does not define.

This shrinks the window to the moment between the last read and the rename. It cannot close it while the hub takes no lock; section 12 asks whether the hub should lock the outbox or write one file per completion.

In a full implementation:

- Each completion is checked on its own. Before ops are built, a `source` that is absent or not a string becomes `osavul`, and an `at` that is not a string becomes null, with the original value kept in the op's `note`. A completion that still cannot form an op the transaction guard accepts is skipped, left in the outbox, and reported with the teka's name and the published id, never the title. One bad completion never blocks the others.
- Each accepted completion is one op with actor `{kind: "external", client: <the implementation's program/version>, origin: "spool-outbox"}`, and the completions applied by one drain form one batch.
- The op is `complete` for `done` and `drop` for `dropped`. `args.closed_at` is the completion's `at` as normalized above, which may be null. `args.source` is its `source` as normalized above.
- The closure entry also carries `at` (the drain time), `op_id`, `kind` and `final`, and its `via` names the implementation instead of `lifeproj drain`.
- Recurring items. A `done` completion for a recurring item advances it (section 5.4) instead of removing it, at most once per occurrence:
  - when it carries `due` equal to the item's current `due`, the item advances, and the op's `occurrence_due` is that date;
  - when it carries an earlier `due`, it repeats an occurrence that has already advanced, for example a tick in the hub's mirror after the app completed the same occurrence. It is acknowledged and removed, and nothing changes;
  - when it carries no `due`, which is what today's hub sends, or a later one, it is not applied on its own. A card asks the user whether that occurrence is done. Either answer acknowledges the completion.
  A `dropped` completion ends the series.
- The app shows each drained batch as an external change the user can undo (section 6.10).

These are the deliberate departures from lifeproj's drain, and the only ones. Once an item carries `recurrence`, the hub must not advance or close it on its own; section 12 asks how the hub learns that.

### 8.4 Hub tolerance rules

A slice reader `[H]` (section 1.6), such as the hub or a cross-binder view in an implementation:

- ignores unknown top-level keys and unknown item keys; a slice without `format_version` is a lifeproj slice;
- treats an absent slice as an invisible teka, never an error;
- flags a malformed or missing slice by file name only, never by title, and logs parse errors without content (the hub does this today);
- derives staleness from `generated` and flags a slice older than 7 days (`brief.py`, `STALE_DAYS`);
- drops anything a slice's `disclosure` would hide, for example a real title in a slice at `kind`;
- writes completions idempotently by id, never a duplicate, and adds `due` to a completion when the slice item had one (section 8.3);
- never reads a file in `inbox/` whose name starts with `.`, since that is a publisher's temporary file;
- never writes anything into a teka.

The existing hub's behaviour on unknown keys has not been verified from its code (its documents are private); it is an open question (section 12).

### 8.5 Annex, informative: the briefs lane

The hub has a provisional lane for readable documents. It is a product feature, not part of this format (decisions.md F8). For orientation only: `briefs/<binder>/manifest.json` holds `{teka, generated, briefs[]}` where each brief has `id`, `file` (one path segment ending in `.md`), `title`, `summary`, `kind`, `event_date`, `doc_date`, `tags`, `bytes`, `updated`, `status` (`published` or `pending`) and `pin_current`; the documents live in `briefs/<binder>/docs/<file>.md`; current versus archive is recomputed on every read; the lane is read-only; containment rules apply (an allowlist, one path segment, no symlinks, a 404 for every refusal). In Sprava, documents readable in the app replace it.

## 9. Adopting an existing teka

### 9.1 The rule

A full implementation adopts a teka in place (decisions.md F1). It never copies a teka into a store and converts no file. It owns only `.sprava/`, `catalog.json` (through ops) and `DASHBOARD.md` (after the switch of section 7.1). Section 9.7 says exactly what it may write; everything else is left as found.

### 9.2 The survey

Adoption begins with a read-only survey whose results are recorded in the `import_snapshot` op. The results hold counts, kinds of problems and record ids, never personal values.

1. Parse `catalog.json` and classify the teka's state (section 9.6). Corrupt: stop.
2. Read the catalog level (section 9.6).
3. Classify `catalog_check.py` by the SHA-256 of its bytes, without running it. This is the checker version:

   | Checker version | lifeproj commit | SHA-256 of the stamped file |
   | --------------- | --------------- | ---------------------------- |
   | gen1, loose, stamped `schema_version: 1` | `b950006` (2026-06-26) | `cbc841229a12f0ca538f9f26af9a7e4a7f9208a185b2ab1ad1c43055bda8da24` |
   | gen2, strict without the `redact` and `slice_title` type checks | `c3658fc` (2026-06-30) | `dc19265c394fb10637238ccb4b20a68970606413741b85333c7d1471a9056cdd` |
   | gen3, current | `cf6ddd6` (2026-06-30) and HEAD | `b13dcf01647a88e16edf24b1cab2205054709753025b26e546e62069851c916d` |

   Any other hash is "modified or unknown"; per-teka variation of the checker is legitimate in lifeproj, and the implementation validates with its own rules whatever the copy says.
4. Count items by status. Note `done` items inside `open_items[]`, waiting or blocked items without `follow_up_at`, items that fail lifeproj's v2 rules, and open items whose id already closes a processing log entry (section 6.8). Note, by kind of difference, items that pass lifeproj but break a v0 rule: an empty or null `due`, a compact or week date, a null `waiting_on` or `link`, non-string tags, a redacted item without `kind`, ids that are neither strings nor integers, and ids that hold whitespace, non-ASCII, format or control characters, or that are not in the recommended form and contain a run of four or more letters (section 5.6).
5. Classify ids: all in the recommended form (`teka-year-seq`) or not (`opaque`). Note ids whose slice projections collide (section 5.6).
6. Note non-ASCII escaping (`\uXXXX`) so the first rewrite's byte change is expected.
7. Find absolute paths from another machine in `link` and `path` fields and in any string that starts with `/Users/`, `/home/` or `~/`, and links that are not paths (a URL or another scheme). Report them; never rewrite or open them. lifeproj's own restore does the same (`stale_paths.py`; test `test_data_json_is_not_rewritten`).
8. Note `documents[]` records lacking `id`, `title` or `path`, and `entities[]` rows lacking `status`. Legacy processing log entries are accepted as they are.
9. Note which module folders exist, to propose `meta.modules`, and every found value under a v0 field name that the v0 types reject, by field name only. The names that can collide are `kind`, `date`, `source`, `sha256`, `path`, `title`, `created`, `lifecycle`, `provenance`, `contexts`, `derived`, `follow_up_at`, `expected_by`, `recurrence`, `disclosure` and `id_scheme` (section 9.5).
10. `DASHBOARD.md`: its SHA-256, whether this format's renderer wrote it (the marker line), and the path of its saved copy (section 7.1).
11. `meta.name`: whether it is present, equals the basename (section 3.1), has the recommended shape, and is unique after case folding among the tekas the implementation knows, their unexpired former names included. Also whether lifeproj can still reach the teka, by the test of section 8.1: listed in lifeproj's registry, holding `catalog_check.py`, or with a manual that runs `lifeproj publish` or `lifeproj drain`.
12. Files that may send data off the Mac or hold secrets, without running them or reading their values: whether `.claude/settings.json` declares hooks (lifeproj stamps routing hooks that send prompt text to an outside service), reported as "may send data off this Mac"; `scripts/mail/.env` and other `.env` or key files (section 3.4), reported as "holds credentials"; and `intake/mail/.env` or `intake/mail/state.json`, reported as "old email-intake layout: credentials and sync state inside the intake", with a pointer to lifeproj's relocation of them to `scripts/mail/` (section 3.3).
13. Symlinks in the teka that resolve outside it (section 3.6), and modes on `.sprava/` wider than 0700 for the folder and 0600 for its files (section 7.2).
14. Whether the teka's resolved path lies in a place a sync service uploads: iCloud Drive (`~/Library/Mobile Documents/`), `~/Desktop` or `~/Documents` while iCloud's Desktop and Documents option is on, any File Provider folder under `~/Library/CloudStorage/`, or any path whose ubiquitous-item resource values say it is synced. It is reported as "this folder is uploaded by a sync service", because the catalog, the op log with its verbatim import snapshot, the proposals and `slice-key` would then leave the Mac (decisions.md A7). The app warns, and lists the teka in its inventory of what leaves the Mac.

### 9.3 What the catalog levels mean

A lifeproj v1 teka passes its own checker with loose items, yet lifeproj's `publish` refuses it, because `publish` validates strictly regardless of `schema_version` (`osavul.py`, `publish`). No lifeproj command migrates a catalog. An implementation of this format therefore validates every catalog against the rules of its catalog level and treats strict failures on a v1 catalog as "needs migration", never as corruption.

### 9.4 What adoption does, in order

1. Takes the lock, copies `catalog.json` and `DASHBOARD.md` (when present) byte for byte to `.sprava/adopted/`, and appends `import_snapshot` with the parsed catalog and the survey. Nothing else in the folder changes. The byte copy matters because the first rewrite changes the catalog's bytes (escaping and hand layout) without changing its content.
2. Renders the dashboard. It writes `DASHBOARD.md` only when the file is absent or carries the marker line; otherwise it offers the switch card of section 7.1. For a v1 catalog it renders what it can (section 5.2) and marks the teka "needs migration".
3. Applies mechanical, lossless changes without a proposal, each as an op with actor `import`, and shows them together on one card the user can undo:
   - deriving `follow_up_at` for waiting and blocked items (section 5.3), with `derived: ["follow_up_at"]`;
   - removing keys whose value is `null` (`due`, `waiting_on`, `link`), since null means absent;
   - removing an empty `due` from an item that has `no_deadline: true`;
   - rewriting a `due` in another form that section 5.2 counts as valid (compact, or an ISO week date, a missing weekday read as Monday) as `YYYY-MM-DD`, with `"due"` added to `derived` and the old value in the op's note.
4. Proposes, for the user's approval, everything that changes meaning:
   - one `complete` per item whose status is `done` (section 5.10), and one per open item whose id already closes a processing log entry, which writes a `closed-duplicate` entry (section 6.8);
   - one card per item that fails the rules, asking for what is missing (a `due` date or `no_deadline`, a party, a kind for a redacted item), since a migration cannot invent a date;
   - a `migrate` that adds `id`, `title` or `path` beside the legacy keys of each document record that lacks them, and `status` to each entity row that lacks it;
   - for a pre-lifeproj catalog (section 9.6), a `migrate` that adds `meta` with `schema_version: 1`, or adds `schema_version: 1` to an existing `meta`, keeping a found value below 1 under `legacy_schema_version` first; and for a core key that holds something other than an array, a `migrate` that copies the value to `legacy_<key>` and replaces the key with an array. For an object keyed by id, the array holds its values in order, each given its key as `id` when it has none;
   - `set_meta` for `modules`, `id_scheme` and any `meta` field the v0 types reject, keeping the old value first as section 9.5 says.
   It also offers the user a `rename_teka` when the name and the basename differ (section 3.1). That is a direct action, applied by the user, never part of a proposal (section 6.5).
5. Asks the user for `disclosure`, proposing `full` when the teka has published slices before and `none` when it has not. While lifeproj can still reach the teka, only `full` is offered (section 8.1).
6. When the catalog, once stamped, would satisfy the whole v0 schema and the conformance checks, proposes a `migrate` that stamps `schema_version: 2` (replacing any value that is not the integer 2), `name` (the folder basename, when absent), `format: "teka"`, `format_version: "0"`, `disclosure`, and empty `documents`, `open_items` and `processing_log` arrays when they are missing. Once the user approves it, the teka is a v0 teka. Until then it is adopted and "needs migration": readable, with history recorded, and accepting ops that add no new violation (section 6.3).

Prefixed and bare ids are both kept as they are. A `status: done` item is never deleted; it becomes a closure with its title and fields preserved. Non-ASCII text is written unescaped on the first rewrite; the content is identical.

Leaving. To hand a teka back to lifeproj alone, the user can restore `.sprava/adopted/catalog.json`, which loses the changes made since adoption (they stay in the op log), or remove `meta.format` and `meta.format_version` by hand. No op removes the stamp, because `migrate` never removes a key. A lifeproj with change 2 of section 9.8 publishes and drains the teka again once `meta.format` is gone. A full implementation that still watches the folder records the edit as an external edit. Section 12 asks whether v0 needs a release op.

### 9.5 Legacy keys

A `migrate` op may add v0 keys beside legacy ones (for example `path` next to a legacy `file`). It never removes, renames or reorders a legacy key. The mapping table of legacy names belongs to the implementation and is filled in once the author's structure-only survey exists (decisions.md F11).

"Beside" fails when a legacy record already uses a v0 field name with another type or meaning: an item `kind: "invoice"`, a document `date: "June 2026"`, an upper-case `sha256`, a `meta.lifecycle` outside `ongoing` and `finite`, a free-text `meta.created`, an object-valued `source`. Stamping needs the v0 value there, so the old one would leave the catalog. The rule: the `migrate` (or the `set_meta` at adoption) first adds the found value under the sibling key `legacy_<field>`, for example `legacy_kind`, and only then replaces the field. When `legacy_<field>` is taken, it uses `legacy_<field>_2`, and so on. Both steps are `add` and `replace`, so no key is removed, and the old value stays in the catalog, not only in the op log. The survey lists the field names that can collide (section 9.2 step 9).

Some legacy values break a v0 rule and cannot be rewritten without loss: an id with whitespace, a hand-written log entry, a foreign absolute path. They are accepted as found. The v0 record rules apply to records a v0 implementation creates or changes; the catalog schema enforces on found records only what can be repaired by adding or replacing values (section 10).

### 9.6 Teka states

Each state is defined here once; other sections cite it.

- **Not a teka**: the folder has no `catalog.json`. It is skipped, never reported as an error, as lifeproj does.
- **Corrupt**: `catalog.json` is not UTF-8, does not parse as JSON, or is not a JSON object. The implementation reads nothing further, writes nothing, and tells the user. When the op log or the snapshot holds a consistent state, it offers to restore the catalog from it (section 6.7 step 1); otherwise recovery is a hand fix or a restore from backup.
- **Unknown level**: the level table below says so. The implementation may display the catalog and writes nothing (section 1.4).
- **Needs migration**: a catalog at a known level that is not yet stamped v0, or whose records fail its level's rules (duplicate ids or non-object entries in `open_items[]`, `documents[]` or `processing_log[]` included). A pre-lifeproj catalog is in this state too: an object without a `meta` object, without `meta.schema_version`, with `schema_version` an integer below 1, or with a core key that holds something other than an array. It is adopted and readable, and accepts ops that add no new violation; adoption proposes the migration (section 9.4 step 4).
- **Needs attention** (after adoption): an external edit left records that break their level's rules (section 6.7); a crash recovery could not roll forward (section 6.9); the basename differs from `meta.name` (section 3.1); `catalog.json`, `DASHBOARD.md`, `.teka.lock` or `.sprava/` is a symlink or not a regular file or folder (section 3.6); the catalog holds a duplicate key, a lone surrogate or an out-of-range number (section 4.8); or the level table says so for a stamped catalog. Ops that touch the broken records are refused and others proceed. Three problems block more: a symlink problem, unsafe JSON or a broken stamp block every write until the user approves a repair, and a name mismatch blocks publishing and draining.
- **Ready**: a stamped v0 catalog in none of the states above.

The level table. The level is read on every read of the catalog, from the values as written in the file, because the content hash cannot tell `2` from `2.0` (section 4.8).

| `meta.format` | `meta.schema_version` | `meta.format_version` | Level and state |
| ------------- | --------------------- | --------------------- | --------------- |
| absent | the integer `2` | any | lifeproj v2 |
| absent | the integer `1` | any | lifeproj v1 |
| absent | an integer of 3 or more | any | unknown level |
| absent | missing, or an integer below 1 | any | pre-lifeproj: needs migration |
| absent | a digit string such as `"2"`, or a number with a fraction such as `2.0` | any | lifeproj v1, because lifeproj's checker treats every value that is not an integer as legacy |
| absent | null, a boolean, an object, an array, or a string that is not digits | any | unknown level |
| exactly `"teka"` | the integer `2` | exactly `"0"` | teka v0 |
| exactly `"teka"` | anything else | exactly `"0"` | teka v0, needs attention: a repair proposal replaces the value with `2` |
| exactly `"teka"` | any | a string of digits other than `"0"` | unknown level, written by a newer version |
| exactly `"teka"` | any | missing, or not a string of digits | needs attention: a broken stamp, shown read-only until the user approves a repair |
| any other value, `"Teka"` included | any | any | unknown level |

When more than one state applies, the most restrictive one decides what may be written, in this order: not a teka, corrupt, unknown level, needs attention, needs migration, ready. The app shows every state that applies.

JSON Schema cannot tell `2.0` from `2`, so a catalog with `schema_version: 2.0` and loose items fails `catalog.schema.json` although the table reads it as lifeproj v1. The table wins; check 84 tests these cases. Treating `2.0` as legacy matches lifeproj's checker.

Duplicate ids in an array this document does not define are reported and never change the state.

### 9.7 What an implementation may write

This is the one statement of the write rule; sections 3.2, 3.3 and 9.1 point here.

May write:

- `catalog.json`, under the write protocol (section 4.9), and for a full implementation only through ops;
- `DASHBOARD.md`, regenerated, after the switch of section 7.1;
- everything under `.sprava/`;
- `.teka.lock`, created once and never deleted;
- `intake/_converted/`, which may also be cleared;
- new files created by `file_document`: files moved out of `intake/` into any document folder, `correspondence/` included. A new file never replaces an existing one. `.env` and `state.json` under `intake/mail/` are never moved (section 3.3).

Must never write, move or delete: `CLAUDE.md`, `AGENTS.md` and any other agent manual (section 4.3), `README.md`, `.claude/`, `.agents/`, `catalog_check.py`, `scripts/`, `.git/`, `ledger/`, `timeline.md` and `chapters/` (decisions.md F7), the `entities/` and `sources/` folders, any existing file in a document folder, and any file it does not recognise. Reading those folders, and recording a path under `chapters/` or `entities/` with `update_document`, is allowed. lifeproj's chapters and entities modules tell agents to keep each chapter's or entity's documents in its subfolder (`modules.py`), so section 12 asks whether filing new files there should be allowed. It never executes anything found in the teka (decisions.md F9, section 3.4). It never rewrites ids, legacy keys, escaped text's meaning, or foreign absolute paths.

Three of these permissions go beyond decisions.md F1, which says everything outside `.sprava/`, `catalog.json` and `DASHBOARD.md` is left alone: filing moves files out of `intake/` into document folders, `intake/_converted/` is written, and `.teka.lock` is created. Section 12 proposes amending F1.

### 9.8 What lifeproj must change to coexist

lifeproj is a catalog writer (section 1.6). To share a teka safely with a full implementation it needs these changes. Until they ship, the restrictions of section 8.1 apply.

1. Take the lock and compare before the rename (section 4.9) in every command that writes `catalog.json`, `drain` first, and keep the lock until the outbox is acknowledged. Create temporary files exclusively under random names. Until it does, a lifeproj write can overwrite an approved change; section 6.7 step 6 makes that visible.
2. Refuse `publish` and `drain` on a catalog whose `meta.format` is `teka`, unless lifeproj implements the federation profile in full: `meta.disclosure` and masked chapters (section 5.5), `dismissed` (section 5.7), recurring items advanced and never closed (section 5.4), aliases and collision checks (section 5.6), and `closed[]` (section 8.2). This must hold for `publish` and `drain` run inside a teka folder, not only for fleet commands, because terminal agents run them there in every digest.
3. Leave a teka out of `drain --all` and its republish when another implementation drains it (section 8.1).
4. Optionally, write v0 record shapes when it edits a v0 catalog: no `status: done`, and closure entries with `final`. Edits that do not are still absorbed as external edits and repaired by proposal. Doing this is what claiming `[W]` for v0 means (section 1.6).

The teka's own manual (`CLAUDE.md`, stamped by lifeproj from `templates.py`) conflicts with a v0 teka in three ways. It tells agents to mark items `done` and drop them once shown. It tells them to run `lifeproj drain` and `lifeproj publish` in each digest. And it tells them to regenerate `DASHBOARD.md` and keep facts there, such as a ledger's balance or a chapter's key facts, which a rendered dashboard would overwrite outside its Notes section. An implementation never edits the manual. The app offers the user a short addendum to paste in, and lifeproj could stamp it for v0 tekas. The addendum says, in substance:

- close items with the app, or by moving the item out of `open_items[]` and into a closure entry in `processing_log[]` in one edit; never set `status` to `done`, and never log a closure for an item that stays open;
- do not run `lifeproj publish` or `lifeproj drain` in this teka; the app does both;
- edit `DASHBOARD.md` only below the line `## Notes`, and do not regenerate it.

## 10. JSON Schemas

All schemas use JSON Schema 2020-12. Each is self-contained (no cross-file references) so a validator can be pointed at one file. The `$id` values use a `urn:sprava:teka:v0:` prefix until a domain is settled (decisions.md P11). Conforming validation asserts the `date` and `date-time` formats. The files live in `docs/spec/schemas/` and are reproduced here verbatim. They are generated from one set of definitions so that the item, document and log-entry copies inside `catalog.schema.json` and `op.schema.json` match `item.schema.json`, `document.schema.json` and `log-entry.schema.json`. The generator is not yet in the repository; a build step, still to be written, will fail when the copies differ. Today the copies match.

Validation means structure. Rules a schema cannot express are conformance checks instead (section 11): unique ids within an array, compared by JSON type and value; an open item's id not in the processing log; `meta.name` equal to the folder basename; unique slice projections; the path rules after NFC, full Unicode case folding and symlinks, and Cf characters outside the Basic Multilingual Plane; real calendar dates in lifeproj's loose forms; the level table of section 9.6, `2.0` included; a field named in both `set` and `unset`; `end` not less than `start` in a span; the guard's "new violation" rule; and I-JSON. The schemas compare reserved names without regard to ASCII case by listing both cases of each letter, because the regular-expression dialect of JSON Schema has no case-insensitive flag.

How the catalog schema handles the catalog levels. The generic layer checks only what lifeproj's checker needs: `meta` is an object with `schema_version`, and the core arrays are arrays. When `schema_version` is an integer 2 or more, it applies lifeproj's item rules and nothing stricter. When `meta.format` is `teka`, it applies the v0 rules to `meta`, every item, every document, every entity row, and every log entry a v0 implementation wrote. So a fresh lifeproj catalog, a teka name with a space, entity rows without `status`, an empty or compact `due` and an integer id all validate as lifeproj catalogs, and a v1 catalog with loose items validates as legacy (and still needs migration). A catalog that claims `format: "teka"` must satisfy everything.

### 10.1 catalog.json

`schemas/catalog.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:catalog",
  "title": "teka v0 catalog.json",
  "description": "The catalog of one teka. Three catalog levels are accepted: lifeproj v1 (loose), lifeproj v2 (lifeproj's open_items rules) and teka v0 (meta.format is \"teka\"). The generic layer checks only what lifeproj's checker needs to read a catalog. Unknown fields and unknown top-level arrays are allowed and must be preserved by every writer.",
  "type": "object",
  "required": ["meta"],
  "properties": {
    "meta": { "type": "object", "required": ["schema_version"] },
    "documents": { "type": "array" },
    "open_items": { "type": "array" },
    "processing_log": { "type": "array" },
    "entities": { "type": "array" }
  },
  "additionalProperties": true,
  "allOf": [
    {
      "$comment": "lifeproj v2: schema_version is an integer 2 or more, so lifeproj's open_items rules apply. A digit string such as \"2\", or 2.0, is legacy for lifeproj's checker (it tests isinstance(int)); JSON Schema cannot tell 2.0 from 2, so that case is a conformance check. An integer above 2 without meta.format is an unknown level (section 9.6).",
      "if": {
        "properties": {
          "meta": {
            "required": ["schema_version"],
            "properties": { "schema_version": { "type": "integer", "minimum": 2 } }
          }
        }
      },
      "then": { "properties": { "open_items": { "items": { "$ref": "#/$defs/item_v2" } } } }
    },
    {
      "$comment": "teka v0: meta.format is \"teka\". The v0 rules then apply to meta, every open item, every document, every entity and every log entry a v0 implementation wrote.",
      "if": { "properties": { "meta": { "required": ["format"], "properties": { "format": { "const": "teka" } } } } },
      "then": {
        "required": ["documents", "open_items", "processing_log"],
        "properties": {
          "meta": { "$ref": "#/$defs/meta_v0" },
          "open_items": { "items": { "$ref": "#/$defs/item_v0" } },
          "documents": { "items": { "$ref": "#/$defs/document_v0" } },
          "processing_log": { "items": { "$ref": "#/$defs/log_entry_v0" } },
          "entities": { "items": { "$ref": "#/$defs/entity_v0" } }
        }
      }
    }
  ],
  "$defs": {
    "date": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" },
    "timestamp": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$",
      "format": "date-time"
    },
    "meta_v0": {
      "type": "object",
      "required": ["schema_version", "name", "format", "format_version", "disclosure"],
      "properties": {
        "schema_version": { "const": 2 },
        "name": { "type": "string", "minLength": 1, "pattern": "^(?!\\.\\.?$)[^/]+$" },
        "domain": { "type": "string" },
        "lifecycle": { "enum": ["ongoing", "finite"] },
        "created": { "$ref": "#/$defs/date" },
        "next_doc_id": { "type": "integer" },
        "next_item_id": { "type": "integer" },
        "profile": { "type": "object" },
        "active_chapters": { "type": ["array", "string"], "items": { "type": "string" } },
        "current_chapters": { "type": ["array", "string"], "items": { "type": "string" } },
        "active_chapter": { "type": ["string", "null"] },
        "format": { "const": "teka" },
        "format_version": { "const": "0" },
        "modules": { "type": "array", "items": { "type": "string", "minLength": 1 }, "uniqueItems": true },
        "disclosure": { "enum": ["full", "title", "kind", "none"] },
        "id_scheme": { "enum": ["teka-year-seq", "opaque"] },
        "former_names": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["name", "until"],
            "properties": {
              "name": { "type": "string", "minLength": 1, "pattern": "^(?!\\.\\.?$)[^/]+$" },
              "until": { "$ref": "#/$defs/date" }
            }
          }
        }
      },
      "additionalProperties": true
    },
    "item_v2": {
      "$comment": "lifeproj's open_items rules (osavul.validate_open_items, templates.check_open_items) as far as a schema can say them, and no stricter. 'Truthy' means present and not null, false, 0, an empty string, [] or {}. An empty or null due counts as absent. A due in any form Python's date.fromisoformat accepts passes; whether it is a real date is a conformance check.",
      "type": "object",
      "required": ["id", "title", "status", "priority"],
      "properties": {
        "id": { "not": { "enum": [null, false, 0, "", [], {}] } },
        "title": { "not": { "enum": [null, false, 0, "", [], {}] } },
        "status": { "enum": ["open", "waiting", "blocked", "done"] },
        "priority": { "enum": ["high", "normal", "low"] },
        "due": {
          "type": ["string", "null"],
          "pattern": "^$|^\\d{4}(?:-\\d{2}-\\d{2}|\\d{4}|-W\\d{2}(?:-\\d)?|W\\d{2}\\d?)$"
        },
        "tags": { "type": "array" },
        "redact": { "type": "boolean" },
        "slice_title": { "type": "string", "minLength": 1 }
      },
      "additionalProperties": true,
      "allOf": [
        {
          "$comment": "due XOR no_deadline:true. Only the value true counts for no_deadline.",
          "if": { "required": ["due"], "properties": { "due": { "type": "string", "minLength": 1 } } },
          "then": { "not": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } } },
          "else": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } }
        },
        {
          "$comment": "A waiting or blocked item has a truthy waiting_on.",
          "if": { "required": ["status"], "properties": { "status": { "enum": ["waiting", "blocked"] } } },
          "then": {
            "required": ["waiting_on"],
            "properties": { "waiting_on": { "not": { "enum": [null, false, 0, "", [], {}] } } }
          }
        }
      ]
    },
    "item_v0": {
      "$comment": "Generated from item.schema.json.",
      "type": "object",
      "required": ["id", "title", "status", "priority"],
      "properties": {
        "id": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "title": { "type": "string", "minLength": 1 },
        "status": { "enum": ["open", "waiting", "blocked"] },
        "priority": { "enum": ["high", "normal", "low"] },
        "due": { "$ref": "#/$defs/date" },
        "no_deadline": { "type": "boolean" },
        "waiting_on": { "type": "string", "minLength": 1 },
        "follow_up_at": { "$ref": "#/$defs/date" },
        "expected_by": { "$ref": "#/$defs/date" },
        "kind": {
          "enum": [
            "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision",
            "other"
          ]
        },
        "tags": { "type": "array", "items": { "type": "string" } },
        "link": { "type": "string", "minLength": 1 },
        "redact": { "type": "boolean" },
        "slice_title": { "type": "string", "minLength": 1 },
        "recurrence": {
          "type": "object",
          "required": ["freq", "day"],
          "properties": {
            "freq": { "enum": ["monthly", "yearly"] },
            "day": { "type": "integer", "minimum": 1, "maximum": 31 },
            "month": { "type": "integer", "minimum": 1, "maximum": 12, "$comment": "Ignored when freq is monthly." }
          },
          "additionalProperties": true,
          "if": { "properties": { "freq": { "const": "yearly" } } },
          "then": { "required": ["month"] }
        },
        "contexts": { "type": "array", "items": { "type": "string", "pattern": "^@[^\\s@]+$" }, "uniqueItems": true },
        "estimate_min": { "type": "integer", "minimum": 0 },
        "dismissed": { "type": "boolean" },
        "created_at": { "$ref": "#/$defs/timestamp" },
        "updated_at": { "$ref": "#/$defs/timestamp" },
        "provenance": {
          "type": "object",
          "properties": {
            "events": { "type": "array", "items": { "type": "string", "minLength": 1 } },
            "proposed_by": {
              "type": "object",
              "required": ["kind"],
              "properties": {
                "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
                "client": {
                  "type": "string",
                  "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
                },
                "origin": {
                  "type": "string",
                  "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
                },
                "model": { "type": "string" }
              },
              "additionalProperties": true
            },
            "approved_by": { "type": ["string", "null"] },
            "op": { "type": "string", "minLength": 1 },
            "proposal": { "type": "string", "minLength": 1 },
            "reopened_from": {
              "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
              "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
            }
          },
          "additionalProperties": true
        },
        "derived": { "type": "array", "items": { "type": "string", "minLength": 1 }, "uniqueItems": true }
      },
      "additionalProperties": true,
      "allOf": [
        {
          "$comment": "due XOR no_deadline:true. A v0 item never holds a null due; it omits the key.",
          "if": { "required": ["due"] },
          "then": { "not": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } } },
          "else": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } }
        },
        {
          "$comment": "A waiting or blocked item names the party and the date on which to chase.",
          "if": { "required": ["status"], "properties": { "status": { "enum": ["waiting", "blocked"] } } },
          "then": { "required": ["waiting_on", "follow_up_at"] }
        },
        {
          "$comment": "A redacted item names a non-sensitive kind.",
          "if": { "required": ["redact"], "properties": { "redact": { "const": true } } },
          "then": { "required": ["kind"] }
        },
        {
          "$comment": "Recurrence needs a due date: due holds the next occurrence.",
          "if": { "required": ["recurrence"] },
          "then": { "required": ["due"] }
        }
      ]
    },
    "document_v0": {
      "$comment": "Generated from document.schema.json.",
      "type": "object",
      "required": ["id", "title", "path"],
      "properties": {
        "id": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "title": { "type": "string", "minLength": 1 },
        "path": {
          "type": "string",
          "minLength": 1,
          "$comment": "Relative to the teka folder. A record found at adoption may hold any path and is reported; a path written by file_document or update_document follows safe_path or record_path in op.schema.json."
        },
        "date": { "$ref": "#/$defs/date" },
        "kind": { "type": "string", "minLength": 1 },
        "source": { "type": "string" },
        "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "provenance": {
          "type": "object",
          "properties": {
            "events": { "type": "array", "items": { "type": "string", "minLength": 1 } },
            "proposed_by": {
              "type": "object",
              "required": ["kind"],
              "properties": {
                "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
                "client": {
                  "type": "string",
                  "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
                },
                "origin": {
                  "type": "string",
                  "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
                },
                "model": { "type": "string" }
              },
              "additionalProperties": true
            },
            "approved_by": { "type": ["string", "null"] },
            "op": { "type": "string", "minLength": 1 },
            "proposal": { "type": "string", "minLength": 1 },
            "reopened_from": {
              "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
              "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
            }
          },
          "additionalProperties": true
        }
      },
      "additionalProperties": true
    },
    "log_entry_v0": {
      "$comment": "Rules for entries a v0 implementation writes, which always carry op_id. Entries without op_id are legacy and unconstrained; lifeproj's rule that any entry with an id closes that item holds for them whatever their action.",
      "if": { "type": "object", "required": ["op_id"] },
      "then": {
        "type": "object",
        "required": ["action", "at", "via"],
        "properties": {
          "id": {
            "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
            "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type.",
            "description": "Only on a closure: the closed item's id exactly as it appears in the catalog, with its JSON type, never slice-prefixed."
          },
          "item": {
            "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
            "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type.",
            "description": "An item the entry is about without closing it."
          },
          "document": { "type": "string", "minLength": 1, "description": "A document the entry is about." },
          "title": { "type": "string" },
          "action": { "type": "string", "minLength": 1 },
          "at": { "$ref": "#/$defs/timestamp" },
          "closed_at": { "type": ["string", "null"] },
          "source": { "type": "string" },
          "via": { "type": "string", "minLength": 1 },
          "op_id": { "type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" },
          "note": { "type": "string" },
          "kind": {
            "enum": [
              "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision",
              "other"
            ]
          },
          "final": { "type": "object", "description": "The closed item's other fields as they were (section 5.10)." },
          "due": { "$ref": "#/$defs/date" },
          "next_due": { "$ref": "#/$defs/date" },
          "reopened_from": {
            "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
            "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
          }
        },
        "additionalProperties": true,
        "allOf": [
          {
            "$comment": "An entry that carries id is a closure: done or dropped, with the closing details and the item as it was.",
            "if": { "required": ["id"] },
            "then": {
              "required": ["title", "closed_at", "source", "final"],
              "properties": { "action": { "enum": ["done", "dropped"] } }
            }
          },
          {
            "$comment": "A closure of an item whose id was already closed in the processing log: no id, so no id repeats (section 6.8).",
            "if": { "required": ["action"], "properties": { "action": { "const": "closed-duplicate" } } },
            "then": { "required": ["item", "closed_at", "source", "final"], "not": { "required": ["id"] } }
          }
        ]
      }
    },
    "entity_v0": {
      "type": "object",
      "required": ["id", "status"],
      "properties": {
        "id": { "not": { "enum": [null, false, 0, "", [], {}] } },
        "status": { "type": "string", "minLength": 1 }
      },
      "additionalProperties": true
    }
  }
}
```

### 10.2 Item

`schemas/item.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:item",
  "title": "teka v0 open item",
  "description": "One entry of open_items[] in a teka v0 catalog. It satisfies lifeproj's schema_version 2 rules and adds the v0 fields. An id found at adoption is accepted as it is; an id minted by a v0 implementation also matches minted_id in op.schema.json. This file is the single source of the item_v0 copies in catalog.schema.json and op.schema.json. Unknown fields are allowed and preserved.",
  "type": "object",
  "required": ["id", "title", "status", "priority"],
  "properties": {
    "id": {
      "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
      "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
    },
    "title": { "type": "string", "minLength": 1 },
    "status": { "enum": ["open", "waiting", "blocked"] },
    "priority": { "enum": ["high", "normal", "low"] },
    "due": { "$ref": "#/$defs/date" },
    "no_deadline": { "type": "boolean" },
    "waiting_on": { "type": "string", "minLength": 1 },
    "follow_up_at": { "$ref": "#/$defs/date" },
    "expected_by": { "$ref": "#/$defs/date" },
    "kind": {
      "enum": [
        "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision", "other"
      ]
    },
    "tags": { "type": "array", "items": { "type": "string" } },
    "link": { "type": "string", "minLength": 1 },
    "redact": { "type": "boolean" },
    "slice_title": { "type": "string", "minLength": 1 },
    "recurrence": {
      "type": "object",
      "required": ["freq", "day"],
      "properties": {
        "freq": { "enum": ["monthly", "yearly"] },
        "day": { "type": "integer", "minimum": 1, "maximum": 31 },
        "month": { "type": "integer", "minimum": 1, "maximum": 12, "$comment": "Ignored when freq is monthly." }
      },
      "additionalProperties": true,
      "if": { "properties": { "freq": { "const": "yearly" } } },
      "then": { "required": ["month"] }
    },
    "contexts": { "type": "array", "items": { "type": "string", "pattern": "^@[^\\s@]+$" }, "uniqueItems": true },
    "estimate_min": { "type": "integer", "minimum": 0 },
    "dismissed": { "type": "boolean" },
    "created_at": { "$ref": "#/$defs/timestamp" },
    "updated_at": { "$ref": "#/$defs/timestamp" },
    "provenance": {
      "type": "object",
      "properties": {
        "events": { "type": "array", "items": { "type": "string", "minLength": 1 } },
        "proposed_by": {
          "type": "object",
          "required": ["kind"],
          "properties": {
            "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
            "client": {
              "type": "string",
              "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
            },
            "origin": {
              "type": "string",
              "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
            },
            "model": { "type": "string" }
          },
          "additionalProperties": true
        },
        "approved_by": { "type": ["string", "null"] },
        "op": { "type": "string", "minLength": 1 },
        "proposal": { "type": "string", "minLength": 1 },
        "reopened_from": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        }
      },
      "additionalProperties": true
    },
    "derived": { "type": "array", "items": { "type": "string", "minLength": 1 }, "uniqueItems": true }
  },
  "additionalProperties": true,
  "allOf": [
    {
      "$comment": "due XOR no_deadline:true. A v0 item never holds a null due; it omits the key.",
      "if": { "required": ["due"] },
      "then": { "not": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } } },
      "else": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } }
    },
    {
      "$comment": "A waiting or blocked item names the party and the date on which to chase.",
      "if": { "required": ["status"], "properties": { "status": { "enum": ["waiting", "blocked"] } } },
      "then": { "required": ["waiting_on", "follow_up_at"] }
    },
    {
      "$comment": "A redacted item names a non-sensitive kind.",
      "if": { "required": ["redact"], "properties": { "redact": { "const": true } } },
      "then": { "required": ["kind"] }
    },
    {
      "$comment": "Recurrence needs a due date: due holds the next occurrence.",
      "if": { "required": ["recurrence"] },
      "then": { "required": ["due"] }
    }
  ],
  "$defs": {
    "date": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" },
    "timestamp": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$",
      "format": "date-time"
    }
  }
}
```

### 10.3 Document

`schemas/document.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:document",
  "title": "teka v0 document record",
  "description": "One entry of documents[] in a teka v0 catalog. The file lives at path, inside the teka folder. Single source of the document_v0 copies. Unknown fields are allowed and preserved.",
  "type": "object",
  "required": ["id", "title", "path"],
  "properties": {
    "id": {
      "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
      "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
    },
    "title": { "type": "string", "minLength": 1 },
    "path": {
      "type": "string",
      "minLength": 1,
      "$comment": "Relative to the teka folder. A record found at adoption may hold any path and is reported; a path written by file_document or update_document follows safe_path or record_path in op.schema.json."
    },
    "date": { "$ref": "#/$defs/date" },
    "kind": { "type": "string", "minLength": 1 },
    "source": { "type": "string" },
    "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
    "provenance": {
      "type": "object",
      "properties": {
        "events": { "type": "array", "items": { "type": "string", "minLength": 1 } },
        "proposed_by": {
          "type": "object",
          "required": ["kind"],
          "properties": {
            "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
            "client": {
              "type": "string",
              "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
            },
            "origin": {
              "type": "string",
              "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
            },
            "model": { "type": "string" }
          },
          "additionalProperties": true
        },
        "approved_by": { "type": ["string", "null"] },
        "op": { "type": "string", "minLength": 1 },
        "proposal": { "type": "string", "minLength": 1 },
        "reopened_from": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        }
      },
      "additionalProperties": true
    }
  },
  "additionalProperties": true,
  "$defs": {
    "date": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" },
    "timestamp": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$",
      "format": "date-time"
    }
  }
}
```

### 10.4 Log entry

`schemas/log-entry.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:log-entry",
  "title": "teka v0 processing_log entry",
  "description": "One entry of processing_log[]. Entries a v0 implementation writes carry op_id and follow these rules; legacy entries are accepted as they are. Single source of the log_entry_v0 copy. Unknown fields are allowed and preserved.",
  "$comment": "Rules for entries a v0 implementation writes, which always carry op_id. Entries without op_id are legacy and unconstrained; lifeproj's rule that any entry with an id closes that item holds for them whatever their action.",
  "if": { "type": "object", "required": ["op_id"] },
  "then": {
    "type": "object",
    "required": ["action", "at", "via"],
    "properties": {
      "id": {
        "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
        "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type.",
        "description": "Only on a closure: the closed item's id exactly as it appears in the catalog, with its JSON type, never slice-prefixed."
      },
      "item": {
        "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
        "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type.",
        "description": "An item the entry is about without closing it."
      },
      "document": { "type": "string", "minLength": 1, "description": "A document the entry is about." },
      "title": { "type": "string" },
      "action": { "type": "string", "minLength": 1 },
      "at": { "$ref": "#/$defs/timestamp" },
      "closed_at": { "type": ["string", "null"] },
      "source": { "type": "string" },
      "via": { "type": "string", "minLength": 1 },
      "op_id": { "type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" },
      "note": { "type": "string" },
      "kind": {
        "enum": [
          "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision",
          "other"
        ]
      },
      "final": { "type": "object", "description": "The closed item's other fields as they were (section 5.10)." },
      "due": { "$ref": "#/$defs/date" },
      "next_due": { "$ref": "#/$defs/date" },
      "reopened_from": {
        "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
        "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
      }
    },
    "additionalProperties": true,
    "allOf": [
      {
        "$comment": "An entry that carries id is a closure: done or dropped, with the closing details and the item as it was.",
        "if": { "required": ["id"] },
        "then": {
          "required": ["title", "closed_at", "source", "final"],
          "properties": { "action": { "enum": ["done", "dropped"] } }
        }
      },
      {
        "$comment": "A closure of an item whose id was already closed in the processing log: no id, so no id repeats (section 6.8).",
        "if": { "required": ["action"], "properties": { "action": { "const": "closed-duplicate" } } },
        "then": { "required": ["item", "closed_at", "source", "final"], "not": { "required": ["id"] } }
      }
    ]
  },
  "$defs": {
    "date": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" },
    "timestamp": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$",
      "format": "date-time"
    }
  }
}
```

### 10.5 Applied op

`schemas/op.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:op",
  "title": "teka v0 applied op",
  "description": "One line of .sprava/ops.ndjson: an op that has been applied to catalog.json, with its envelope. An applied op carries every value its effect needs, so applying it is a pure function of the catalog and the op (section 6.3). The op body (op, args, note) is what a proposal carries before it is applied.",
  "type": "object",
  "required": ["id", "at", "actor", "op", "args", "before_hash", "after_hash"],
  "properties": {
    "id": { "$ref": "#/$defs/uuid" },
    "at": { "$ref": "#/$defs/timestamp" },
    "hlc": {
      "type": "object",
      "required": ["wall_ms", "counter", "node"],
      "properties": {
        "wall_ms": { "type": "integer", "minimum": 0 },
        "counter": { "type": "integer", "minimum": 0, "maximum": 65535 },
        "node": {
          "type": "string",
          "minLength": 1,
          "$comment": "A random opaque id, never a computer or device name."
        }
      },
      "additionalProperties": true
    },
    "actor": { "$ref": "#/$defs/actor" },
    "proposal": { "$ref": "#/$defs/uuid" },
    "batch": { "$ref": "#/$defs/uuid" },
    "seq": { "type": "integer", "minimum": 0 },
    "batch_size": { "type": "integer", "minimum": 1 },
    "approved_by": { "type": ["string", "null"] },
    "before_hash": { "$ref": "#/$defs/hash" },
    "after_hash": { "$ref": "#/$defs/hash" },
    "compensates": { "$ref": "#/$defs/uuid" },
    "op": {
      "enum": [
        "add_item", "update_item", "set_status", "complete", "drop", "reopen", "dismiss", "undismiss",
        "file_document", "update_document", "add_log_entry", "set_meta", "set_disclosure", "rename_teka",
        "external_edit", "import_snapshot", "migrate", "abort", "expunge"
      ]
    },
    "args": { "type": "object" },
    "note": { "type": "string" }
  },
  "additionalProperties": true,
  "allOf": [
    {
      "$comment": "An op proposed by a clerk or a brain is applied only after approval.",
      "if": { "properties": { "actor": { "properties": { "kind": { "enum": ["clerk", "brain"] } } } } },
      "then": {
        "required": ["approved_by", "proposal"],
        "properties": { "approved_by": { "type": "string", "minLength": 1 } }
      }
    },
    {
      "$comment": "Ops applied together share batch; seq orders them and batch_size says how many lines the batch has (section 6.9).",
      "if": { "required": ["batch"] },
      "then": { "required": ["seq", "batch_size"] }
    },
    {
      "$comment": "An op that writes a processing log entry names the implementation in actor.client, because the entry's via is copied from it (section 6.2).",
      "if": { "properties": { "op": { "enum": ["complete", "drop", "reopen", "file_document", "add_log_entry"] } } },
      "then": {
        "properties": { "actor": { "required": ["client"], "properties": { "client": { "minLength": 1 } } } }
      }
    },
    {
      "if": { "properties": { "op": { "const": "add_item" } } },
      "then": {
        "properties": {
          "args": {
            "required": ["item"],
            "properties": {
              "item": {
                "allOf": [
                  { "$ref": "#/$defs/item_v0" },
                  {
                    "$comment": "A record a v0 implementation creates: minted ASCII id, and created_at and updated_at equal to the op's at.",
                    "required": ["created_at", "updated_at"],
                    "properties": { "id": { "$ref": "#/$defs/minted_id" } }
                  }
                ]
              }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "reopen" } } },
      "then": {
        "properties": {
          "args": {
            "required": ["id", "item"],
            "properties": {
              "id": {
                "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
                "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type.",
                "description": "The closed item's id, with its JSON type."
              },
              "item": {
                "allOf": [
                  { "$ref": "#/$defs/item_v0" },
                  {
                    "$comment": "A record a v0 implementation creates: minted ASCII id, and created_at and updated_at equal to the op's at.",
                    "required": ["created_at", "updated_at"],
                    "properties": { "id": { "$ref": "#/$defs/minted_id" } }
                  },
                  { "required": ["provenance"], "properties": { "provenance": { "required": ["reopened_from"] } } }
                ]
              }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "update_item" } } },
      "then": { "properties": { "args": { "$ref": "#/$defs/item_change" } } }
    },
    {
      "if": { "properties": { "op": { "const": "set_status" } } },
      "then": {
        "properties": {
          "args": {
            "required": ["id", "status"],
            "properties": {
              "id": {
                "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
                "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
              },
              "status": { "enum": ["open", "waiting", "blocked"] },
              "waiting_on": { "type": "string", "minLength": 1 },
              "follow_up_at": { "$ref": "#/$defs/date" },
              "expected_by": { "$ref": "#/$defs/date" },
              "derived": {
                "type": "array",
                "items": { "type": "string", "minLength": 1 },
                "uniqueItems": true,
                "description": "When present, replaces the item's derived array; an empty array removes it (section 5.3)."
              }
            },
            "if": { "properties": { "status": { "enum": ["waiting", "blocked"] } } },
            "then": { "required": ["waiting_on", "follow_up_at"] }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "enum": ["complete", "drop"] } } },
      "then": {
        "properties": {
          "args": {
            "required": ["id", "closed_at", "source"],
            "properties": {
              "id": {
                "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
                "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
              },
              "closed_at": {
                "type": ["string", "null"],
                "$comment": "A v0 implementation writes a timestamp; a drained completion's at is copied as it is."
              },
              "source": { "type": "string" },
              "note": { "type": "string" },
              "reason": { "type": "string" },
              "occurrence_due": { "$ref": "#/$defs/date" },
              "next_due": { "$ref": "#/$defs/date" }
            },
            "dependentRequired": { "next_due": ["occurrence_due"], "occurrence_due": ["next_due"] }
          }
        }
      }
    },
    {
      "$comment": "drop never advances a recurring item; it ends it.",
      "if": { "properties": { "op": { "const": "drop" } } },
      "then": {
        "properties": {
          "args": { "not": { "anyOf": [{ "required": ["next_due"] }, { "required": ["occurrence_due"] }] } }
        }
      }
    },
    {
      "if": { "properties": { "op": { "enum": ["dismiss", "undismiss"] } } },
      "then": {
        "properties": {
          "args": {
            "required": ["id"],
            "properties": {
              "id": {
                "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
                "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
              }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "file_document" } } },
      "then": {
        "properties": {
          "args": {
            "required": ["document"],
            "properties": {
              "document": {
                "allOf": [
                  { "$ref": "#/$defs/document_v0" },
                  {
                    "required": ["sha256"],
                    "properties": { "id": { "$ref": "#/$defs/minted_id" }, "path": { "$ref": "#/$defs/safe_path" } }
                  }
                ]
              },
              "from": { "$ref": "#/$defs/intake_path" }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "update_document" } } },
      "then": { "properties": { "args": { "$ref": "#/$defs/document_change" } } }
    },
    {
      "if": { "properties": { "op": { "const": "add_log_entry" } } },
      "then": {
        "properties": {
          "args": { "required": ["entry"], "properties": { "entry": { "$ref": "#/$defs/log_entry_no_closure" } } }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "set_meta" } } },
      "then": {
        "properties": {
          "args": {
            "properties": {
              "set": {
                "type": "object",
                "propertyNames": {
                  "not": {
                    "enum": ["name", "schema_version", "format", "format_version", "disclosure", "former_names"]
                  }
                }
              },
              "unset": {
                "type": "array",
                "items": {
                  "type": "string",
                  "not": {
                    "enum": ["name", "schema_version", "format", "format_version", "disclosure", "former_names"]
                  }
                }
              }
            },
            "anyOf": [{ "required": ["set"] }, { "required": ["unset"] }]
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "set_disclosure" } } },
      "then": {
        "properties": {
          "actor": { "properties": { "kind": { "const": "user" } } },
          "args": {
            "required": ["disclosure"],
            "properties": { "disclosure": { "enum": ["full", "title", "kind", "none"] } }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "rename_teka" } } },
      "then": {
        "properties": {
          "actor": { "properties": { "kind": { "const": "user" } } },
          "args": {
            "required": ["name", "former", "until"],
            "properties": {
              "name": { "type": "string", "minLength": 1, "pattern": "^(?!\\.\\.?$)[^/]+$" },
              "former": { "type": "string", "minLength": 1, "pattern": "^(?!\\.\\.?$)[^/]+$" },
              "until": { "$ref": "#/$defs/date" }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "external_edit" } } },
      "then": {
        "properties": {
          "actor": { "properties": { "kind": { "const": "external" } } },
          "args": {
            "required": ["patch"],
            "properties": {
              "patch": { "$ref": "#/$defs/json_patch" },
              "detected_at": { "$ref": "#/$defs/timestamp" },
              "hint": { "type": "string" }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "import_snapshot" } } },
      "then": {
        "properties": {
          "actor": { "properties": { "kind": { "const": "import" } } },
          "args": {
            "required": ["catalog", "survey"],
            "properties": { "catalog": { "type": "object" }, "survey": { "type": "object" } },
            "$comment": "The first op of every op log, and a later re-base point when a log fails replay (section 6.6). before_hash and after_hash both equal the hash of catalog."
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "migrate" } } },
      "then": {
        "properties": {
          "actor": { "properties": { "kind": { "const": "import" } } },
          "args": {
            "required": ["from", "to", "patch"],
            "properties": {
              "from": { "type": "object" },
              "to": { "type": "object" },
              "patch": {
                "allOf": [
                  { "$ref": "#/$defs/json_patch" },
                  { "items": { "properties": { "op": { "enum": ["add", "replace"] } } } }
                ],
                "$comment": "A migration never removes a key."
              }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "abort" } } },
      "then": {
        "properties": {
          "actor": { "properties": { "kind": { "const": "import" } } },
          "args": {
            "required": ["ops", "reason"],
            "properties": {
              "ops": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/uuid" } },
              "reason": { "type": "string", "minLength": 1 }
            }
          }
        }
      }
    },
    {
      "if": { "properties": { "op": { "const": "expunge" } } },
      "then": {
        "properties": {
          "actor": { "properties": { "kind": { "const": "user" } } },
          "args": {
            "required": ["replaced", "rewrote"],
            "properties": {
              "replaced": {
                "type": "object",
                "additionalProperties": { "type": "integer", "minimum": 0 },
                "description": "How many values were replaced in each place, for example {\"catalog.json\": 2, \"ops.ndjson\": 5}. Never the text and never a digest of it."
              },
              "rewrote": {
                "type": "array",
                "items": { "$ref": "#/$defs/uuid" },
                "description": "The op lines whose free text was rewritten."
              },
              "reason": { "type": "string" }
            }
          }
        }
      }
    }
  ],
  "$defs": {
    "uuid": { "type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" },
    "hash": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
    "date": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" },
    "timestamp": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$",
      "format": "date-time"
    },
    "actor": {
      "type": "object",
      "required": ["kind"],
      "properties": {
        "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
        "client": {
          "type": "string",
          "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
        },
        "origin": {
          "type": "string",
          "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
        },
        "model": { "type": "string" }
      },
      "additionalProperties": true
    },
    "minted_id": {
      "type": "string",
      "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]*$",
      "$comment": "Ids minted by a v0 implementation are ASCII (section 5.6)."
    },
    "safe_path": {
      "type": "string",
      "pattern": "^(?!(?:[Cc][Aa][Tt][Aa][Ll][Oo][Gg]\\.[Jj][Ss][Oo][Nn]|[Dd][Aa][Ss][Hh][Bb][Oo][Aa][Rr][Dd]\\.[Mm][Dd]|[Rr][Ee][Aa][Dd][Mm][Ee]\\.[Mm][Dd]|[Cc][Aa][Tt][Aa][Ll][Oo][Gg]_[Cc][Hh][Ee][Cc][Kk]\\.[Pp][Yy]|[Tt][Ii][Mm][Ee][Ll][Ii][Nn][Ee]\\.[Mm][Dd])$)(?!(?:[Ii][Nn][Tt][Aa][Kk][Ee]|[Ss][Cc][Rr][Ii][Pp][Tt][Ss]|[Ll][Ee][Dd][Gg][Ee][Rr]|[Ss][Oo][Uu][Rr][Cc][Ee][Ss]|[Cc][Hh][Aa][Pp][Tt][Ee][Rr][Ss]|[Ee][Nn][Tt][Ii][Tt][Ii][Ee][Ss])(?:/|$))(?!(?:.*/)?(?:[Cc][Ll][Aa][Uu][Dd][Ee]\\.[Mm][Dd]|[Cc][Ll][Aa][Uu][Dd][Ee]\\.[Ll][Oo][Cc][Aa][Ll]\\.[Mm][Dd]|[Aa][Gg][Ee][Nn][Tt][Ss]\\.[Mm][Dd]|[Gg][Ee][Mm][Ii][Nn][Ii]\\.[Mm][Dd])(?:/|$))[^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb.~][^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb]*(?:/[^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb.~][^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb]*)*$",
      "$comment": "Where file_document may put a file (section 4.3): relative, every segment non-empty, not starting with '.' or '~', no backslash and no Cc or Cf character; not a reserved file or folder, compared without regard to case; no agent manual name in any segment. NFC form, full Unicode case folding and containment after symlinks are conformance checks."
    },
    "record_path": {
      "type": "string",
      "pattern": "^(?!(?:[Cc][Aa][Tt][Aa][Ll][Oo][Gg]\\.[Jj][Ss][Oo][Nn]|[Dd][Aa][Ss][Hh][Bb][Oo][Aa][Rr][Dd]\\.[Mm][Dd]|[Rr][Ee][Aa][Dd][Mm][Ee]\\.[Mm][Dd]|[Cc][Aa][Tt][Aa][Ll][Oo][Gg]_[Cc][Hh][Ee][Cc][Kk]\\.[Pp][Yy]|[Tt][Ii][Mm][Ee][Ll][Ii][Nn][Ee]\\.[Mm][Dd])$)(?!(?:[Ii][Nn][Tt][Aa][Kk][Ee]|[Ss][Cc][Rr][Ii][Pp][Tt][Ss]|[Ll][Ee][Dd][Gg][Ee][Rr]|[Ss][Oo][Uu][Rr][Cc][Ee][Ss])(?:/|$))(?!(?:.*/)?(?:[Cc][Ll][Aa][Uu][Dd][Ee]\\.[Mm][Dd]|[Cc][Ll][Aa][Uu][Dd][Ee]\\.[Ll][Oo][Cc][Aa][Ll]\\.[Mm][Dd]|[Aa][Gg][Ee][Nn][Tt][Ss]\\.[Mm][Dd]|[Gg][Ee][Mm][Ii][Nn][Ii]\\.[Mm][Dd])(?:/|$))[^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb.~][^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb]*(?:/[^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb.~][^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb]*)*$",
      "$comment": "A path update_document may record (it moves nothing): the rules of safe_path, except that it may lie under chapters/ or entities/ (section 4.3)."
    },
    "intake_path": {
      "type": "string",
      "pattern": "^intake/[^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb.~][^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb]*(?:/[^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb.~][^/\\\\\\u0000-\\u001f\\u007f-\\u009f\\u00ad\\u061c\\u180e\\u200b-\\u200f\\u202a-\\u202e\\u2060-\\u2064\\u2066-\\u206f\\ufeff\\ufff9-\\ufffb]*)*$",
      "$comment": "Filing moves a file only out of intake/."
    },
    "item_change": {
      "type": "object",
      "required": ["id"],
      "properties": {
        "id": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "set": {
          "type": "object",
          "propertyNames": { "not": { "enum": ["id", "status", "dismissed", "created_at", "updated_at"] } }
        },
        "unset": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "string",
            "not": { "enum": ["id", "title", "status", "priority", "dismissed", "created_at", "updated_at"] }
          }
        }
      },
      "anyOf": [{ "required": ["set"] }, { "required": ["unset"] }],
      "$comment": "A field never appears in both set and unset; that is a conformance check."
    },
    "document_change": {
      "type": "object",
      "required": ["id"],
      "properties": {
        "id": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "set": {
          "type": "object",
          "propertyNames": { "not": { "const": "id" } },
          "properties": { "path": { "$ref": "#/$defs/record_path" } }
        },
        "unset": {
          "type": "array",
          "minItems": 1,
          "items": { "type": "string", "not": { "enum": ["id", "title", "path"] } }
        }
      },
      "anyOf": [{ "required": ["set"] }, { "required": ["unset"] }]
    },
    "json_patch": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["op", "path"],
        "properties": { "op": { "enum": ["add", "remove", "replace"] }, "path": { "type": "string" } },
        "if": { "properties": { "op": { "enum": ["add", "replace"] } } },
        "then": { "required": ["value"] }
      }
    },
    "item_v0": {
      "$comment": "Generated from item.schema.json.",
      "type": "object",
      "required": ["id", "title", "status", "priority"],
      "properties": {
        "id": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "title": { "type": "string", "minLength": 1 },
        "status": { "enum": ["open", "waiting", "blocked"] },
        "priority": { "enum": ["high", "normal", "low"] },
        "due": { "$ref": "#/$defs/date" },
        "no_deadline": { "type": "boolean" },
        "waiting_on": { "type": "string", "minLength": 1 },
        "follow_up_at": { "$ref": "#/$defs/date" },
        "expected_by": { "$ref": "#/$defs/date" },
        "kind": {
          "enum": [
            "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision",
            "other"
          ]
        },
        "tags": { "type": "array", "items": { "type": "string" } },
        "link": { "type": "string", "minLength": 1 },
        "redact": { "type": "boolean" },
        "slice_title": { "type": "string", "minLength": 1 },
        "recurrence": {
          "type": "object",
          "required": ["freq", "day"],
          "properties": {
            "freq": { "enum": ["monthly", "yearly"] },
            "day": { "type": "integer", "minimum": 1, "maximum": 31 },
            "month": { "type": "integer", "minimum": 1, "maximum": 12, "$comment": "Ignored when freq is monthly." }
          },
          "additionalProperties": true,
          "if": { "properties": { "freq": { "const": "yearly" } } },
          "then": { "required": ["month"] }
        },
        "contexts": { "type": "array", "items": { "type": "string", "pattern": "^@[^\\s@]+$" }, "uniqueItems": true },
        "estimate_min": { "type": "integer", "minimum": 0 },
        "dismissed": { "type": "boolean" },
        "created_at": { "$ref": "#/$defs/timestamp" },
        "updated_at": { "$ref": "#/$defs/timestamp" },
        "provenance": {
          "type": "object",
          "properties": {
            "events": { "type": "array", "items": { "type": "string", "minLength": 1 } },
            "proposed_by": {
              "type": "object",
              "required": ["kind"],
              "properties": {
                "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
                "client": {
                  "type": "string",
                  "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
                },
                "origin": {
                  "type": "string",
                  "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
                },
                "model": { "type": "string" }
              },
              "additionalProperties": true
            },
            "approved_by": { "type": ["string", "null"] },
            "op": { "type": "string", "minLength": 1 },
            "proposal": { "type": "string", "minLength": 1 },
            "reopened_from": {
              "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
              "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
            }
          },
          "additionalProperties": true
        },
        "derived": { "type": "array", "items": { "type": "string", "minLength": 1 }, "uniqueItems": true }
      },
      "additionalProperties": true,
      "allOf": [
        {
          "$comment": "due XOR no_deadline:true. A v0 item never holds a null due; it omits the key.",
          "if": { "required": ["due"] },
          "then": { "not": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } } },
          "else": { "required": ["no_deadline"], "properties": { "no_deadline": { "const": true } } }
        },
        {
          "$comment": "A waiting or blocked item names the party and the date on which to chase.",
          "if": { "required": ["status"], "properties": { "status": { "enum": ["waiting", "blocked"] } } },
          "then": { "required": ["waiting_on", "follow_up_at"] }
        },
        {
          "$comment": "A redacted item names a non-sensitive kind.",
          "if": { "required": ["redact"], "properties": { "redact": { "const": true } } },
          "then": { "required": ["kind"] }
        },
        {
          "$comment": "Recurrence needs a due date: due holds the next occurrence.",
          "if": { "required": ["recurrence"] },
          "then": { "required": ["due"] }
        }
      ]
    },
    "document_v0": {
      "$comment": "Generated from document.schema.json.",
      "type": "object",
      "required": ["id", "title", "path"],
      "properties": {
        "id": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "title": { "type": "string", "minLength": 1 },
        "path": {
          "type": "string",
          "minLength": 1,
          "$comment": "Relative to the teka folder. A record found at adoption may hold any path and is reported; a path written by file_document or update_document follows safe_path or record_path in op.schema.json."
        },
        "date": { "$ref": "#/$defs/date" },
        "kind": { "type": "string", "minLength": 1 },
        "source": { "type": "string" },
        "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
        "provenance": {
          "type": "object",
          "properties": {
            "events": { "type": "array", "items": { "type": "string", "minLength": 1 } },
            "proposed_by": {
              "type": "object",
              "required": ["kind"],
              "properties": {
                "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
                "client": {
                  "type": "string",
                  "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
                },
                "origin": {
                  "type": "string",
                  "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
                },
                "model": { "type": "string" }
              },
              "additionalProperties": true
            },
            "approved_by": { "type": ["string", "null"] },
            "op": { "type": "string", "minLength": 1 },
            "proposal": { "type": "string", "minLength": 1 },
            "reopened_from": {
              "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
              "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
            }
          },
          "additionalProperties": true
        }
      },
      "additionalProperties": true
    },
    "log_entry_no_closure": {
      "$comment": "add_log_entry never closes an item: closures go through complete and drop, so the entry must not carry id.",
      "type": "object",
      "required": ["action"],
      "not": { "required": ["id"] },
      "properties": {
        "item": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "document": {
          "anyOf": [{ "type": "string", "minLength": 1 }, { "type": "integer", "not": { "const": 0 } }],
          "$comment": "A v0 id is a non-empty string or a non-zero integer, compared by JSON type and value (section 5.6). Ids are copied with their type."
        },
        "action": { "type": "string", "minLength": 1 },
        "note": { "type": "string" },
        "source": { "type": "string" }
      },
      "additionalProperties": true
    }
  }
}
```

### 10.6 Op batch (proposal)

`schemas/op-batch.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:op-batch",
  "title": "teka v0 op batch (proposal)",
  "description": "A set of ops that are approved and applied together, with the provenance a review card shows. Stored as .sprava/proposals/<id>.json; the applied ops are appended to .sprava/ops.ndjson with proposal and batch set to this id. A new record's id in a proposal is a placeholder such as \"$new:1\", which later ops in the same batch may reference; the real id is minted when the batch is applied (section 5.6).",
  "type": "object",
  "required": ["id", "format_version", "created_at", "actor", "state", "ops"],
  "properties": {
    "id": { "$ref": "#/$defs/uuid" },
    "format_version": { "const": "0" },
    "created_at": { "$ref": "#/$defs/timestamp" },
    "actor": {
      "type": "object",
      "required": ["kind"],
      "properties": {
        "kind": { "enum": ["user", "clerk", "brain", "import", "external"] },
        "client": {
          "type": "string",
          "description": "program/version of the implementation that applied or proposed the op. The via of any log entry the op writes is copied from it."
        },
        "origin": {
          "type": "string",
          "description": "For kind external: where the change came from when known, for example spool-outbox, lifeproj or unknown."
        },
        "model": { "type": "string" }
      },
      "additionalProperties": true
    },
    "state": { "enum": ["proposed", "approved", "applied", "rejected", "superseded"] },
    "title": { "type": "string", "description": "One line for the review card. Optional." },
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
    "provenance": {
      "type": "object",
      "properties": {
        "events": {
          "type": "array",
          "items": { "type": "string", "minLength": 1 },
          "description": "Capture event ids this proposal was built from."
        },
        "interpretation": {
          "type": "string",
          "minLength": 1,
          "description": "The derived event (the clerk's interpretation) the ops were built from."
        },
        "producer": { "type": "object" }
      },
      "additionalProperties": true
    },
    "ops": {
      "type": "array",
      "minItems": 1,
      "items": {
        "type": "object",
        "required": ["op", "args"],
        "properties": {
          "op": {
            "enum": [
              "add_item", "update_item", "set_status", "complete", "drop", "reopen", "dismiss", "undismiss",
              "file_document", "update_document", "add_log_entry", "set_meta", "migrate"
            ]
          },
          "args": { "type": "object" },
          "note": { "type": "string" },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
          "spans": {
            "type": "array",
            "items": {
              "type": "object",
              "required": ["event", "start", "end"],
              "properties": {
                "event": { "type": "string", "minLength": 1 },
                "start": { "type": "integer", "minimum": 0 },
                "end": { "type": "integer", "minimum": 0 }
              }
            },
            "description": "Spans of the source text each op came from, in the capture event's text, counted in Unicode scalar values and half-open [start, end), as in capture-event-v0.md. end >= start is a conformance check."
          }
        },
        "additionalProperties": true
      }
    },
    "approved_by": { "type": ["string", "null"] },
    "approved_at": { "$ref": "#/$defs/timestamp" },
    "applied_at": { "$ref": "#/$defs/timestamp" },
    "applied_ops": { "type": "array", "items": { "$ref": "#/$defs/uuid" } },
    "rejected_at": { "$ref": "#/$defs/timestamp" },
    "rejected_reason": { "type": "string" },
    "superseded_by": { "$ref": "#/$defs/uuid" }
  },
  "additionalProperties": true,
  "allOf": [
    {
      "if": { "properties": { "state": { "const": "applied" } } },
      "then": { "required": ["approved_by", "applied_at", "applied_ops"] }
    },
    {
      "if": { "properties": { "state": { "const": "approved" } } },
      "then": { "required": ["approved_by", "approved_at"] }
    },
    { "if": { "properties": { "state": { "const": "superseded" } } }, "then": { "required": ["superseded_by"] } }
  ],
  "$defs": {
    "uuid": { "type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" },
    "timestamp": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$",
      "format": "date-time"
    }
  }
}
```

### 10.7 Agenda slice v1

`schemas/slice.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:slice",
  "title": "agenda slice v1 (inbox/<teka>.agenda.json)",
  "description": "What a v0 publisher writes to the spool. The six top-level keys and the nine item keys are lifeproj's frozen contract; format_version, disclosure, closed[], kind and follow_up_at are v1 additions a hub may ignore. lifeproj itself may publish dates in other ISO forms; a reader treats an unparseable due as undated. A reader must ignore unknown keys.",
  "type": "object",
  "required": ["teka", "lifecycle", "active_chapter", "active_chapters", "generated", "items"],
  "properties": {
    "teka": { "type": "string", "minLength": 1, "pattern": "^(?!\\.\\.?$)[^/]+$" },
    "lifecycle": { "type": ["string", "null"] },
    "active_chapter": { "type": ["string", "null"] },
    "active_chapters": { "type": "array", "items": { "type": "string" } },
    "generated": { "$ref": "#/$defs/timestamp" },
    "items": { "type": "array", "items": { "$ref": "#/$defs/slice_item" } },
    "format_version": { "const": "1" },
    "disclosure": {
      "enum": ["full", "title", "kind"],
      "$comment": "The binder's level when the slice was written, so a hub can drop anything a newer, lower level would hide."
    },
    "closed": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "action", "closed_at"],
        "properties": {
          "id": { "type": "string", "minLength": 1 },
          "action": { "enum": ["done", "dropped"] },
          "closed_at": { "$ref": "#/$defs/timestamp" },
          "kind": {
            "enum": [
              "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision",
              "other"
            ]
          }
        },
        "additionalProperties": true
      }
    }
  },
  "additionalProperties": true,
  "$defs": {
    "timestamp": {
      "type": "string",
      "pattern": "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$",
      "format": "date-time"
    },
    "date_or_null": { "type": ["string", "null"], "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" },
    "slice_item": {
      "type": "object",
      "required": ["id", "title", "status", "priority", "due", "no_deadline", "tags", "waiting_on", "link"],
      "properties": {
        "id": { "type": "string", "minLength": 1 },
        "title": { "type": "string", "minLength": 1 },
        "status": { "enum": ["open", "waiting", "blocked", "done"] },
        "priority": { "enum": ["high", "normal", "low"] },
        "due": { "$ref": "#/$defs/date_or_null" },
        "no_deadline": { "type": "boolean" },
        "tags": { "type": "array", "items": { "type": "string" } },
        "waiting_on": { "type": ["string", "null"] },
        "link": { "type": ["string", "null"] },
        "kind": {
          "enum": [
            "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision",
            "other"
          ]
        },
        "follow_up_at": { "type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" }
      },
      "additionalProperties": true,
      "allOf": [
        {
          "if": { "required": ["due"], "properties": { "due": { "type": "string" } } },
          "then": { "properties": { "no_deadline": { "const": false } } },
          "else": { "properties": { "no_deadline": { "const": true } } }
        },
        {
          "if": { "properties": { "status": { "enum": ["waiting", "blocked"] } } },
          "then": { "properties": { "waiting_on": { "type": "string", "minLength": 1 } } }
        }
      ]
    }
  }
}
```

### 10.8 Outbox v1

`schemas/outbox.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:sprava:teka:v0:outbox",
  "title": "outbox v1 (outbox/<teka>.intake.json)",
  "description": "What a hub writes for a teka to drain. completions[] is live; items[] is a documented stub that a drain preserves untouched. teka and generated are informative; a drain ignores them.",
  "type": "object",
  "properties": {
    "teka": { "type": "string" },
    "generated": { "type": "string" },
    "format_version": { "const": "1" },
    "items": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["title"],
        "properties": {
          "title": { "type": "string", "minLength": 1 },
          "note": { "type": "string" },
          "due": { "type": ["string", "null"], "pattern": "^\\d{4}-\\d{2}-\\d{2}$", "format": "date" },
          "source": { "type": "string" }
        },
        "additionalProperties": true
      }
    },
    "completions": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "action"],
        "properties": {
          "id": {
            "type": "string",
            "minLength": 1,
            "description": "The published slice id (teka-prefixed) or the raw catalog id; a drain matches either."
          },
          "action": { "enum": ["done", "dropped"] },
          "at": {
            "type": ["string", "null"],
            "format": "date-time",
            "description": "When the hub saw the item done. A drain copies it into closed_at; a value that is not a string is read as null."
          },
          "source": {
            "type": "string",
            "description": "Where the closing came from. A drain uses osavul when it is absent or not a string."
          },
          "due": {
            "type": "string",
            "pattern": "^\\d{4}-\\d{2}-\\d{2}$",
            "format": "date",
            "description": "Optional, added in v1: the due date the hub showed when the item was checked off. A drain advances a recurring item only when it equals the item's current due (section 8.3)."
          }
        },
        "additionalProperties": true
      }
    }
  },
  "additionalProperties": true
}
```

### 10.9 Validation of the samples

The draft was checked with `check-jsonschema` 0.38.2 against invented samples. Must pass (39):

- a fresh lifeproj v2 catalog built by hand from `scaffold.py`;
- a live v2 catalog with a bare id, a prefixed id, a `done` item, a waiting item without `follow_up_at`, an unknown field, a `\u`-escaped title and a foreign absolute path;
- a v1 legacy catalog, and a v1 catalog that is loose everywhere (a lifecycle word lifeproj does not know, a free-text `created`, a string `next_item_id`, a duplicated module, documents and entities without ids or status, a legacy closure with action `completed`);
- v2 catalogs that lifeproj accepts: an empty `due` with `no_deadline`, a compact `due`, an integer id, a name with a space, entity rows without `status` and with a decimal price;
- a v0 catalog with every new field, a v0 catalog with unknown fields and arrays (a float, duplicate ids in an unknown array), a v0 catalog with legacy log entries, a v0 catalog with an open integer id and the closure of another, and one with a `closed-duplicate` entry;
- a twelve-op log with real RFC 8785 hashes: adoption, a derived field, a two-op adoption batch (a closure and the migrate stamp), a two-op clerk batch (a one-off item and a recurring one), a status change, an external edit by a terminal agent, an undo of the status change, a recurring item advanced, a closure, and its undo by `reopen`;
- the final catalog of that log, a slice at disclosure level `title`, an outbox, an outbox completion with `due`, a proposal with a placeholder id, and single item, document and log-entry records;
- single ops: a `file_document`, a `reopen` of an integer id, a `set_status` that marks a derived `follow_up_at`, a `rename_teka` with `until`, an `expunge`, a drained completion with actor origin `spool-outbox`, and an `update_document` that records a path under `chapters/`.

All passed. Thirty-four deliberately broken samples all failed on the intended rule: both `due` and `no_deadline`; waiting without a party; a compact date in v0; `done` in v0; `redact` without `kind`; waiting without `follow_up_at`; null `due`, `waiting_on` and `link` in v0; a clerk op without approval; `update_item` setting `status`; `update_item` setting `dismissed`; `set_meta` setting `disclosure`; `set_disclosure` from a clerk; a `complete` whose actor has no `client`; a `rename_teka` without `until`; an `expunge` that records a digest; a `file_document` moving `../../.ssh/id_ed25519` to `.claude/settings.json`; `file_document` paths `catalog.json`, `Catalog.json`, `Dashboard.md`, `Claude.md`, `documents/CLAUDE.md`, `correspondence/notary/agents.md`, `.teka.lock`, `Intake/_converted/will.pdf`, `Chapters/tenancy-1/lease.pdf`, `Ledger/2026-10.csv` and `SCRIPTS/run.command`, and paths holding U+202E, U+200B or U+0085; an external edit with a `move` step and an `add` without a value; an op timestamp with an offset; a slice item missing keys; and a slice `closed[]` entry with a null `closed_at`.

The sample op log was then replayed by a small reference applier that follows section 6: it reproduced every `after_hash` and the final catalog. A second log that ends with an incomplete batch was replayed too, and the incomplete batch was ignored as section 6.9 says. Finally the applier's expunge (section 6.11) was run on the sample log with the texts `2026`, `open`, `rent` and a four-digit run taken from one of its hashes. Each time every rewritten op line and the final catalog stayed schema-valid, replay reproduced every re-stamped hash, and no key, id, UUID, date, timestamp, path or closed-list value changed.

The samples, the validation script and the reference applier are not yet in the repository; they sit in the planning session's scratch folder. They are to be published under `docs/spec/conformance/`, under Apache-2.0 like the schemas (decisions.md L2), after a privacy scan. Until then checks 8, 23, 62 and 72 are marked "pending publication": a second implementer cannot run them from this document alone. The validation command is:

```
uvx --from check-jsonschema check-jsonschema --schemafile docs/spec/schemas/<name>.schema.json <document.json>
```

## 11. Conformance checks

Each statement is testable. Where lifeproj already pins it, the test is named (`tests/` in the lifeproj repository; all 149 pass as of 2026-10-06). Each check carries its class from section 1.6: `[R]` reader, `[W]` catalog writer, `[W, v0]` a catalog writer that claims v0, `[F]` full implementation, `[P]` federation profile, `[H]` slice reader. A check marked "pending publication" needs the samples of section 10.9, which are not yet in the repository.

Folder and identity

1. `[R]` A folder is a teka exactly when it contains `catalog.json`. The teka is corrupt when the file does not parse or is not a JSON object. An object without `meta` or without `meta.schema_version` is a pre-lifeproj catalog that needs migration, never corrupt. (`test_drain_all_skips_unmigrated`, `test_drain_all_errors_on_broken_catalog` for the existence part; the rest is new)
2. `[R]` `meta.name` equals the folder basename after NFC, compared case-sensitively; a mismatch puts the teka in needs attention. `[F]` A teka a v0 implementation creates has a name matching `^[a-z0-9][a-z0-9-]*$`, unique among the known tekas and their unexpired former names. (`test_new_rejects_path_like_names` for lifeproj's name rule; the rest is new)
3. `[F]` Given a teka whose `catalog_check.py`, `scripts/` files, `.claude/` hooks and a filed `.command` file each write a marker file when run, no marker exists after adoption, a series of ops, a publish and a drain. (new)
4. `[W]` Inside the teka, an implementation deletes no file, except that filing moves files out of `intake/` and `intake/_converted/` may be cleared. Filing never replaces an existing file. (new)

Catalog structure

5. `[R]` Within `open_items[]`, `documents[]` and `processing_log[]`, ids among entries that carry an `id` are unique. A duplicate in another array is reported and blocks nothing. (`test_validate_flags_each_rule`, duplicate branch of `check_open_items`)
6. `[W]` Unknown top-level keys, unknown arrays and unknown fields survive a rewrite unchanged and in order, decimals included. (new; lifeproj's checker tolerates them)
7. `[R]` In a lifeproj catalog a missing core array is read as empty, never reported. In a stamped v0 catalog it is a rule failure, repaired by proposal. (`CATALOG_CHECK`, `data.setdefault`, for the lifeproj part)
8. `[R]` A fresh lifeproj catalog validates against `catalog.schema.json` without changes, and so do the lifeproj-valid samples of section 10.9. (checked in section 10.9, pending publication; `test_generated_catalog_check_runs_clean` pins lifeproj's side)

Items

9. `[R]` `id`, `title`, `status`, `priority` are present and non-empty. (`test_catalog_check_enforces_strict_open_items`)
10. `[W]` `status` is one of `open`, `waiting`, `blocked` or `done`. `[W, v0]` An implementation never writes `done` into a catalog whose `meta.format` is `teka`. (`test_catalog_check_enforces_strict_open_items`; the `done` rule is new)
11. `[R]` `priority` is `high`, `normal` or `low`. (`test_validate_flags_each_rule`)
12. `[R]` Exactly one of `due` and `no_deadline: true` is present; in a lifeproj catalog `null`, an empty `due` and `false` count as absent. (`test_validate_flags_each_rule`, `test_catalog_check_enforces_strict_open_items`)
13. `[W]` A `due` written by a v0 implementation matches `^\d{4}-\d{2}-\d{2}$` and is a real date. lifeproj's `20260705` and `2026-W27-1` are read as dates and rewritten at adoption. (new; lifeproj accepts them)
14. `[R]` `waiting_on` is a non-empty string when status is `waiting` or `blocked`. (`test_validate_flags_each_rule`, `test_catalog_check_enforces_strict_open_items`)
15. `[R]` `tags` is an array; `redact` is a boolean; `slice_title` is a non-empty string when present. (`test_validate_redact_and_slice_title_types`)
16. `[R]` An open item's id does not appear as the `id` of any processing log entry, ids being compared by JSON type and value. (`test_validate_flags_each_rule`, reuse branch)
17. `[W, v0]` `follow_up_at` is present on every waiting or blocked item in a v0 catalog. (new)
18. `[W, v0]` The item's `kind` is present when `redact` is `true`, and is from the closed list. (new)
19. `[F]` `recurrence` is well-formed and requires `due`; `complete` records `next_due` equal to the first matching date strictly after the later of `due` and today, with month-length clamping. (new)
20. `[R]` `dismissed` items appear in no bucket. `[P]` They appear in no slice. (new)

Buckets and dates

21. `[R]` Bucket assignment follows section 5.2 exactly: a waiting or blocked item is never Overdue, and a loose v1 item without a valid date lands in No deadline. (`test_items_land_in_urgency_buckets`, `test_waiting_wins_over_the_date_bucket`, `test_unparseable_due_is_undated_never_dropped` pin lifeproj's six-bucket version)
22. `[R]` Recently closed covers closures whose local closing date is today or within the 6 days before it, across midnight in a time zone behind UTC. The closing date comes from `closed_at` as a date-time, then `closed_at` as a `YYYY-MM-DD` date, then `at`; a date after today counts as today; an entry with none is left out. A `done` item in `open_items[]` is listed last as "date unknown" and not counted. A compact `due` such as `20260705` buckets as a date, and the integer `20260705` does not. (new)

Ops and the op log

23. `[F]` Every applied op's `before_hash` equals the `after_hash` of the previous op that took effect, and replay from the latest `import_snapshot` reproduces every `after_hash`. Replaying the sample log of section 10.9 reproduces every hash and the final catalog. (new; the sample part is pending publication)
24. `[F]` The content hash is SHA-256 over the RFC 8785 canonical form, so re-indenting or `\u`-escaping a catalog does not change it; the vectors of check 63 pass. (new)
25. `[F]` The transaction guard rejects an op that adds a new violation or leaves a record it touches invalid, and nothing changes. In a catalog with two broken items, an op that repairs one of them is accepted. A `complete` of an item listed before a broken item is accepted: the broken item's violation keeps its identity although its position changed (section 6.3). (new)
26. `[F]` An op with actor `clerk` or `brain` carries `proposal` and a non-empty `approved_by`. (schema; checked in section 10.9)
27. `[F]` `update_item` never changes `id`, `status`, `dismissed`, `created_at` or `updated_at`, and a field never appears in both `set` and `unset`. (schema, except the last part; checked in section 10.9)
28. `[F]` A catalog changed outside the implementation yields exactly one `external_edit` op whose patch, applied to the expected state, gives the found state, and the next read finds no change. (new)
29. `[F]` Closures from `complete` and `drop` land in the processing log with `id`, `title` and `final`, and `final` holds every item field except `id`, `title` and `kind`. The closure of an item whose id is already closed writes a `closed-duplicate` entry without `id`. No other entry carries `id`; `import_snapshot`, `migrate` (outside its own patch), `external_edit` and `abort` write no entry. `add_log_entry` replaces any `at`, `via` and `op_id` in its entry. (new; `test_drain_applies_done_and_dropped` pins lifeproj's closure entries)
30. `[F]` The first line of `.sprava/ops.ndjson` is an `import_snapshot`. (new)

Dashboard

31. `[F]` Rendering the same inputs twice gives identical bytes; two implementations' renderings differ only in the marker and header lines. (new)
32. `[F]` Sections appear in bucket order; an empty section reads `_None._`; the Notes section, from the line `## Notes` to the end, is copied unchanged. Editing only the Notes section produces no saved copy. A switched dashboard whose old `##` headings were demoted into Notes survives two renders byte for byte. (new)

Federation profile

33. `[P]` The spool root resolves as `$OSAVUL_SPOOL`, else `$XDG_DATA_HOME/osavul`, else `~/.local/share/osavul`; an absent root means a quiet no-op and the root is never created. (`test_publish_noop_when_spool_absent`, `test_drain_stub_is_safe`)
34. `[P]` A slice has the six top-level keys in order, then `format_version`, `disclosure` and `closed` in that order, and each item exactly the nine keys in order, followed only by `kind` and `follow_up_at`. (`test_project_slice_shape` for lifeproj's part)
35. `[P]` Slice ids are prefixed with `<teka>-` once, never twice. (`test_id_prefix_is_idempotent`)
36. `[P]` At `full`: `slice_title` wins; `redact: true` gives `[redacted]`, `[party]` and, from a v0 publisher, a null `link`; tags pass through; an unredacted item's `waiting_on` passes through. (`test_redaction_projection`; the null `link` is new)
37. `[P]` `active_chapters` projection: one chapter fills `active_chapter`; many leave it null; `current_chapters` is the fallback; none gives `[]` and null. (`test_active_chapters_projection`)
38. `[P]` Publishing validates items under the v2 rules regardless of `schema_version`; on error nothing is written. (`test_publish_rejects_invalid_open_items`, `test_publish_writes_valid_slice`)
39. `[P]` The slice is written atomically through a temporary file and a rename. (`publish`; new test)
40. `[P]` A drain matches a completion by raw id, `<teka>-<raw id>`, the alias of any open item, or the id last published for an item; in a former name's outbox, also by `<former>-<raw id>`. The closure entry keeps the raw id with its JSON type. (`test_drain_resolves_prefixed_slice_id`; the rest is new)
41. `[P]` A drain applies only `done` and `dropped`, skips unknown and already-closed ids, writes the catalog before acknowledging the outbox, acknowledges by removing applied completions (matched by `id` and `at`) from a fresh read of the outbox, deletes the file only when nothing else is left in it, leaves unknown completions and `items[]` in place, and is idempotent. (`test_drain_applies_done_and_dropped`, `test_drain_idempotent_and_preserves_items`, `test_drain_no_outbox_is_noop` for lifeproj's part)
42. `[P]` A drain never republishes; a fleet loop republishes only tekas that drained something. (`test_drain_all_fleet`)
43. `[P]` A broken `catalog.json` is an error that does not stop the fleet; a folder without one is a skip. (`test_drain_all_errors_on_broken_catalog`, `test_drain_all_skips_unmigrated`)
44. `[H]` A slice reader skips `done` items, tolerates sparse items and offset `generated` stamps, buckets an unparseable `due` as undated, flags a slice older than 7 days, and never reads a dot-file in `inbox/`. (`test_tolerates_offset_stamps_and_sparse_items`, `test_unparseable_due_is_undated_never_dropped`, `test_sources_report_stale_never_published_and_undrained`)
45. `[P]` At disclosure level `none` no slice exists. At `kind` every title is `[redacted]`, tags are empty, chapters are masked and every item carries a kind. At `title`, `waiting_on` is `[party]` only where a party exists, a redacted item's tags are empty, and chapters are masked. At `title` and `kind`, every id not in the recommended form is aliased. Below `full`, `closed[].closed_at` carries the day only. (new)

Adoption

46. `[F]` Adoption changes no file but `.sprava/`, `.teka.lock` and an absent or marker-bearing `DASHBOARD.md` until an op is approved or a mechanical step is applied. (new)
47. `[R]` A v1 catalog is "needs migration", never corrupt; strict failures on it are reported, not rejected. A digit-string or `2.0` `schema_version` is read as v1. (`test_catalog_check_legacy_schema_skips_strict` pins lifeproj's leniency)
48. `[F]` Foreign absolute paths and non-path links are reported and never rewritten or opened. (`test_data_json_is_not_rewritten`)
49. `[F]` `catalog_check.py` is classified by hash and never run. (new)
50. `[F]` A derived `follow_up_at` is listed in the item's `derived` array, and the name is removed when an op later sets the field. (new)

Write protocol and recovery

51. `[W]` A writer takes the exclusive lock on `.teka.lock` and hashes the catalog again before its rename. A drain and an op run at the same moment never lose either change. (new; lifeproj needs a change, section 9.8)
52. `[F]` Crash injection: killing the writer after the op log is synced and before the catalog rename, then reading again, rolls the change forward and records no `external_edit`. The same holds for a batch, and for a `file_document` killed before and after the file move. (new)
53. `[F]` A torn last line, or a trailing batch with fewer lines than its `batch_size`, is ignored and truncated before the next append. (new)
54. `[F]` Replaying an op log on a later day, after the filed files changed, gives the same hashes. (new)
55. `[F]` `updated_at` is set to the op's `at` by exactly the ops section 6.3 lists. (new)
56. `[F]` Two proposals that each add one item, approved one after the other, both apply, with different minted ids. (new)
57. `[F]` Each op in the table of section 6.10 is reversed by its compensating op. A mistaken `complete` is undone by `reopen`, and the new item carries `reopened_from`. (new)
58. `[P]` A drained completion for a recurring item, delivered twice, advances it once. A completion whose `due` is earlier than the item's `due`, including one ticked in the hub after the app already advanced and republished, is acknowledged without a second advance. A completion without `due`, or with a null `at`, goes to a card and never advances on its own. (new)
59. `[W]` With an unknown `format_version`, nothing in the teka is written, `DASHBOARD.md` included (section 1.4). (new)
60. `[F]` `set_status` to `open` removes `waiting_on`, `follow_up_at` and `expected_by` unless the op supplies them. (new)
61. `[F]` `format: "teka"` is stamped only on a catalog that then satisfies the v0 schema and the conformance checks. (new)

Containment and privacy

62. `[F]` A `file_document` whose `from` is outside `intake/`, or whose `path` breaks the rules of section 4.3, is rejected, reserved names compared without regard to case and agent manuals refused in any segment; so is any path that reaches outside the teka through a symlink. (samples in section 10.9, pending publication; the symlink part is new)
63. `[R]` Hash vectors. Two inputs that differ only in escaping, `{"title": "Caf\u00e9"}` (the escape written out, six characters) and `{"title": "Café"}` (the precomposed letter U+00E9), both hash to `sha256:97abf59ac9ce42d34f62d32f6b75eb18a16cedc16ef9de9c818e902a93c51e5f`. The same title with a decomposed `é` (an `e` followed by U+0301) hashes to `sha256:e7156f5c49620b91d15fd0591e9502fe9790b7f1159314a6f77591083fbd7fac`: RFC 8785 does not normalize, so a tool that rewrites NFC text as NFD causes an external edit. `{"amount": 12.5, "big": 1e16, "small": 1e-7}` canonicalizes to `{"amount":12.5,"big":10000000000000000,"small":1e-7}` and hashes to `sha256:bf32401fef70ae0645acbb210250c2874daa04e3fbc33c94e4ac6463c89d5acf`. `{"ﬁ": 1, "😀": 2}` canonicalizes to `{"😀":2,"ﬁ":1}` and hashes to `sha256:14dc6c14e11d686bbd1332452e5c8dc999ac1479def9c87e945308b1b27d469b`. A duplicate key, a lone `\ud800` and the integer 9007199254740993 each put a catalog in needs attention, and nothing is written until a repair is approved. (new)
64. `[F]` A title `![x](https://tracker.example/p.png)` renders in `DASHBOARD.md` as inert text. (new)
65. `[P]` A teka's projected slice ids are unique; publishing fails on a collision. (new)
66. `[P]` A redacted item whose id is not in the recommended form of section 5.6 is published under an alias, and the drain resolves the alias. An id such as `sell-house-before-probate`, which matches the minted pattern but not the recommended form, is aliased. (new)
67. `[F]` Index, search and MCP reads never return content from `scripts/`, `.claude/`, `.agents/`, `.git/`, `.sprava/`, a `.env` file, `intake/mail/state.json` or a key file as section 3.4 lists them. (new)
68. `[F]` After an `expunge`, the forgotten text appears in no free-text value of `catalog.json`, `ops.ndjson`, the proposals, `snapshot.json`, the Notes section of `DASHBOARD.md`, `.sprava/adopted/` or `.sprava/torn/`; `intake/_converted/` is empty; the bytes of the new `index.sqlite` and of its `-wal` and `-journal` files hold no copy; and the slice was republished. (new)
69. `[P]` A publisher refuses a symlinked `inbox/` or `outbox/` and creates slice files with mode 0600. (new)
70. `[F]` Adoption saves `DASHBOARD.md` to `.sprava/adopted/` before writing anything, and no rendering replaces a hand-edited dashboard without a saved copy. (new)
71. `[P]` A publisher that does not implement sections 5.5 to 5.7 does not publish or drain a stamped v0 teka, whether it is run on one folder or on a fleet. (new; requires the lifeproj change of section 9.8)

Added after the second review

72. `[F]` Expunging `2026`, `open`, and four digits that occur inside one of the log's hashes changes no key, id, UUID, date, timestamp, path, link or closed-list value; every op line stays schema-valid; replay reproduces every re-stamped hash; and the `expunge` op holds no digest of the text. (checked on the sample log, pending publication)
73. `[F]` Crash injection: after a completed write, the user restores the previous catalog by hand. The next read records an `external_edit` and shows the overwritten-change card; it does not roll forward. A crash after the rename and before the snapshot update leaves no `abort` and refreshes the snapshot. (new)
74. `[F]` A power loss that leaves `catalog.json` empty is reported as corrupt, and the app offers a restore from the op log or the snapshot, never applying it on its own. (new)
75. `[F]` A simulated lifeproj drain that reads the catalog, waits while the implementation applies an approved op, and then renames its own copy over the catalog, yields an external edit labelled as an overwritten change with a card to apply the lost ops again. (new)
76. `[P]` A completion the hub adds to the outbox while a drain is running survives the acknowledgement. (new)
77. `[P]` A completion with `source: null`, one with a numeric `at`, and one that the guard rejects do not stop the other completions of the same drain from applying; the rejected one stays in the outbox. (new)
78. `[P]` After `rename_teka`, the old slice is removed, a completion for a bare id published under the former name resolves through the former outbox, and no new teka may take the former name before its `until` date. (new)
79. `[P]` When the slice on the spool differs from the hash recorded in `.sprava/cursors.json`, the implementation republishes or removes it and tells the user. A teka holding `catalog_check.py` or a manual that runs `lifeproj publish` is offered only disclosure level `full` until section 9.8's change is confirmed. (new)
80. `[F]` A complete or a drop of an integer-id item writes a closure entry whose `id` is that integer; a `reopen` of it carries the integer in `args.id` and in `provenance.reopened_from`. (samples in section 10.9, pending publication)
81. `[F]` The guard refuses `complete` without `next_due` on a recurring item, and with `next_due` on an item without `recurrence`. A `set_status` with `derived` marks the field; one without it removes the field's name; an empty `derived` is removed. (new)
82. `[F]` A proposal file planted in `.sprava/proposals/` by another program is shown as "found in the folder, origin unknown". A planted `index.sqlite` is rebuilt, not opened. (new)
83. `[F]` Viewing a filed email `.md` that holds `![x](https://tracker.example/p.png)` makes no network request. (new)
84. `[R]` The level table of section 9.6 classifies `format: "Teka"` as unknown level, `format: "teka"` without `format_version` as a broken stamp, `format: "teka"` with `schema_version: "2"` as needing attention, and `schema_version: 0` as pre-lifeproj. (new)
85. `[F]` A found item `kind: "invoice"` survives stamping as `legacy_kind`, and the stamped item carries a kind from the closed list. (new)
86. `[F]` A teka inside iCloud Drive or a File Provider folder is reported as uploaded by a sync service, at creation and at adoption. (new)

## 12. Open questions for the author

1. Is the op log history that must survive, or a cache? This draft says the op log, the proposals, the saved dashboards and the slice key are the files under `.sprava/` that cannot be rebuilt. Closure entries now keep the closed item in `final`, so the catalog alone no longer loses fields when an item closes (decisions.md F1, F2). If you want "everything under `.sprava/` is disposable", history must be accepted as lossy.
2. The documents and log shapes of your live tekas are unknown (decisions.md F11). Section 4.3 requires `id`, `title` and `path` for v0 document records. Will you run the structure-only survey so the legacy-key mapping in section 9.5 can be written and lossless adoption tested?
3. Should `title` disclosure mask `waiting_on` and `link` for every item, as section 5.5 does, or only honour per-item `redact` as `full` does? The hub shows the party in its Waiting bucket, so the choice affects its usefulness.
4. Is the `kind` list right for your tekas? The draft uses eight values with `other` as the escape hatch, and freezes the list within v0.
5. Hub annotations: the hub also keeps an `importance` field whose type is unknown to this draft. Should `importance` become an item field (and with what values), stay hub-only, or be dropped?
6. Where does a teka's default context live? Section 5.9 resolves an item's context as explicit tag, teka default, `@anywhere`, but `meta` has no field for the default yet. Proposed: `meta.default_context`.
7. Mechanical steps at adoption (section 9.4 step 3) are applied without a proposal because they are lossless and marked: deriving `follow_up_at`, removing null values, removing an empty `due`, and rewriting compact dates. Do you want them to go through the review queue anyway?
8. Does the existing hub ignore unknown keys in a slice and unknown top-level fields (`format_version`, `disclosure`, `closed[]`)? Its code is private; section 8.4 states the rule as a requirement, and the first v1 publish against the live hub will tell.
9. `closed[]` in the slice: this draft answers "ids, actions, dates and kind only". Closure entries already keep `redact` and `slice_title` inside `final` (section 5.10), so per-item redaction could be honoured if titles were ever published there. Should they ever be?
10. Local git in tekas (decisions.md F12): tolerated and ignored here. Should a `.git/` history count as provenance when `.sprava/ops.ndjson` is missing?
11. `$id` for the schemas uses `urn:sprava:teka:v0:` because no domain is registered (decisions.md P11). Replace with `https://sprava.app/...` once the name and domain are settled?
12. Should the dashboard carry the redacted or the natural titles? The draft uses natural titles because the file is inside the teka. If a teka folder is ever shared or synced wholesale, that choice leaks.
13. How long does a rejected proposal stay in `.sprava/proposals/`? The draft proposes 90 days unless the user keeps it. Forever would keep the provenance of what the clerk got wrong, and also any sensitive text the rejected proposal holds.
14. Proposal: a teka's own staleness signal, "last activity", taken from the `at` of its latest op, beside the slice's `generated` stamp. Which threshold should raise the digest-overdue signal in the app?
15. Should `expunge` (section 6.11) be part of v0? It is the only way to forget a dictated account number or health detail, and it is the one exception to the append-only op log.
16. decisions.md F1 says everything outside `.sprava/`, `catalog.json` and `DASHBOARD.md` is left alone. Filing into document folders, `intake/_converted/` and `.teka.lock` go beyond that (section 9.7). Proposed: amend F1 to name these three exceptions. A related question on F7: lifeproj's chapters and entities modules keep each chapter's or entity's documents in its own subfolder, and decisions.md P9 recommends a rental property with tenancies as chapters as a first template. This draft keeps `chapters/` and `entities/` closed to filing, as F7's "left opaque" reads, and lets `update_document` only record paths there. Should filing be allowed to create new files under `chapters/<name>/` (not `_past/`) and `entities/<id>/`, never replacing one?
17. decisions.md F7 asks for `at` (or `closed_at`) and `action` on every processing log entry. This draft requires them only on entries a v0 implementation writes, because legacy entries cannot be rewritten (section 4.5). Update F7?
18. This draft adds items to the format that no decision covers. Should they become an F-entry in decisions.md? They are:
    - item fields `contexts`, `estimate_min`, `dismissed` and `derived`; log entry fields `final`, `op_id`, `item`, `document`, `reopened_from`, `next_due` and the action `closed-duplicate`; `meta.former_names`; outbox v1's optional `due` on a completion; the slice's `disclosure`;
    - the ops `dismiss`, `undismiss`, `reopen`, `rename_teka`, `abort` and `expunge`; the envelope field `batch_size`; the actor field `origin`; a later `import_snapshot` as a re-base point;
    - the rules: ASCII minted ids, integer ids kept with their type, the mint prefix and the recommended-form test (section 5.6); aliases and `.sprava/slice-key`; the map of published ids; I-JSON; the `Z`-only timestamp; the conformance classes; the `id_scheme` values; `.sprava/adopted/` and `.sprava/torn/`; the `legacy_<field>` rule (section 9.5); the level table (section 9.6);
    - the mapping of the hub's dismiss (section 5.7): a recurring item maps to `drop`, which reads F3's "dismissing ends it" literally. If you prefer that a hub dismiss only hides a recurring item, that row becomes `dismiss`;
    - v0 has no op for entity rows (section 4.6). Should `add_entity` and `update_entity` ({id, set?, unset?}, never `id`) join v0, so that an accepted bid is a recorded change rather than an external edit?
19. Should a drain hold some completions for approval: more than a set number of closures at once, or any closure of a `legal-deadline` or `payment` item? That would protect against a misbehaving local process writing the outbox, but it departs from decisions.md F8, which keeps lifeproj's completion semantics exactly. This draft keeps F8 and only shows each drained batch as an undoable change.
20. The slice gains a fifth additive field, `disclosure`, beyond the four in decisions.md F8. At `full`, a redacted item's `link` is published as null and a hand-made id as an alias, which departs from lifeproj's projection (section 5.5). At `title` and `kind`, which lifeproj does not have, every id that is not in the recommended form is aliased, redacted or not, and a redacted item's tags are emptied at `title`. Accept these departures?
21. A sensitive teka's name is visible to the hub at every level except `none`. Should `meta` gain a `public_name` that the slice and the spool file use instead?
22. When will lifeproj gain the changes of section 9.8? Until then, every adopted teka that lifeproj can reach keeps disclosure level `full` and cannot use `dismiss` or recurrence. Reachable includes every teka that holds `catalog_check.py` or a manual that runs `lifeproj publish`, which today is every teka lifeproj made.
23. The hub writes the outbox without a lock, so a drain can still lose a completion that lands between its last read and its rename (section 8.3). Should the hub take a lock on the outbox, or write one file per completion, which would make acknowledgement race-free?
24. Recurring items move into the teka (section 5.4). Once an item carries `recurrence`, the hub must stop advancing or closing it on its own, and should add `due` to its completions so the drain can tell occurrences apart. How should the hub learn which items recur: a `recurrence` field in the slice, or the `kind`?
25. Leaving Sprava is a hand edit today (section 9.4, "Leaving"). Should v0 have a release op that removes the stamp, as the one exception to "migrate never removes a key"?
26. Changes `docs/architecture.md` and `docs/mvp.md` ask of this draft, not yet made here. Each needs the author's acceptance (architecture.md section 13, items 8, 10, 11, 31, 36 and 43; mvp.md section 8, questions 3 and 13):
    - a `withdrawn` proposal state, so that a brain's withdrawal is not recorded as a rejection, and a named `expect` field on proposals (section 6.5);
    - an optional `seal` field on op lines, which other implementations ignore, and the op types `takeover` and `rekey`, which section 1.3 makes a version change because op types are a closed list;
    - an actor field for the MCP client's name on `brain` ops, because `actor.client` names the implementation that applied the op (section 6.2);
    - `documents[].sensitivity` with the value `private`, honoured by every reader, whose removal or lowering is a privacy change. capture-event-v0 section 3.3 calls the same marker `redact: true` on the document record, which section 4.3 does not define, so one name must be chosen for both drafts;
    - `.sprava/owner.json`, the owner record, and `.sprava/proposals/<id>/`, the body of a document a brain proposes, in the table of section 7.2, which today requires every unlisted file there to be rebuildable;
    - in sections 6.5 and 9.7, two more writes and one rule: the visible `captures/` folder of filed captures (which mvp.md defers), a new file created in a document folder for an approved brain document, and the rule that nothing a proposal carries reaches the teka's visible folders before approval;
    - in section 9.8, lifeproj's refusal keyed on adoption (a teka that has `.sprava/ops.ndjson`) as well as on `meta.format`, refusing with one line and exit status 0, and the outbox acknowledgement of section 8.3 asked of lifeproj too;
    - in section 9.8, an addendum that forbids every hand edit of `catalog.json`, closing included, opens with a marker line, and says it overrides older instructions in the same manual;
    - after an outside edit, mechanical repairs applied as one undoable `import` batch after a quiet period with no outside write, where section 6.5's complete list of changes without a proposal names mechanical steps only at adoption and section 6.7 step 7 offers every repair as a proposal;
    - rules for creating a teka beyond sections 3.1, 4.2 and 6.9: an empty stamped v0 catalog and the template's checklist offered as one proposal.
