# Daily workflow

Two everyday uses first, with no provider and no subscription: a tax year and a condo board. Binders, to-dos and
filed documents work on their own; Claude and email intake, further down, are optional. This covers binders made
in Sprava; bringing in an existing lifeproj binder is not covered here. Sprava sends no email: mail is opened and
sent in your mail client.

## Before you rely on it

- **Health:** the background part answers. No "Starting Sprava's background part…" or Login Items line remains.
- **Saving:** a note or a drop is acknowledged ("Added…"). A note that says the background part did not confirm its
  destination means checking the binder and the Inbox before saving it again.
- **Backup:** set up on the Backup page. Pick a binder and **Run Restore Drill**; once it reports "Restore drill
  passed.", "Last restore drill" shows a date rather than "never".
- **Backup key, in this development build:** the key is kept in the Mac's login Keychain, not synchronized, and iCloud
  Keychain is unavailable, so keep your own copy of the key. If backups stop after an update because Sprava cannot
  read the key, the Backup page shows a **Backup key** section: type the key there and choose **Use This Key**. The
  key must open your existing backup; a wrong one changes nothing. If macOS asks to let Sprava use the key, **Always
  Allow** lets backups read it unattended. See `docs/backup.md` §4.

## Project templates

In **Settings › Project templates › Open Templates Folder**, copy or edit a template for any project.
Each has a `template.json` manifest and a `PROJECT.md` guide. New Binder previews its contents and keeps
a copy with the new binder; later template edits affect future binders. See `docs/project-templates.md`.

## A tax year

Choose the folder for new binders once in **Sprava › Settings › Binders › Choose Folder…**.
New Binder opens Settings first if no folder has been chosen. Changing the location later affects only new binders.

1. **New Binder…**, pick **A tax year**, and set **Tax year** to the year it is for. The name follows the year
   (`tax-2027`) unless you type your own. Check the name and location, then choose **Create Binder**.
2. Its starter checklist arrives under **Waiting for your OK** as one card, every item undated. **Edit** it to
   leave lines out or to give a date of your own, then **Approve**. No item carries a filing deadline; any date on
   it is one you chose, and you can add one later by double-clicking the item and choosing **Add date**.
3. Add slips and receipts by dropping them on **Drop emails or files here**, at the top of the binder's page. Each
   becomes a card within a minute. Check its **Folder** (`slips`, `receipts` or `return`) and **How did it reach
   you?**, change the folder if it is wrong, then **Approve** to file it.

## A condo board

1. **New Binder…**, pick **A condo board**. It has folders for `governing`, `meetings`, `finances`, `maintenance`
   and `correspondence`, and an undated starter checklist to approve as above.
2. Keep the records by dropping minutes, statements, quotes and letters on the binder, and choosing the folder on
   each card before **Approve**.
3. Track action items. Type one per line in **Tell this binder…** (it comes back as a card for your OK), or use
   **Add a to-do** on the To-dos page with this binder chosen. On the binder's page, double-click an item (or
   choose **Edit** from its right-click menu) to set its **Details** and **Priority**; set **Status** to
   **Waiting** to name who it is **Waiting on** and **Add follow-up date**, then **Save**. **Mark Done**, in the
   same menu, closes it.
4. Find a filed document under **Filed documents** with **Find a document by title or path**; **Show in Finder**
   selects its file.
   If it was filed in the wrong folder or under the wrong name, choose **Move / rename…**, type its **New path inside
   this binder** (such as `finances/annual-budget.pdf`) and choose **Move**: the file and its catalog record move
   together. **Undo** under **Recent changes** moves it back, for seven days and while it is still where the move
   put it.

## Optional: Claude and email intake

This pilot uses one isolated Claude conversation per physical binder. Local models are optional; they do
not route or replace this conversation. Claude reads explicitly shared sources and suggests drafts/tasks;
it cannot send email, execute tools or save a task without the person's button click.

1. Build/install Sprava using the normal app scripts. Open Health and wait for the background connection
   to answer before creating or adopting a binder. A running heartbeat alone is not an XPC connection.
2. Install Claude Code. In Brains, select its executable, privately obtain a subscription token
   with `claude setup-token`, paste into the secure field, and select **Verify and Enable Claude**.
   Sprava verifies the Anthropic signature and two harmless fixed turns across a CLI restart before enabling the account. Ordinary Claude updates are accepted; the signature is checked on each launch. Its own local Keychain item keeps the token across background restarts, including development builds. macOS may ask you to authorize Keychain access when enabling a rebuilt app.
3. Open the binder. Expand **Email intake (IMAP)**, which is built into Sprava. Homebrew Python 3 must be
   installed (`brew install python`). Sprava runs a bundled stdlib-only worker, not the older imap-extract
   converter, which can overwrite attachments with duplicate names. Disable any pre-existing watcher for the
   same mailbox to avoid two independent cursors importing twice.
4. **Server.** Type the host and select **Check**. Sprava tries the likely ports in order (SSL/TLS on 993,
   then STARTTLS on 143; for `127.0.0.1` or `localhost`, Proton Mail Bridge's STARTTLS on 1143 first) and
   fills in the one that answers. Pick a security and port yourself to check exactly that. A server that
   accepts only OAuth (Microsoft 365, Google Workspace) is named as such; forward its mail to an account with
   password sign-in. A bridge on this Mac shows its self-signed certificate's SHA-256 fingerprint: trust it
   only if it matches the bridge's certificate. The trust is a pin, for loopback hosts only; a remote server's
   certificate must verify.
   **Account.** Enter the username and password (for a bridge, the password the bridge shows; for an account
   with two-step sign-in, an app password) and select **Sign in**. The password goes to the worker on stdin,
   never in arguments, environment or a file.
   **Folder or label.** Pick one from the account's list. **More filters** adds optional From/Subject
   substrings and an IMAP SEARCH expression such as `UNSEEN SINCE 01-Oct-2026`; these filter on the server,
   and From/Subject are checked again against decoded headers after a private fetch.
5. Choose whether to include existing messages, then **Connect binder** (Touch ID or your login password confirms it). A first sync
   establishes UIDVALIDITY before fetching history. **Check now** or automatic checks within five minutes
   continue bounded batches. Complete Markdown and uniquely numbered attachments appear under `intake/mail/`; a byte-for-byte
   original EML is retained with every message, including parts the bounded parser cannot preview; the server is
   never marked read, deleted from or otherwise changed. Interrupted partial exports are not published;
   already completed messages can be retained with an explicit partial-sync status. A changed
   worker or unsafe state requires reconnecting rather than silently resetting a cursor. A refused sign-in, or
   a bridge that now offers a different certificate, stops automatic checks until you choose **Change…** and
   set it up again. The password is kept in the Mac's Keychain (`org.sprava.imap`, one item per account)
   across background restarts, including development builds. If Keychain access is unavailable, the
   binder asks you to unlock it or enter the password again (**Resume**).
   Mail that cannot be fetched (an account with OAuth-only sign-in, or no IMAP at all) can be dragged from
   Outlook or Mail onto the binder's drop bar, at the top of its page; each message arrives in `intake/` as an
   `.eml`, and attachments or files from Finder arrive as they are. Outlook on the web (also when installed as an
   app) hands over no email when a message is dragged: select its text and drag the selection, or save it as `.eml`
   or PDF and drop the file.
6. In **Conversation with Claude**, choose document/intake sharing and connect the binder. Selected
   information, including private material when shared, goes to Anthropic. Imported mail is reference data,
   never instructions. Ask which bylaw covers pet regulations: the answer can cite current source paths
   and page numbers. Coverage is bounded and not claimed exhaustive; missing evidence must stay visible.
7. Ask for a reply to an intake email. Review its recipient, source citations and facts; copy privately or
   save the draft as text. Sending and reply threading remain in your mail client.
8. Ask for a To-do. Edit its title, details, due date and priority, then click **Add privately to To-dos**.
   This is an ordinary authenticated app write, and the task appears on the global To-dos page. An older
   conversation suggestion creates a *new* task only after a separate confirmation; it is not auto-replayed.

Stop interrupts the active turn; reopening a window resumes an accepted turn without sending it again. Saved app dialogue survives a
restart. Disconnecting stops future sharing but cannot recall information already sent to Anthropic.
Removing/offloading a binder fences its Claude and importer before the app acknowledges that change.
These paths have invented-data fixture coverage; real server credentials, the final installed app launch
and each machine's subscription/account verification are exercised by the person, not unattended tests.
