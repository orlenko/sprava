# The companion web app and its relay

Status: design draft, 2026-10-08, from the author's decision P19 (decisions.md). It comes right after the
MVP. Nothing here is built yet. Examples are invented.

## 1. What it is for

The person's phone is an ordinary Android phone. They want to see their to-dos on it, with enough context to
act, and mark them done so they get out of the way. Apple's apps are not an option on Android, and a Google
integration should not be the price of seeing one's own list.

So Sprava gets a companion: a small installable web app (a progressive web app, or PWA) that works on any
phone or browser, backed by a relay that stores only encrypted data. The Mac stays the one place where
binders live and where changes are approved.

The relay is also the foundation for two features deferred so far, sharing a binder with another person and a
second Mac (decisions.md M2). Both need a place to exchange data; the relay is that place, built once.

## 2. Principles

1. **The server never reads anything.** Every binder's data is encrypted on the Mac before it is uploaded and
   decrypted only on a paired device. The relay stores ciphertext and the minimum it needs to route it.
2. **The Mac is the source of truth.** The companion shows what the Mac last published. What the person does
   on the phone travels back as requests, which the Mac applies as the person's own actions, with Undo, exactly
   as check-offs from the hub are applied today (binder-v0 §8.3).
3. **Approval stays on the Mac.** The phone can view, check off, drop, snooze and capture. It never approves
   proposed changes and never edits a binder's settings. A stolen phone or a broken relay can at worst tick
   items, never rewrite a binder (architecture 4.6).
4. **Portable and dumb.** The relay is one small service plus an S3-compatible bucket, with no
   vendor-specific storage, so it runs on any host and can later be offered to other people unchanged.
5. **Per binder, by choice.** Each binder has one switch, "Show on my phone", off by default. Because only the
   person's devices can read it, a shown binder appears in full, not redacted the way the hub's slice is
   (binder-v0 §5.5).

## 3. The parts

```
Mac (Sprava runtime)                     Relay (one small service + a bucket)        Phone (PWA)
  publishes encrypted binder views  ──▶   stores ciphertext, per device mailbox  ◀──  reads, decrypts, shows
  drains encrypted requests         ◀──   check-offs, snoozes, captures          ◀──  writes encrypted requests
  sends push notifications          ──────────────────────────────────────────────▶   shows them
```

- **The runtime's companion job** publishes and drains, with a budget, a breaker and a Health line, like every
  other job (architecture 3.4).
- **The relay**: an HTTP API in front of the bucket. It authenticates devices, stores and lists encrypted
  objects, and deletes them on request. It has no idea what a binder is.
- **The PWA**: static files, served from any static host. It runs offline from its cache and works on Android,
  desktop browsers and anything else.

## 4. Keys and pairing

- **The account key.** Sprava generates a symmetric key for the person's companion data. It lives in the Mac's
  Keychain and on each paired device, nowhere else.
- **Per-binder keys.** Each shown binder's data is encrypted with its own key, wrapped by the account key. This
  is the per-binder key design of architecture §9.2, now put to use: sharing one binder later means giving
  another person that binder's key only, and turning "show on my phone" off rotates it.
- **Pairing a device.** The Mac app shows a QR code holding a one-time pairing secret and the relay's address.
  The phone scans it. The two run a short key exchange through the relay (X25519, so the relay sees only public
  values), confirm a six-digit code on both screens, and the Mac sends the account key to the phone, encrypted.
  The phone keeps it in the browser's storage, encrypted with a key the browser cannot export (WebCrypto
  non-extractable keys).
- **Removing a device.** One click on the Mac revokes its relay token and rotates the account key and every
  binder key; the remaining devices receive the new keys.

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
| Done, Drop | applies `complete` or `drop` as the person's own action, with Undo |
| Snooze, follow up on a date | applies `set_status` or `update_item` (a new `follow_up_at` or `due`) |
| Note | writes a capture event into the inbox (text, P12), with `obtained.channel: note` and the device named; the clerk files it like any other note |
| Share (from another Android app) | a text, a link, a photo or a PDF shared to Sprava becomes a capture, files included (P15) |

Each request names the item by id and carries the view version the person saw. If the item changed since, the
Mac does not guess: it shows a card ("you marked this done on your phone, but it changed since"). Requests are
deleted from the relay once applied. While the Mac is asleep, they wait there, and the phone shows them as
pending.

## 7. Notifications

The PWA subscribes to Web Push, which Android's Chrome supports. The subscription is sent to the Mac, through
the relay, encrypted. The Mac sends notifications itself, through the push service, with the payload
encrypted to the phone's subscription key: the relay never learns what is due or when. Notifications follow
the daily summary's rule (counts and, on the person's choice, titles) and the Nudge bucket.

## 8. The relay

- **API**, all over HTTPS, all bodies opaque: `PUT/GET/DELETE /objects/<id>`, `GET /mailbox/<device>` (a list
  of object ids), `POST /pair/<pairing-id>` for the key exchange, and device registration and revocation.
- **Auth**: one random token per device, stored on the relay only as a hash; requests are signed with it. The
  Mac holds an owner token that can add and revoke devices.
- **Storage**: an S3-compatible bucket, objects named by random ids. No names, no binder titles, no item
  counts beyond what object sizes reveal.
- **Limits**: a size cap per object, a rate limit per device, and an expiry for unread mailbox objects.
- **Deployment**: one container image and a bucket. The first deployment is the author's own (DigitalOcean App
  Platform or a small droplet, with Spaces for storage; the static PWA on Vercel or the same host).
- **What a breach of the relay reveals**: how many objects exist, their sizes, and when devices talk. Nothing
  else.

## 9. The PWA

- Screens: a cross-binder Today (Overdue, Today, Nudge), each shown binder's Now page, an item's detail with its
  context (notes, waiting on, follow up, the binder's description), and a note field.
- Actions: Done, Drop, Snooze, Follow up on…, Note, and the Android share target.
- Offline: the last views are cached, decrypted only in memory; actions made offline are queued and sent later.
- No third-party scripts, no analytics, and a strict content security policy, because the page holds keys.

## 10. The hub

The companion replaces what osavul's hub does for the person: a cross-binder list on the phone. Until the
person retires the hub, the hub lane keeps working unchanged for lifeproj's binders. Sprava does not extend
the Google Tasks mirror, which belongs to the hub.

## 11. Order of work

1. The relay (API, auth, bucket) and its deployment, with a test suite that runs it locally.
2. Pairing and keys on the Mac and in the PWA.
3. Publishing views, and the PWA's read-only screens.
4. Requests back: Done, Drop, Snooze, Note; the Mac's drain and its cards for conflicts.
5. Notifications.
6. The Android share target, with files.

## 12. Questions for the author

1. Notifications: counts only, or titles too? Titles are end-to-end encrypted, but show on a lock screen.
2. Should the phone see document files (open a PDF from a binder), or only titles and dates in v1?
3. Is a separate repository right for the relay and the PWA (a TypeScript or Go service and a static app), or
   should they live in this repository under `companion/`?
