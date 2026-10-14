# Companion browser protocol

This is the first browser-side component of the companion described in `docs/companion.md`.
It is not yet an installable web app: pairing, IndexedDB state, payload validation, screens,
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
defined fields. View/outcome schemas and freshness admission are still separate work.

These results remain provisional. The caller must commit the high-water marks and encrypted
cache durably as section 10.2 requires before showing anything, pin the signing key only when
a pairing is installed, and preserve that pin during rotations. Decrypted data stays in memory.
