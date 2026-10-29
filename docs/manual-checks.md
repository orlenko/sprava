# Manual checks

Checks that need a person at the Mac, because they register background work, show system prompts or need
a real sleep. Each names the spike it settles (architecture 13, item 39; mvp.md section 5). Use invented
binders only, for example copies of `Tests/SpravaCoreTests/Fixtures/*.json` in folders named after their
`meta.name`.

## Increment 2: the runtime

Run `./scripts/restart-app.sh` to build, install in `/Applications` and open the app (also after updates).
Alternatively, build with `./scripts/build-app.sh`, copy `build/Sprava.app` to `/Applications`, and open it.

### Signing

macOS keeps its record of Sprava's background jobs, launch constraint included, under the app's signer. An ad-hoc
signature changes with every build, so an updated ad-hoc build is refused at launch ("Launch Constraint
Violation") and background work stops. `build-app.sh` therefore signs the app and every helper with one
Apple-issued identity:

- With exactly one Developer ID Application or Apple Development identity in the keychain, it is used.
- Otherwise name one: `SPRAVA_SIGN_IDENTITY=<SHA-1 or name> ./scripts/build-app.sh`; `security find-identity -v -p
  codesigning` lists them. Never commit an identity, a team id or a fingerprint.
- The keychain that holds the identity must be unlocked: being listed by `security find-identity` does not mean
  `codesign` can use it, and a locked one fails with `errSecInternalComponent`.
- `SPRAVA_SIGN_IDENTITY=-` signs ad-hoc, for development only.
- No secure timestamp is requested (`--timestamp=none`): the build stays offline, and nothing is notarized.

On a Mac without an identity, install a bundle built and signed on one that has it, without building:
`./scripts/restart-app.sh --install <path to Sprava.app> --team <team id>`. The team id comes from the person who
signed it, not from the bundle. The script checks the copy where it is and again on the install volume: Sprava's
bundle identifier, a valid deep signature, an Apple-issued identity of that team, and the same team on every
executable. Then it asks Sprava to quit and installs it as an update does.

Both ways install only a team-signed app. Over an ad-hoc one, that is the intended move to stable signing; check
afterwards that Health shows the runtime running and that `runtime/watch.json` gets a new `ran_at` at the next
quarter hour. Over a team-signed one, the team must be the same: a move to ad-hoc or to another team is refused.

1. **Registration (spike c).** Open Sprava with neither job registered. It registers its background work
   without a prompt (decisions.md A19); within a minute Health shows "Runtime running". If macOS wants approval
   instead, Health and the binder page show one line with Open Login Items, and nothing opens by itself.
   Record whether one approval covers both the runtime and the outside watcher.
2. **Disk image refusal (spike c).** Open Sprava from the build folder mounted as a disk image, or from a
   quarantined copy in Downloads: Health must say "Move Sprava to Applications first", with a Restart button.
3. **Duplicate start.** Run `/Applications/Sprava.app/Contents/MacOS/sprava-runtime` in Terminal. It must
   exit at once; Health shows "duplicate starts refused 1".
4. **Freeze drill (M3 part 4).** `kill -STOP <pid>` (the pid is on the Health page). Within 5 minutes Health
   turns red, "Runtime not answering". `kill -CONT <pid>` and it recovers.
5. **Stop drill.** `kill -9 <pid>`. launchd restarts it within about 10 seconds; restarts today goes up.
6. **Restart (spike b).** With the runtime frozen (step 4), press Restart. Record whether `launchctl
   kickstart -k` restarted it, or the unregister and register fallback was needed.
7. **Notifications (spike h).** Allow notifications when asked. Health must show "Notifications allowed".
   Then turn them off in System Settings: within an hour Health shows "Alerts are off" in red. Record
   whether a notification posted by `sprava-runtime` appears under Sprava's name.
8. **Sleep and wake (spike i).** Sleep the Mac for 10 minutes. On wake Health shows "Waking up", then
   green; `runtime/jobs.log` has a `wake` line and a sentinel run right after it.
9. **Daily summary.** With an invented binder that has an item due today, the summary notification at 08:00
   says only counts, such as "1 due today".
10. **Outside watcher.** With background work on, quit the app, then stop the runtime's job by hand with
    `launchctl bootout gui/$(id -u)/ca.orlenko.sprava.runtime` while the watcher stays registered: within 15
    minutes one notification says background work stopped. `runtime/watch.json` records each run.
11. **Start at launch.** Quit the app, stop the runtime's job by hand as in step 10, then open the app: without
    a prompt, Health goes from "Starting background work…" to "Runtime running" within a minute. Health has no
    Turn Off.
12. **Update a running copy.** With background work approved, run `./scripts/restart-app.sh`. The replacement
    app renews its background registration before starting the new runtime. Check Health for a working
    connection and verify that the update did not produce a runtime launch-constraint crash.

## Increment 5: the capture inbox and the intake cards

Use an invented binder adopted in the installed app (never a live one).

1. **A typed note, no binder.** Inbox › type two lines › Save Note with "Not sure". Within a few seconds the
   Inbox shows one card, "Add 2 items from a note", from sprava, with no "unverified source" mark.
   `capture/journal.ndjson` has `ingested` and `unfiled` lines with ids only, never the text.
2. **A typed note into a binder.** Pick the invented binder and save. The card appears on that binder's page
   under "Waiting for your OK"; approve it and the items show in Someday (no deadline).
3. **A note from the terminal.** `sprava note "Invented line"` with no app involved: the card lands in the
   Inbox marked "unverified source", even with `--binder`.
4. **File it from the Inbox.** Choose a binder on an Inbox card and press File: the card moves to that
   binder's page.
5. **The one-minute measure.** In `runtime/jobs.log`, each `capture` line's `slowest_s` stays under 60.
6. **An intake file.** Copy an invented PDF into the binder's `intake/`. Within a minute a card "File … from
   intake" shows the name, date, size and digest. Change the folder field to `letters`, approve: the file is
   now in `letters/`, gone from `intake/`, and Recent changes lists the filing.
7. **A file that changes.** Copy a file into `intake/`, wait for its card, then overwrite the file. Approving
   the old card is refused; within a minute a new card replaces it.
8. **Files left alone.** `.DS_Store`, `intake/_converted/`, links in `intake/`, and a mail monitor's
   `intake/mail/.env` and `state.json` never get a card.

## Increment 7: reading intake

Use an invented binder adopted in the installed app, with invented documents only.

1. **A letter is read.** Copy an invented one-page PDF notice into `intake/`. Within a minute or two its card
   shows "begins: …", the dates and amounts code found, and "How did it reach you?". Within a few more
   minutes (the clerk runs in the background) the card is replaced by "File “<title>” and add N items",
   with the clerk's summary and dated items.
2. **A scan.** Photograph an invented printed page and drop the JPEG in `intake/`: the card says "read from a
   scan" and shows the text's first words.
3. **An email from a mail monitor.** Write `intake/mail/2026-10-01_1_test.md` with front matter (`subject`,
   `from`, `date`) and a body, plus `intake/mail/2026-10-01_1_test attachments/` with an invented PDF. One
   card files both; it does not ask how the message came.
4. **A file that cannot be read.** Drop a file of random bytes named `x.pdf`: a card "Held: … was not read"
   says why.
5. **The channel answer.** Approve a card with "on paper, scanned" picked: the document in `catalog.json` has
   `provenance.obtained.channel: paper`.
6. **A careful reading.** An invented by-law appears under Inbox › "Worth a careful reading". No brain gets
   intake documents until the person can mark one as not private (issue #283): with a brain connected to that
   binder, "May read documents" on and the binder's disclosure at full, ask it to look at the documents
   waiting. `list_readings` lists none, and the by-law stays in the Inbox for the person. With "May read
   documents" off, `read_document` is refused for that reason.
7. **Logs.** `runtime/jobs.log` has `intake carded=… held=…` and `clerk document outcome=… class=…` lines
   with counts only: no names, titles or text.

## Unfinished work

Use invented text in an Inbox note, a binder note, a To-do draft, an item edit, a review-card edit, a filing answer,
the binder's instruction line, the conversation composer and an edited task suggestion.

1. Visit another page and return: every draft is still present.
2. Close the window or quit: **Keep Working** leaves the words in place; closing without saving takes
   a separate explicit choice. Opening an editor without changing it does not prompt.
3. Save an edit or note, then immediately try to quit: the app refuses to close until the runtime acknowledges it.
   A failed save keeps the draft. A successful save no longer needs the unfinished-work prompt.
4. With two windows, quitting checks both. Closing one checks that window, and preserves the other.

## The weekly fault drill (mvp.md 1.2, M3 part 4)

1. **Freeze.** `kill -STOP <pid>`: within five minutes Health shows red "runtime not answering"; `kill -CONT <pid>`.
2. **Stopped.** Add `{"drill_exit_at_start": true}` to `developer.json` in Sprava's folder and press Restart on
   Health: the runtime exits at every start before its lease, launchd keeps restarting it, and within five
   minutes Health shows red with a rising restart count. Remove the setting afterwards.
