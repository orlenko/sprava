# The companion web app and its relay

Status: decided 2026-10-08 (decisions.md P19). The wire protocol is `docs/spec/companion-v0.md`. Examples are
invented.

## 1. What it is for

The person's phone is an ordinary Android phone. They want to see their to-dos on it, with enough context to
act, and mark them done so they get out of the way. Apple's apps are not an option on Android, and a Google
integration should not be the price of seeing one's own list.

So Sprava gets a companion: a small installable web app (a progressive web app, or PWA) that works on any
phone or browser, backed by a relay that stores only encrypted data. The web app is published from this
repository to GitHub Pages; the relay is an API only. The Mac stays the one place where binders live and where
changes are approved.

The relay is also the foundation for two features deferred so far, sharing a binder with another person and a
second Mac (decisions.md M2). Both need a place to exchange data; the relay is that place, built once.

## 2. Principles

1. **The server never reads anything.** Every binder's data is encrypted on the Mac before it is uploaded and
   decrypted only on a paired device. The relay stores ciphertext and the minimum it needs to route it.
   Encryption protects against the relay's host, the bucket, their logs and their backups. What the relay can
   still observe (object kinds and sizes, timing, which device reads what, and often which binder a request
   was about) is listed in companion-v0 §11.
2. **The code that holds the keys does not come from the relay.** Whoever controls the code a browser runs can
   read what that browser decrypts. So the relay never serves the web app. The web app is built from this
   public repository's release by GitHub Actions and published to GitHub Pages, an origin the relay does not
   control, and its code is trusted as published there. If that is ever not enough, a native app is the path;
   the protocol stays the same.
3. **The Mac is the source of truth.** The companion shows what the Mac last published. What the person does
   on the phone travels back as requests, which the Mac applies as the person's own actions, with Undo, exactly
   as check-offs from the hub are applied today (binder-v0 §8.3).
4. **Approval stays on the Mac.** The phone can view, check off, drop, follow up, postpone and capture. It never
   approves proposed changes and never edits a binder's settings. Until it is removed, a stolen unlocked phone can
   do what its owner could do from it: close or drop items, move follow-up and due dates, and add notes, each
   applied as an ordinary change with Undo on the Mac; nothing more (architecture 4.6). A broken relay can do
   none of that: requests are sealed per device.
5. **Portable and dumb.** The relay is one small service plus an S3-compatible bucket, with no
   vendor-specific storage, so it runs on any host and can later be offered to other people unchanged.
6. **Per binder, by choice.** Each binder has one switch, "Show on my phone", off by default. Because only the
   person's devices can read it, a shown binder appears in full, not redacted the way the hub's slice is
   (binder-v0 §5.5).
7. **Anyone can run their own.** Sprava is open source. Nothing in the code names a particular relay, domain or
   bucket: each person deploys their own relay from the same code, and their Mac learns its address when they
   set it up. The web app learns it from the pairing QR code, so one published web app serves every relay. One
   relay serves one person's Mac and devices; it is claimed once, with a generated setup code only its deployer
   knows. Two people's relays share nothing.

## 3. The parts

```
Mac (Sprava runtime)                     Relay (one small API + a bucket)            Phone (PWA)
  publishes encrypted binder views  ──▶   stores ciphertext, per device mailbox  ◀──  reads, decrypts, shows
  drains encrypted requests         ◀──   check-offs, follow-ups, captures       ◀──  writes encrypted requests
  sends push notifications          ──────────────────────────────────────────────▶   shows them

                                         GitHub Pages (built from this repository)
                                           serves the PWA's files                ──▶  loads and caches them
```

- **The runtime's companion job** publishes and drains, with a budget, a breaker and a Health line, like every
  other job (architecture 3.4).
- **The relay**: an HTTP API in front of the bucket, and nothing else: it serves no web pages. It authenticates
  devices, stores and lists encrypted objects, and deletes them on request. It has no idea what a binder is.
  It accepts browser calls only from the web app's origin (`SPRAVA_WEB_ORIGIN`).
- **The PWA**: static files, built from a release of this repository by GitHub Actions and published to GitHub
  Pages, at an origin of its own that the relay does not control. Anyone can host the same build elsewhere
  instead. It learns its relay's address from the pairing QR code; v0 pairs one browser profile with one
  relay. It runs offline from its cache and works on Android, desktop browsers and anything else.

## 4. Keys and pairing

- **The account key.** Sprava generates a symmetric key for the person's companion data. It lives in the Mac's
  Keychain and on each paired device, nowhere else.
- **Per-binder keys.** Each shown binder's data is encrypted with its own key, wrapped by the account key. This
  is the per-binder key design of architecture §9.2, now put to use: sharing one binder later means giving
  another person that binder's key only, and turning "show on my phone" off rotates it.
- **Pairing a device.** The Mac app shows a QR code holding a one-time pairing secret, the relay's address and
  the Mac's public key. The phone scans it. The two run a short key exchange through the relay (X25519, so the
  relay sees only public values), confirm a six-digit code on both screens, and the Mac sends the account key
  to the phone, encrypted. The phone's name travels encrypted to the Mac and nowhere else. The phone keeps its
  keys in the browser's storage as keys the browser cannot export (WebCrypto non-extractable keys).
- **A key per device.** Pairing also gives the Mac and that phone a key only the two of them share. The phone
  seals its requests with it, so no phone can act in another's name, and the Mac uses it to deliver new keys.
- **The owner's signature.** The Mac has a signing key (Ed25519) that never leaves it. Each phone receives its
  public half at pairing and keeps it. The Mac signs everything it publishes, and a phone shows nothing
  without a valid signature, so neither the relay nor a removed phone can forge a list, a version number or a
  key.
- **Removing a device.** One click on the Mac revokes its relay token, forgets its device key, and rotates the
  account key and every binder key. Each remaining device receives the new keys sealed with its own device
  key, so the removed one never can. Keys carry an epoch, and a device never goes back to an older one.

## 5. What is published

For each shown binder, the Mac publishes one encrypted **view**: the open items with every field the phone
shows (title, status, due, waiting on, follow up, tags, contexts, notes), the eight buckets as computed for
today (binder-v0 §5.2), recently closed items, the binder's name and description, and the documents' titles
and dates. Document files themselves are not published in v1.

A view is replaced whole when the binder changes, and at least once a day so its buckets stay current. It is
small: a binder with 100 items is tens of kilobytes. An index object lists the shown binders and their views'
versions, so the phone fetches only what changed.

## 6. What the phone sends back

Requests, each a small encrypted object in the Mac's mailbox on the relay:

| Request | What the Mac does |
|---|---|
| Done, Drop (an open, waiting or blocked item) | applies `complete` or `drop` as the person's own action, with Undo |
| Follow up on a date (a waiting or blocked item) | sets `follow_up_at` to that date and nothing else: they chased, and are waiting again |
| Arrived (a waiting or blocked item) | `set_status` to `open`: the waiting fields go, `due` stays |
| Postpone to a date (an open item with a deadline) | sets `due` to that date and nothing else |
| Note | writes a capture event into the inbox (text, P12) as an in-app note would (capture-event-v0 §8.1), with the device named in Sprava's extension; the clerk files it like any other note |
| Share (from another Android app) | a text, a link, a photo or a PDF shared to Sprava becomes a capture, files included (P15) |

Follow up, Arrived and Done are the three answers of a Nudge card (binder-v0 §5.3). A request on an item whose
status does not allow it (Postpone on a waiting item, say) becomes a card on the Mac, never a guess. Each request
names the item by id and carries the view version the person saw. If the item changed since, the Mac does not
guess either: it shows a card ("you marked this done on your phone, but it changed since"). The Mac makes every
check from its own records: the device is still paired, the binder is still shown, the item is in it. Each request
carries a sequence number, so a replayed or duplicated request is refused. A request the Mac cannot open or that
breaks the rules is refused and noted in the journal by id only. Requests are deleted from the relay once decided.
While the Mac is asleep, they wait there, and the phone shows them as pending. The Mac publishes each phone's
outcomes (applied, a card, or refused), signed and readable only by that phone, so the phone knows what became of
every action; one that never gets an answer stays visibly unresolved.

## 7. Notifications

The PWA subscribes to Web Push, which Android's Chrome supports. The subscription is sent to the Mac, through
the relay, encrypted. The Mac sends notifications itself, through the push service, with the payload
encrypted to the phone's subscription key: the relay never learns what is due or when. Notifications follow
the daily summary's rule (counts and, on the person's choice, titles) and the Nudge bucket.

## 8. The relay

- **API only**, all over HTTPS, all payloads opaque: objects the Mac publishes (an index, one view per shown
  binder, one keys object per device), a mailbox of requests per device, pairings, and device revocation
  (companion-v0 §7). It serves no web pages. Browsers may call it only from the web app's origin.
- **Auth**: one random bearer token per device, stored on the relay only as a hash. A device that has joined a
  pairing can do nothing but fetch its key until the Mac confirms it. The Mac holds an owner token that can add
  and revoke devices.
- **Storage**: an S3-compatible bucket, objects named by random ids. No binder
  names, no titles, no device names.
- **Limits**: a size cap per object, a rate limit per device, and an expiry for unread requests. The Mac does
  not rely on them: it bounds how many requests and bytes it takes per run, and serves devices in turn, so a
  device whose requests are stuck never holds up another's.
- **Deployment**: one service, run as a single instance, and one bucket, configured entirely by environment
  variables (section 13). The repository carries a template for DigitalOcean App Platform with placeholders,
  never anyone's real values; a deployer keeps theirs in the host's settings.
- **What a breach of the relay reveals**: what kinds of objects exist and how many, their sizes, when they
  change, which device reads what and when, and how many requests each device sends (companion-v0 §11). Not a
  binder name, a title, a device name or any content. Requests are padded to whole kilobytes, so a check-off
  and a short note look alike. v0 does not hide which binder's view the Mac rewrites after a request, so the
  relay can often tell which binder a request was about; rewriting every view on a fixed schedule would hide
  that, and is a possible later option.

## 9. The PWA

- Screens: a cross-binder Today (Overdue, Today, Nudge), each shown binder's Now page, an item's detail with its
  context (notes, waiting on, follow up, the binder's description), and a note field.
- Actions: Done, Drop, Follow up on…, Arrived, Postpone to…, Note, and the Android share target.
- Offline: the last views are cached, decrypted only in memory; actions made offline are queued and sent later.
- Freshness: the phone says how old its data is, and refuses any index or view older than one it already
  accepted, or not signed by the Mac, so a relay cannot quietly bring back a finished task.
- Several tabs: windows of one browser share one pairing; one of them sends at a time (a Web Lock), and every
  counter it stores only moves forward.
- Hosting: built from a release of this repository by GitHub Actions and published to GitHub Pages, never
  served by the relay. Its origin serves nothing else, because every page on one origin can use the keys
  stored there: a custom domain, or a `github.io` address with no other site. The app shows the release and
  commit it was built from.
- Trust: the published code is trusted, because it holds the keys; encryption protects against everything on
  the relay's side. A native app is the path if that is ever not enough.
- No third-party scripts, no analytics, and a strict content security policy, because the page holds keys.

## 10. The hub

The companion replaces what osavul's hub does for the person: a cross-binder list on the phone. Until the
person retires the hub, the hub lane keeps working unchanged for lifeproj's binders. Sprava does not extend
the Google Tasks mirror, which belongs to the hub.

## 11. Order of work

1. The relay (API, auth, bucket) and its deployment, with a test suite that runs it locally; the web app's
   build and its publishing to GitHub Pages.
2. Pairing and keys on the Mac and in the PWA.
3. Publishing views, and the PWA's read-only screens.
4. Requests back: Done, Drop, Follow up, Arrived, Postpone, Note; the Mac's drain, its cards for conflicts, and
   the outcomes the phone reads back.
5. Notifications.
6. The Android share target, with files.

## 12. Decisions (2026-10-08)

1. Notifications show counts only in v1 ("3 due today"); titles are a later setting.
2. The phone sees document titles and dates, not files, in v1.
3. The relay and the web app live in this repository under `companion/` (`relay/`, `web/`), in TypeScript,
   with the protocol in `docs/spec/companion-v0.md`, so one change can update both sides and their tests.

## 13. Running your own

Everything a person needs to run Sprava's companion for themselves is a relay and a bucket:

1. An S3-compatible bucket (for example DigitalOcean Spaces, Amazon S3, Cloudflare R2 or MinIO), private, and
   an access key limited to it.
2. A host for one container under HTTPS, run as a single instance (DigitalOcean App Platform, Fly, a small
   server behind Caddy).
3. The environment variables of `docs/spec/companion-v0.md` §13: an instance id generated with
   `openssl rand -hex 16`, a setup code generated with `openssl rand -base64 32`, and `SPRAVA_WEB_ORIGIN`, the
   web app's origin. Starting over means a new instance id and a new setup code; the old data is left behind
   under the old id.
4. In the Mac app, Settings › Phone: the relay's address and the setup code, and the web app's address if it is
   not the shared build. The Mac claims the relay, and the relay ignores the code from then on. Devices are
   paired from the Mac with a QR code.

The web app needs no hosting of their own: the shared GitHub Pages build works with any relay, which it learns
from the QR code. A person who prefers to trust their own host instead builds the same release and serves it
at an origin of their own, and sets `SPRAVA_WEB_ORIGIN` to it.

For development and tests, the relay runs locally with files on disk instead of a bucket, and the Mac and a
browser on the same machine pair with it.
