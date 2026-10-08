# Backup, offload and restore

Status: design draft, 2026-10-07, from the author's decisions A11 and A12 (decisions.md). It replaces the
cmirror-based backup of architecture §9.3 and MVP feature 8. Nothing here is built yet. Examples are
invented.

## 1. The decisions this rests on

- Binders always live in a local folder. A live binder inside a synced folder is not supported, because sync
  clients make conflict copies, evict files, ignore the binder lock and can run two Macs on one binder
  (architecture §2.3).
- Backup is a setting, not a plugin: Sprava keeps an encrypted mirror in iCloud Drive. Sprava is a Mac-only
  tool, and iCloud fits; other destinations can come later.
- The engine is restic, bundled with the app. Old cmirror copies are migrated by decrypting them with cmirror
  and backing them up again.
- No git as a versioning mechanism. Restic snapshots are the versions. A binder that has its own git repo
  keeps it; `.git` is backed up like any other folder.
- A live binder stays entirely local. When the person is done with a binder (a tax year filed, a court case
  closed), they **offload** it: the whole binder leaves the Mac and lives only in the backups. To look
  something up later, they **restore** it with one click, then offload it again.
- Offloading requires a second, independent copy.
- Where the key is kept is the person's choice.

## 2. The states of a binder

| State | On the Mac | In the backups | On the Shelf |
|---|---|---|---|
| Live | everything | snapshots, kept by the retention rule | as today |
| Offloaded | nothing (a small record in Sprava's own state) | a pinned snapshot in the mirror, and a copy in the second backup | under "Offloaded", with its size and the date it left |
| Restored | everything, back where it was | the pinned snapshot, unchanged | live again, marked "restored from offload" |

Restored is an ordinary live binder with one convenience: "Offload again" skips the upload when nothing
changed since the restore (section 6.4).

## 3. The mirror

### 3.1 One repository in iCloud Drive

Sprava keeps one restic repository in a folder of the person's iCloud Drive, by default
`iCloud Drive/Sprava Backup/`. Everything inside is encrypted by restic before it is written, names and
folder structure included. iCloud and anyone who reaches the iCloud account see only the number of files,
their sizes and when they change.

One repository for everything, rather than one per binder: deduplication works across binders, and the
cloud folder reveals nothing about how many binders exist or which is which.

Repository settings: restic's larger pack size (`--pack-size 64`, in MiB) to keep the number of files iCloud
syncs low; JSON output (`--json`) so Sprava parses progress and results instead of reading text.

### 3.2 What is backed up

- Each binder folder, as one snapshot per binder, tagged with the binder's opaque id (never its name, so the
  tags say nothing even to someone who has the key and reads the snapshot list over the person's shoulder).
  Included: everything, `.sprava/` and `intake/` too. Excluded: `.teka.lock`, temporary files (`.*.tmp`).
- Sprava's own state, as its own snapshot: the Shelf, settings, the capture store, unfiled cards, the clerk's
  records, integration settings (`~/Library/Application Support/Sprava`, minus logs and caches).
- Never: the Keychain. Integration passwords and brain tokens are re-entered after a restore onto a new Mac.

### 3.3 When it runs

- A few minutes after a binder stops changing (proposed: 10 minutes after its last op), and once a day.
- One run at a time, as a runtime job with a breaker (architecture 3.4). A run is never killed for taking
  long; it is cancelled only after a stretch with no progress, as architecture 3.4 already requires for
  backups.
- Weekly: `restic check` of the repository's structure. Monthly: `restic check --read-data-subset` over a
  rotating part of the data, so every byte is read back over a year.

### 3.4 Is it really in iCloud?

For each file in the repository, macOS says whether iCloud has uploaded it
(`URLResourceKey.ubiquitousItemIsUploadedKey`). Sprava reads that after every run:

- "Backed up": the snapshot is written and every file it needs is uploaded.
- "Waiting for iCloud": written, not yet uploaded. Shown amber after 24 hours, with the likely cause (iCloud
  Drive off, the account out of space, the Mac offline).
- iCloud Drive's "Optimize Mac Storage" may evict older repository files to save space. That is fine: backups
  only add files, and a restore downloads what it needs (it may then take longer).

### 3.5 Retention

The rule: keep at least N snapshots, for at least X days, whichever keeps more. restic's `forget` does this
with `--keep-last N --keep-within Xd`, which keeps the union. Proposed defaults, per binder:

- the last 30 snapshots, and every snapshot from the last 90 days;
- then one a month for 2 years, and one a year for 10 years;
- an offloaded binder's snapshot is pinned (tag `offloaded`, kept with `--keep-tag`) and never forgotten.

`forget` and `prune` run weekly. Deleting a document for good (binder-v0's expunge) also removes it from
every snapshot with `restic rewrite --exclude`, then prunes.

## 4. The key

restic encrypts the repository with a key derived from a password. Sprava generates a strong one at setup.
The person chooses how it is kept:

- **I keep it.** Sprava shows it once, offers to copy it or save it as a file, and asks the person to store it
  where they keep such things (a password manager). Setup is not finished until the person types it back.
- **Sprava keeps it in iCloud Keychain.** Recovery on a new Mac signed in to the same Apple account needs no
  typing. Less private: anyone who reaches the iCloud account reaches both the backup and its key.

Either way the runtime holds a copy in the local Keychain, this device only, so backups run unattended. restic
receives it through a short-lived file, readable by the person's user only, in Sprava's own folder and deleted when
the command ends; never through an environment variable or a file in a binder.

On a new Mac, a restore starts with "paste your backup key" (or nothing, with iCloud Keychain). The restore
drill (section 8) walks the same path, so the person learns it before they need it.

## 5. The second backup

Offloading removes the copy on the Mac, so the mirror would become the only copy. Before a binder can be
offloaded, a second, independent copy must exist:

- a second restic repository, at a destination the person chooses once in Settings: an external disk, or a
  folder another cloud service syncs;
- filled with `restic copy`, which copies the binder's pinned snapshot from the mirror without re-reading the
  binder;
- checked the same way as the mirror (section 3.3), and, for an external disk, whenever it is connected.

A second repository in the same iCloud account would not count: losing the account would lose both. The
person picks whatever they have: another cloud service's synced folder, or an external disk (decided
2026-10-08).

## 6. Offload and restore

### 6.1 Offload

"Offload this binder" is one button on a binder's page. The steps, each shown with progress:

1. **Ready?** The binder belongs to this Mac, no card is waiting, and nothing is in `intake/` or `outgoing/`.
   If open items remain, the card lists them with a warning: once offloaded, they no longer show on the
   Shelf, in the daily summary or on the hub. The person may close them first, or confirm and offload anyway
   (decided 2026-10-08). The confirmation is recorded in the binder's history before the snapshot.
2. **Snapshot** the binder into the mirror, tagged `offloaded`.
3. **Verify** the snapshot: restore it into a temporary folder on this Mac (`restic restore --verify`) and
   compare every file's SHA-256 with the live binder. This reads the whole binder back once; for gigabytes it
   takes minutes, which is acceptable for a step done once per binder.
4. **Wait for iCloud** until every file the snapshot needs is uploaded (section 3.4).
5. **Copy** the snapshot to the second backup and check it there.
6. **Leave the Mac.** The binder folder moves to the Trash, so nothing is destroyed until the person empties
   it. The hub stops showing the binder, as for a binder at disclosure `none`. The Shelf keeps a small record:
   the name, the opaque id, the snapshot ids in both backups, the size, the date, and a short summary.

### 6.2 Restore

"Restore" on an offloaded binder in the Shelf. One click, then:

1. Pick where: the original folder by default.
2. `restic restore` the pinned snapshot from the mirror, with a progress bar. If iCloud has evicted the files
   it needs, macOS downloads them first; this is where "a few minutes for gigabytes" goes. If the mirror is
   unreachable, the second backup is used instead.
3. Verify every file's SHA-256 against the snapshot, re-open the binder, and show it as live, marked
   "restored from offload". On a different Mac, the binder's owner record names the old Mac, and the takeover
   card of architecture 2.3 appears first.

An interrupted restore can be resumed: restic skips files already restored correctly
(`--overwrite if-changed`).

### 6.3 Peek at one document

On an offloaded binder's record, "Open a document" lists the documents the catalog names, and opens one with
`restic dump` into a temporary folder, then in its default app. It costs seconds to a minute and no full
restore. It is cheap to build on top of 6.2, so it is in the design. If it turns out not to be, a full restore
is the fallback.

### 6.4 Offload again

After a restore, "Offload again" compares the binder with its pinned snapshot. If nothing changed, steps 2 to 5
of 6.1 are skipped and the folder simply goes back to the Trash. If something changed, a new snapshot replaces
the pinned one, and the whole of 6.1 runs.

## 7. In the app

- **Settings › Backup:** on or off; the iCloud folder; the key and how it is kept; the second backup's
  destination; retention, with the defaults of 3.5.
- **Health page:** one line per binder (last backup, "waiting for iCloud", last check), one for the second
  backup, and the date of the last restore drill. Amber after 48 hours without a backup, red after 7 days, as
  architecture 3.4 already proposes.
- **Shelf:** an "Offloaded" section with each offloaded binder, its size, the date it left, and Restore.
- **Doctor:** a binder in a synced folder, a key that no longer opens the repository, a second backup not
  checked for 30 days.

## 8. Restore drill

Offered at setup and monthly on the Health page: restore one binder from the mirror into a temporary folder,
compare it with the live one, and delete the copy. On request, the same drill against the second backup. It
proves the key, the repository and the restore path before they are needed.

## 9. Moving from cmirror

For each binder cmirror backs up today:

1. Sprava takes a first snapshot of the live binder into the new repository. For a live binder this is all
   that is needed; cmirror's copy is no longer the source.
2. For a binder that exists only in cmirror's backup (already offloaded the old way), the person decrypts it
   with cmirror into a temporary folder, Sprava takes a snapshot of that folder tagged `offloaded`, and the
   binder appears under "Offloaded" on the Shelf.
3. When every binder is in the new repository, the person stops cmirror's schedule and may delete its cloud
   folders.

Sprava writes nothing into cmirror's configuration. A binder listed in cmirror's config is also in lifeproj's
registry; offloading it does not change that file, so the doctor reminds the person to archive it in lifeproj
too, or lifeproj will look for a folder that is gone.

## 10. Bundling restic

- A pinned restic release (BSD-2-Clause licence), signed with the app, its SHA-256 checked before each run
  (the rule of architecture 3.5 for any binary Sprava runs).
- Run as a subprocess by the runtime with an explicit environment, `--json`, the key in a short-lived private file, the cache in
  Sprava's own folder, and no shell.
- Upgrading restic is a release of Sprava. The repository format is restic's stable version 2.

## 11. What changes elsewhere

- decisions.md: A6 superseded by A11 and A12.
- architecture §9.1 to §9.3 (age blobs, cmirror calls, the root identity file): replaced by this document.
  §9.2's other rows (MCP tokens, the runtime key, the device id) stay.
- mvp.md feature 8 ("backup status from cmirror", observe only) and spike (l): replaced. The MVP builds backup
  and offload (decided 2026-10-08).

## 12. Decided 2026-10-08

1. The second backup goes to another cloud service's folder or an external disk, whichever the person has.
2. Open items in a binder being offloaded: a warning that lists them; the person may close them or confirm
   and offload anyway.
3. The MVP builds backup and offload.
