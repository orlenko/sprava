# Companion web app

The local PWA build has pairing, shared binder browsing, item controls, an inbox-note editor and pending
action status. IndexedDB holds encrypted caches, immutable queued requests and
non-extractable keys. A service worker caches only this build's static shell, so admitted
data can be opened offline. Every binder string is rendered as text.

Mac companion integration and release
publishing are still pending. This build does not yet provide phone-to-Mac use.

```sh
cd companion/web
npm ci
npm test
npm run build
npm run dev
```

`npm run dev` builds and serves `dist/` at `http://localhost:5173`; set `SPRAVA_WEB_PORT`
for a different port. The preview binds only to localhost. Serve the same static output
over HTTPS at an origin dedicated to this app for a device test; no deployment is performed
by the build or preview scripts. The version and commit appear at the foot of the app.

The note editor stays mounted through refreshes and saves an encrypted draft on each input.
Startup recovers a single unsent draft or offers a chooser for multiple saved drafts. A failed
draft write says to keep the window open and copy the note. The editor clears only after the
request and matching draft deletion commit together for its original pairing, and retains drafts on validation/storage failure.
Pending pages contain metadata rather than ciphertext or note text. "Sent" means received
by the relay; a signed outcome from the Mac resolves the entry.

Item controls follow the published status: Done/Drop for active items, Arrived/Follow up
for waiting or blocked items, and Postpone for open items with a deadline. Requests capture
the exact numeric/string item id, published view version and pairing generation; items
remain in the view until the Mac publishes an update. The date editor stays mounted across
refreshes and saves a separate encrypted draft, recovered as an item action rather than
an inbox note. Save atomically queues the request and retires its draft; Cancel retires the
draft without sending. A changed pairing cannot receive an old editor's action.

The build emits browser ES modules under `dist/`, with no Node imports, third-party runtime
dependencies or secrets. `src/sealed.ts` imports non-extractable AES-256-GCM keys, seals device
messages with random nonces, and authenticates the owner's Ed25519 signature before opening
published objects. Names and epochs come from the requested object and local state, never
from the envelope. Content and cryptography errors are not included in returned errors.

The relay and browser share the strict JSON reader in `companion/shared/json.ts`; both run
the committed wire vectors. The first encryption vector was generated with Node's separate
crypto API and is reproduced by WebCrypto tests.

`src/pairing-keys.ts` implements the device's X25519 and HKDF-SHA256 agreement, produces
non-extractable wrap/device keys and the six-digit confirmation code, and refuses low-order
keys. Derived keys remain provisional: the pairing handshake and user confirmation must
complete before a caller installs them. Shared derivation vectors are public invented inputs.

The codec validates the envelope and JSON. `src/owner-payloads.ts` adds recipient/epoch,
key, revision, timestamp and binder-entry validation for pairing deliveries, device-key
rotations and indexes. It imports secret keys as non-extractable CryptoKeys and returns only
defined fields. `src/view-payloads.ts` checks signed view schemas, including typed item ids,
cross-array uniqueness, bucket membership, dates and per-item versions. The shared public
payload-validation corpus covers these owner payloads. `src/outcomes-payloads.ts` authenticates
device outcomes, validates their recipients/revisions/entries and checks ASCII-space padding
against the original plaintext byte length. Outcomes remain provisional until their revision
and matching outbox changes commit together.

Decoder results remain provisional. `src/browser-store.ts` provides pairing reservations,
conditional installation and acknowledgement, and atomic admission of indexes, views and key
rotations. Every state write uses strict IndexedDB durability and resolves only after completion.
Validation runs outside transactions; commit rechecks the pairing, epoch and relevant index/version
floors. The cache stores sealed bytes and non-extractable keys, never decrypted binder text. Views
are separate records: accepting one rewrites only that view and its admission metadata,
so a refresh does not clone and rewrite the entire cache. `readView` checks the current
index, epoch and exact version in one read transaction before returning a cache.
Removed binders lose their cached views and keys in the index transaction; their version floors
remain. Outdated caches may remain stored, and display reads check the current index,
epoch and exact view version before opening and showing them. Outcomes admission and send-attempt transitions use that same database. The HTTP client below supplies network transport; pairing removal is not implemented
here.

The Node suite uses fake-indexeddb for abort and concurrent-window scenarios. A separate real
Chrome check writes invented fixtures to a disposable profile, restarts Chrome, and decrypts
the persisted cache with its non-extractable keys:

```sh
npm run test:browser
# On another platform, set SPRAVA_TEST_CHROME to the Chrome executable.
```

This check never opens an existing browser profile and removes its temporary profile afterward.
It also exercises the actual screens: inert markup-like binder text, distinct numeric/string
ids, draft retention through browser termination, encrypted note sending, offline shell/cache reload and frame refusal.

`src/device-payloads.ts` validates actions before numbering: the request-type field table,
typed item ids, positive seen versions, valid dates, note character/encoded-byte limits,
allowed controls and Unicode scalar validity. It seals requests with the smallest whole-KiB
padding, fixed-size private pairing hellos and instance-bound self-revocations. A caller
must still durably enqueue the sealed request before sending and retain the editor draft
when validation or storage fails; the outbox and HTTP components below implement those steps.

`src/outbox.ts` adds durable numbering/enqueue: validate first, seal outside IndexedDB,
then atomically advance `next_seq` and store the immutable ciphertext. Concurrent windows
retry with a new number and request id. A changed pairing produces an entry of the original
generation marked "not sent", with no ciphertext; it never encrypts an old action for a new
pairing. Pending-entry display reads bounded metadata pages rather than the whole ciphertext
queue. The attempt/outcomes component below handles sending state and expiry; pairing removal
remains separate work.

`src/outbox-state.ts` commits attempted before exposing send bytes, saves retry backoff
and deadlines, conditionally records replies, suspends sending on auth refusal while
retaining keys, and atomically admits signed outcomes with their revision and matching
entry transitions. Late replies cannot overwrite resolved actions. Expiry runs in bounded
pages and keeps unconfirmed actions visible. `src/sender.ts` holds the shared Web Lock
for one attempt through result persistence, aborts after 30 seconds, and leaves all
backoff waiting outside the lock. Its injectable transport must honor AbortSignal; the app orchestrates refresh, pairing and screen updates.

`src/relay-client.ts` supplies device-only HTTP calls: canonical relay/device scoping,
strict bounded JSON responses, streamed object limits, abortable 30-second calls, no
redirects, cookies or referrers, and no remote error text in returned errors. The real
Chrome check now sends encrypted bytes through this client to an isolated invented API,
restarts, fetches an independently signed outcome, and atomically resolves the action.
The test server is a fixture, not a deployed relay or a Mac companion implementation.

`src/pairing-flow.ts` reserves a generation, creates one fixed X25519 transcript, retries
only explicit 503 joins with identical bytes, shows the confirmation code after a valid
join, polls the wrapped delivery and conditionally installs the pairing. Its first ack
runs after durable installation; startup/refresh can retry the persisted pending flag.
Cancellation retires only that flow's reservation. The original flow cannot acknowledge
a replacement generation, and lost joins require a new link. The complete flow is
bounded to ten minutes; each HTTP call also has its own deadline. The app calls these helpers during pairing and scheduled refresh.

`src/refresh.ts` searches keys before indexes, reconciles epoch-independent outcomes, and
fetches only the selected binder's exact view. Each prefix has a five-candidate budget,
including the index re-list after a missing view; the whole refresh has a 30-second network
deadline. All admissions belong to the pairing generation that started the request.
Invalid candidates and network failures leave admitted offline caches intact; storage
failures remain visible to the caller. `src/display-cache.ts` opens admitted sealed data
in memory and rechecks pairing/index prerequisites after decryption. It never persists
decrypted names or content. The app calls it at startup, on visibility/network changes and during scheduled refresh.

`src/drafts.ts` saves editor drafts encrypted under the non-extractable device key with
fresh nonces and a local, generation/editor-bound context. Each window has its own editor
id and increasing revisions; a late encryption cannot overwrite newer text. Bounded
recovery pages decrypt only in memory. Draft input preserves UTF-16 code units, including
temporarily incomplete input, before the stricter outbound-note validation. Enqueue can
delete matching draft revisions in the same strict transaction as numbering and ciphertext
storage, so a restart cannot find a leftover draft from a completed enqueue. A stale screen
generation cannot number an action for a replacement pairing.

Pairing removal is an explicit screen action. It tries an encrypted, instance-bound relay
revocation for at most 30 seconds, asks other windows to stop this generation's attempts,
then takes the send lock and strictly deletes its keys and caches together with action
transitions. Queued actions become "not sent"; attempted/sent actions remain "unresolved".
The screen shows counts and asks for removal on the Mac too when revocation was not
confirmed. A changed generation is untouched, and an unsent note remains in the editor
for copying after removal.
