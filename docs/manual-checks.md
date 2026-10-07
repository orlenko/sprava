# Manual checks

Checks that need a person at the Mac, because they register background work, show system prompts or need
a real sleep. Each names the spike it settles (architecture 13, item 39; mvp.md section 5). Use invented
binders only, for example copies of `Tests/SpravaCoreTests/Fixtures/*.json` in folders named after their
`meta.name`.

## Increment 2: the runtime

Build with `./scripts/build-app.sh`, copy `build/Sprava.app` to `/Applications`, open it.

1. **Registration (spike c).** Health › Set Up Background Work. Expect "Waiting for your approval" and
   System Settings › Login Items opening; approve. Within 30 seconds Health shows "Runtime running".
   Record whether one approval covers both the runtime and the outside watcher.
2. **Disk image refusal (spike c).** Open Sprava from the build folder mounted as a disk image, or from a
   quarantined copy in Downloads: Set Up must say "Move Sprava to Applications first".
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
10. **Outside watcher.** Turn background work off, then quit the app; restore the runtime's job by hand with
    `launchctl bootout gui/$(id -u)/ca.orlenko.sprava.runtime` while the watcher stays registered: within 15
    minutes one notification says background work stopped. `runtime/watch.json` records each run.
11. **Turn Off.** Health › Turn Off shows "Background work is off (your choice)", never red, and the
    outside watcher stays silent.

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
8. **Files left alone.** `.DS_Store`, `intake/mail/`, `intake/_converted/` and links in `intake/` never get a
   card.

## The weekly fault drill (mvp.md 1.2, M3 part 4)

1. **Freeze.** `kill -STOP <pid>`: within five minutes Health shows red "runtime not answering"; `kill -CONT <pid>`.
2. **Stopped.** Add `{"drill_exit_at_start": true}` to `developer.json` in Sprava's folder and press Restart on
   Health: the runtime exits at every start before its lease, launchd keeps restarting it, and within five
   minutes Health shows red with a rising restart count. Remove the setting afterwards.
