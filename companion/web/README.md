# Companion browser protocol

This is the first browser-side component of the companion described in `docs/companion.md`.
It is not yet an installable web app: the pairing/network flow, screens,
offline requests and GitHub Pages publishing still need implementations.

```sh
cd companion/web
npm ci
npm test
npm run build
```

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
remain. Outdated caches may remain stored, so a future screen must check the current index,
epoch and exact view version before opening and showing them. Outcomes/outbox storage and
pairing removal will extend the same database; those flows are not implemented here.

The Node suite uses fake-indexeddb for abort and concurrent-window scenarios. A separate real
Chrome check writes invented fixtures to a disposable profile, restarts Chrome, and decrypts
the persisted cache with its non-extractable keys:

```sh
npm run test:browser
# On another platform, set SPRAVA_TEST_CHROME to the Chrome executable.
```

This check never opens an existing browser profile and removes its temporary profile afterward.
