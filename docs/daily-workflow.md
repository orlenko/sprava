# Claude and IMAP daily workflow

This pilot uses one isolated Claude conversation per physical binder. Local models are optional; they do
not route or replace this conversation. Claude reads explicitly shared sources and suggests drafts/tasks;
it cannot send email, execute tools or save a task without the person's button click.

1. Build/install Sprava using the normal app scripts. Open Health and wait for the background connection
   to answer before creating or adopting a binder. A running heartbeat alone is not an XPC connection.
2. Install Claude Code **2.1.304**. In Brains, select its executable, privately obtain a subscription token
   with `claude setup-token`, paste into the secure field, and select **Verify and Enable Claude**.
   Sprava verifies two harmless fixed turns across a CLI restart before enabling the account. A provisioned build uses its own local Keychain item; the current ad-hoc build can keep the token only in background memory and clearly asks you to re-enable after a background restart.
3. Open the binder. Expand **IMAP intake plugin**. Homebrew Python 3 must be installed
   (`brew install python`). Sprava runs a bundled stdlib-only adapter with the same TECAS .env keys; the
   older imap-extract converter is not used because it can overwrite attachments with duplicate names.
   Disable any pre-existing watcher for the same mailbox to avoid two independent cursors importing twice.
4. Select a private `.env` file outside the binder, readable only by your user (`chmod 600 /path/to/.env`).
   Its required keys are `IMAP_HOST`, `IMAP_USER`, and `IMAP_PASSWORD`. Sprava never copies this file into
   intake or sends it to a model. Select the server mailbox/label and optional From/Subject substring
   filters, plus an optional IMAP SEARCH expression such as `UNSEEN SINCE 01-Oct-2026`. These filter on
   the server; From/Subject are also checked against decoded headers after a private fetch.
   Choose verified TLS on 993 or STARTTLS on 143. Self-signed local bridges are not supported by this pilot.
5. Choose whether to include existing messages, then **Enable IMAP plugin for this binder**. A first sync
   establishes UIDVALIDITY before fetching history. **Sync now** or automatic checks within five minutes
   continue bounded batches. Complete Markdown and uniquely numbered attachments appear under `intake/mail/`; a byte-for-byte
   original EML is retained with every message, including parts the bounded parser cannot preview; the server is
   never marked read, deleted from or otherwise changed. Interrupted partial exports are not published;
   already completed messages can be retained with an explicit partial-sync status. Changed credentials,
   exporter binary or unsafe state require checking/reconnecting rather than silently resetting a cursor. Authentication failures disable automatic checks until the person corrects the private .env and reconnects.
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
