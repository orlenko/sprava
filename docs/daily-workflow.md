# Claude and IMAP daily workflow

This pilot uses one isolated Claude conversation per physical binder. Local models are optional; they do
not route or replace this conversation. Claude reads explicitly shared sources and suggests drafts/tasks;
it cannot send email, execute tools or save a task without the person's button click.

1. Build/install Sprava using the normal app scripts. Open Health and wait for the background connection
   to answer before creating or adopting a binder. A running heartbeat alone is not an XPC connection.
2. Install Claude Code **2.1.304**. In Brains, select its executable, privately obtain a subscription token
   with `claude setup-token`, paste into the secure field, and select **Verify and Enable Claude**.
   Sprava verifies two harmless fixed turns across a CLI restart before enabling the account. A provisioned build uses its own local Keychain item; the current ad-hoc build can keep the token only in background memory and clearly asks you to re-enable after a background restart.
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
   set it up again. The password is kept in the Keychain (`org.sprava.imap`, one item per account); the
   current ad-hoc build cannot write the Keychain, so it keeps the password in background memory and the
   binder asks for it again (**Resume**) after a background restart.
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

Stop interrupts the active turn; closing a window only stops polling. Saved app dialogue survives a
restart. Disconnecting stops future sharing but cannot recall information already sent to Anthropic.
Removing/offloading a binder fences its Claude and importer before the app acknowledges that change.
These paths have invented-data fixture coverage; real server credentials, the final installed app launch
and each machine's subscription/account verification are exercised by the person, not unattended tests.
