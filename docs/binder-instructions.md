# Binder instructions

How the person sets a binder's mission and basic rules in the app, how the reader of new intake documents
follows them, and how a template starts a binder with some. Status: proposed 2026-11-16 with decisions.md D43,
revised the same day after one critique. Every example is invented.

## 1. Why

On 2026-11-16 the author answered the lead's picks with "go with your picks on all four" (decisions.md D43). The
pick here, over keeping `AGENTS.md` edited by hand: an Instructions editor in the app, intake filing that follows
it, and templates carrying a starting text. The reason: there will be several generic binders, and each
must handle intake its own way, splitting the work and the state it keeps in its own way. Two binders made from
the same template differ in what they are for, so each needs its own
words on where a document goes, how it is named, and what goes on the to-do list. Those words should live in
the binder, be editable in the app, and be followed by the reader of new documents as well as by the binder's
Claude.

## 2. Where the instructions live

In the binder's `AGENTS.md`, in the person's part: everything outside Sprava's section. No new file.

- The binder's Claude already reads `AGENTS.md` first in every session as how the person works in this binder
  (decisions.md D33; `ClaudeConversationPolicy`), and any terminal agent the person runs there reads it too. A
  second file would be a second place for the same thing.
- It is a plain file in the binder: visible, editable in any text editor, backed up and restored with the binder.
- It is closed to the binder's Claude: the sandbox refuses writes to it (`ClaudeReadLaunch`), so a document
  that steers a conversation cannot rewrite the person's rules.

**Sprava's section.** decisions.md F14 gives Sprava a section of `AGENTS.md` between two marker lines. That
writer is not built: today Sprava writes no `AGENTS.md`, a binder created in the app has none, and a binder
adopted in place keeps the one it had. This design fixes the marker lines so the editor and F14's later writer
agree:

```
<!-- sprava:begin -->
...Sprava's text...
<!-- sprava:end -->
```

Each is a line of its own, compared after trimming spaces. The first begin line and the next end line bound
the section; the person's part is the text before the begin line followed by the text after the end line's
line break. A file with no begin line is all the person's. A begin line with no end line after it, a second
begin line, or an end line outside a section makes the file ambiguous: it is shown, not saved over, and the
page says to fix the marker lines in a text editor. The old addendum marker `<!-- sprava-managed v0 -->`
(binder-v0 §9.8) is not one of these: an addendum the person pasted is their text.

**Bounds.** `AGENTS.md` is read as UTF-8 through `SafeFile`, from the binder's folder down with no link on the
way, at most 1 MiB. A file that is a link, not a regular file, larger, or not UTF-8 is left as it is: the page
says why and offers no save. A saved person's part is at most 16,000 characters (Swift characters) and 64 KiB
of UTF-8, about 4,000 tokens.

**Accepted text.** The reader of new documents follows the person's part only when it is the text the person
last saved or confirmed in the app. Its digest (SHA-256 of the UTF-8) is kept in `.sprava/instructions.json`,
which the binder's Claude cannot write either. Text changed outside the app, by the person in a text editor or
by a terminal agent they ran, and the old manual of a binder adopted in place, are shown on the tab with "Not
used for filing until you save it here"; one click, **Use this text**, confirms it as it is. Until then the
reader files as if there were no instructions, and a card it makes says "Your instructions changed outside
Sprava and were not used". The binder's conversation reads `AGENTS.md` as it is, as today (D33).

## 3. The editor

A fourth tab, **Instructions**, on the binder's Project surface beside To-dos, Explore and History. It saves for
an adopted binder this Mac owns whose writes are not blocked; elsewhere it shows the text read-only.

- One plain text editor with the person's part, and above it one line: "How this binder works: what it is
  for, where things go, what belongs on your to-do list. Sprava's reader of new documents and this binder's
  conversation follow it." When the binder is connected to Claude with file changes allowed and intake shared, a
  second line says the instructions go to Claude with each new intake document (section 4.3).
- **Save** and **Revert**, enabled only with a change, and **Use this text** when the text on disk is not the
  accepted one. The page reads `AGENTS.md` and the accepted digest itself through a `BinderFormat` reader, so
  it shows them while the runtime is down (code-structure rule 5). It writes only through the runtime.
- **The save.** The command `save_instructions` carries the binder, the new text, and the digest of the person's
  part as the page read it. The runtime checks the binder as for any write (adopted, owned by this Mac, writes
  not blocked, no expunge pending), reads `AGENTS.md` again, and refuses with nothing written when the person's
  part no longer has that digest ("AGENTS.md changed since this page read it. Your text is still here; copy it,
  then Reload."), when the file is ambiguous or out of bounds, or when the text is over the bound. Otherwise it
  keeps the file as it was (section 3, Undo), writes through `AtomicFile` Sprava's section exactly as found, if
  any, then the person's text exactly as given, mode 0644, and records the new digest as accepted. An empty
  text saves an empty part; the file is never deleted, and saving the same text writes nothing but the
  acceptance (this is **Use this text**). It answers with the new digest.
- **Undo.** Before it writes, the save keeps the file it replaces, whole, as `.sprava/instructions-previous.md`,
  and records in `.sprava/instructions.json` the digest the save left. The tab offers **Undo last save** while
  the person's part still has that digest, in this session or after a restart. `undo_instructions` puts the
  previous person's part back under the current Sprava section, with no size bound (the replaced text may be a
  long old manual the person just trimmed), records it as accepted only if it was accepted before, and clears
  the record: one level of Undo. Older versions are in the binder's backups.
- **A conversation turn's Undo never touches it.** The turn history records the person's edits before a turn
  and treats every other change until the turn ends as the turn's, so a save made while Claude is answering
  would be taken back by that turn's Undo. The binder's Claude cannot write `AGENTS.md` or `CLAUDE.md`, so the
  turn history leaves both out, as it leaves out `catalog.json` and `DASHBOARD.md`.
- **The conversation rereads it.** The line Sprava puts before each message gives `DASHBOARD.md`'s revision;
  it gains `AGENTS.md`'s, and the session is told to read a file again when its revision differs.
- **Lifeproj words.** A binder whose `AGENTS.md` tells agents to run `lifeproj publish` or `lifeproj drain`
  counts as one lifeproj can reach, and repeats are off there (`Adoption.lifeprojCanReach`). The tab says so
  under the editor when the text holds those words, before the person saves.

**Bringing in an imported binder's old instructions.** The import of binder-v0 §9.4 sets aside the old
manuals as `.sprava/adopted/manuals/AGENTS.md.saved` and `CLAUDE.md.saved` and carries none of their text
into the new `AGENTS.md`. When either exists, the tab shows **Copy in the old AGENTS.md** (or `CLAUDE.md`),
which appends that file's text to the editor, unsaved, for the person to read, trim (an old manual often tells
an agent to run lifeproj, which nothing here does) and save. It is never copied on its own. The import by copy
is not built yet; until it is, a binder adopted in place keeps its `AGENTS.md` where it was, and the tab shows
it as not yet used for filing.

## 4. The reader of new documents follows them

Amends F14 (decisions.md D43): the accepted person's part of `AGENTS.md` is the person's filing guidance for the
reader of intake documents, whether that is Claude (D40) or the on-device clerk. Sprava's section, `CLAUDE.md`,
`DASHBOARD.md` and every document stay data, never instructions.

### 4.1 What the reader may take from them

Only choices about filing this document in this binder:

- **Which folder.** One folder for the document; its attachments go with it, each given a free name there again
  (`freePath`), so the card never collides with a file already in that folder. A folder is taken when it passes
  the document path rules (binder-v0 §4.3: relative, no hidden or reserved segment, not under `intake/`), has at
  most four segments, and is one of these: a folder of the binder's own (below); a path the instructions write
  out whole, matched case-insensitively with nothing but spaces, punctuation other than `/ - _ .`, or the text's
  ends on either side; or one of those two plus one new last segment ("bills" written, `bills/Hydro`
  taken). A document cannot make the reader invent a folder anywhere else.
- **How the file is named.** A file name without its extension. Code keeps the original's extension, makes the
  name safe (`DocumentPaths.safeName`), and adds ` (2)` and so on when it is taken. A name that would make the
  file a key file (`DocumentPaths.isKeyFile`: `credentials …`, `token….json` and the like) when the original was
  not one is refused, and the original name stays: a key file drops out of every model's reach and out of the
  turn history's copies. The document's title on the card stays its own heading, checked as today.
- **What goes on the to-do list.** Which of the document's requests become to-dos, and whether several
  payments or steps are one to-do or several. Every to-do is still checked by code as today: its quote is in
  the document, its title comes from it, its date resolves.

Splitting one file into several documents is not among them: Sprava never changes a file it files.

**The binder's own folders** are the parent folders of the documents in its catalog and the folders on disk up
to two levels down, each passing the rules above, without `intake`, hidden folders or links; at most 200,
the most used first. A new binder's template folders are among them from the start, since creation makes them.

### 4.2 What the reader may not take from them

Anything else, whatever the text says. The instructions never widen what leaves the Mac, never name a path
outside the binder, and never run anything. They cannot change a document's privacy (intake stays private),
the binder's disclosure, another binder, the class rule, or the card's need for the person's OK. Nothing the
reader proposes is applied without the card, and code checks every proposed op exactly as it checks one today.
The text is untrusted only in the sense that a model reads it: the person or a program they run may write it,
the binder's Claude may not, and a model may misread it; the checks above hold whatever the model answers.

### 4.3 Which reader gets them, and what leaves the Mac

- **Claude (D40).** The instructions go in the call's instructions, after Sprava's fixed rules and labelled as
  the person's guidance for this binder, which may set the folder, the file name and which requests are to-dos
  and nothing else; the document stays in the prompt as data. The binder's own folders go with them. The answer
  gains two optional keys, `folder` and `file_name`, empty unless the instructions say where or how. This
  happens only when the binder's connection allows file changes as well as sharing intake, checked when the
  call is prepared and again just before it leaves (`readIntake`'s last check); then Claude may already read
  `AGENTS.md` and every folder, so nothing new leaves the Mac, the person's own addresses in the instructions
  included (this amends D40's "never the person's addresses" for text the person wrote for Claude). A
  connection narrowed in between refuses the call, and the on-device clerk reads the document. A binder
  connected for reading only, with intake shared, sends the document as today, without the instructions or the
  folders, and the on-device clerk makes the folder choice below.
- **The on-device clerk.** One more small call after its reading, only when there are accepted instructions:
  the instructions, the document's file name, title and summary, and a closed list of the binder's own folders
  plus "none", within the clerk's budget (4,096 tokens on most Macs). When they do not fit, the call is skipped
  and the card says "Your instructions are too long for the on-device reader". It chooses a folder only; the
  file name stays the original's. Nothing leaves the Mac.
- **Without either**, code's suggestion stands: the folder most of the binder's documents are in, else
  `documents`.
- **Longer than the bound.** A person's part written outside the app may be longer than 16,000 characters;
  once accepted, the reader is given its first 16,000, and the card says only the first part was read.

The card names the folder as it does today and adds "Folder from your instructions" when the reader chose it.
The reading records which choices came from the instructions (`folder_from: "instructions"`,
`name_from: "instructions"`), never their text. Logs carry only that a choice was made.

### 4.4 Filing rules (D11)

D11's filing rules, drafted from corrections and kept in Sprava's section once accepted, are not built. When
they are, an accepted rule wins where it and the free text disagree: it records a specific correction the
person accepted.

## 5. Templates carry a starting text

A template folder may hold `instructions.md` beside `template.json` and `PROJECT.md`, within the bound of
section 2, part of the template's fingerprint, shown in the New Binder preview. Creation writes it as the
person's part of the new binder's `AGENTS.md` and records it as accepted, since the person chose it in the
preview; a template without one writes no `AGENTS.md`. From then on it is the binder's own, as `PROJECT.md`
is: editing the template changes only binders made later. `PROJECT.md` stays the project guide, a document of
reference material; `instructions.md` holds the few operative rules. The shipped examples get a short one each.
A library seeded before this change keeps its templates as they are; the person may add the file.

An invented example for a household binder:

```
This binder holds the household's running paperwork for one flat.
- Utility bills go in bills, in a folder for each provider, named "<provider> <yyyy-mm>".
- Insurance letters go in insurance; only renewals become to-dos.
- One to-do per bill to pay, never one per reminder about the same bill.
```

## 6. The pieces of work

Each a separate PR in the target the code-structure rules give it.

1. This document, D43 and the F14, D40 and binder-v0 §3.4 amendments (docs).
2. The reader: `BinderInstructions` in `BinderFormat`, parsing the marker lines and reading the person's part
   and the accepted digest within the bounds of section 2.
3. The editor: the writer and Undo in `BinderStore`, the turn history leaving out `AGENTS.md` and `CLAUDE.md`,
   the `save_instructions` and `undo_instructions` commands, the Instructions tab, the conversation's revision
   line. Tier B (the turn history is on the sensitive-path list).
4. The readers take the instructions: the Claude call's guidance and folders, the on-device folder call, and
   their checks, in `Clerk`; the clerk job and `readIntake` pass and check them. Tier B (it parses model output
   into actions).
5. The card follows them: the folder and file name applied to the filing ops in `Capture`, and the card's line.
   Tier B for the same reason.
6. Templates: `instructions.md`, the preview, and creation writing `AGENTS.md`.

Not in this work: F14's own section and `CLAUDE.md`, the import by copy, D11's filing rules, and giving the
instructions to a conversation without file tools.
