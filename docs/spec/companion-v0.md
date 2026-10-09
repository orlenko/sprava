# companion-v0: the relay protocol

Status: draft for implementation, 2026-10-08. The design and its reasons are in `docs/companion.md`; this
document is the contract the three implementations share: the Mac (Swift, CryptoKit), the relay (TypeScript)
and the web app (TypeScript, WebCrypto). Where they disagree, this document wins and the others are fixed.
Examples are invented.

## 1. Roles

- **The owner**: one Mac running Sprava. It claims the relay once (section 6), pairs and revokes devices,
  publishes encrypted objects, and drains the requests devices send.
- **A device**: a browser profile running the web app, usually on a phone. It reads what the owner published
  and sends requests.
- **The relay**: an HTTP API that stores opaque bytes under names and checks tokens. It never holds a key that
  decrypts anything, never parses a payload, and serves no web pages.
- **The web app**: static files built from this repository and served from an origin of their own, never by
  the relay (section 10.1).

One relay serves exactly one owner. A second person runs a second relay (docs/companion.md §13). A browser
profile is paired with at most one relay at a time (section 10.2).

**Scope.** v0 covers pairing, published views and the requests of section 8.6. Notifications (Web Push
subscriptions) and the Android share target with files are later steps (docs/companion.md §11, steps 5 and 6)
and get their own payloads in a later version. "binder-v0" is the binder format, `docs/spec/binder-v0.md`
(named `docs/spec/teka-v0.md` before its rename).

## 2. Trust model

- **What encryption protects against.** Everything the owner publishes and every request a device sends is
  encrypted end to end. The relay's host, the bucket's provider, the relay's logs and backups, and anyone who
  obtains a copy of them see only what section 11 lists.
- **What is trusted.** The Mac. The QR code on its screen, which carries the relay's address and the owner's
  public key to the device. And the web app's code: it holds the keys, so whoever controls the code a browser
  runs at the web app's origin can read the data. That code is trusted as published from this public
  repository's release build (section 10.1). The relay does not serve it and cannot change it.
- **What is not trusted.** The relay, for confidentiality and integrity. It cannot read or forge what the
  owner publishes, which the owner signs (section 4.5), nor a device's requests, which are sealed per device.
  It can withhold, delay, reorder, replay or delete objects and requests, and send oversized or malformed
  responses. The protocol refuses replays, rollbacks and oversized responses (sections 3.2, 9 and 10.3) but
  cannot force the relay to deliver anything; the web app shows how old its data is.
- **If that is not enough.** A native app, whose code does not come from a web origin, is the path. The
  protocol does not change for it.

## 3. Encodings

- **b64**: base64url without padding (RFC 4648 §5). Readers reject padding, characters outside the alphabet,
  and non-canonical encodings (unused trailing bits that are not zero).
- **Ids**: 16 random bytes in b64 (22 characters), from a cryptographic random source. Device, pairing,
  binder and request ids have this form; the relay and the Mac refuse any other. Item ids are the binder's own
  (section 8.5).
- **Tokens**: 32 random bytes in b64 (43 characters). A token's hash is SHA-256 over the 43 ASCII bytes of the
  token as written (not over the 32 bytes it decodes to), in lowercase hex: 64 characters of `0-9a-f`. The
  relay stores only hashes and compares them in constant time. A bearer value that is not 43 canonical b64
  characters is `401`, without hashing. The owner sends its token's hash when it claims (section 6); a value
  that is not 64 lowercase hex characters is `400`.
- **Times**: RFC 3339 in UTC, exactly `YYYY-MM-DDTHH:MM:SSZ`. **Dates**: `YYYY-MM-DD`, a valid Gregorian date.
- **Unsigned integers**: counters, epochs, revisions, versions, sequence numbers and sizes. A JSON number with
  digits only (no sign, fraction, exponent or leading zero), from 0 to 2^53 − 1.
- **Item ids that are numbers**: signed safe integers, as binder-v0 allows. Digits with an optional leading
  `-` (no fraction, exponent or leading zero), from −(2^53 − 1) to 2^53 − 1, and never `0` or `-0`.
- Readers reject any other number where one of these is expected, `1.0` and `1e2` included.
- **Strings**: two strings are equal when their sequences of Unicode scalar values are equal; nothing is
  normalized, and ids are compared this way. Lengths are counted in Unicode scalar values (Swift
  `unicodeScalars.count`, JavaScript `[...s].length` once section 3.1 has ruled out lone surrogates).

### 3.1 Strict JSON

Every JSON text in this protocol (request and response bodies, sealed objects, payloads) is UTF-8 and is read
strictly. A reader rejects the whole text when:

1. it is longer than its limit (section 3.2), checked before parsing;
2. it is not well-formed UTF-8, or starts with a byte order mark;
3. it nests arrays and objects deeper than 16 levels;
4. an object has two members with the same name, compared after escapes are decoded (`"a"` and `"\u0061"`
   are the same name);
5. a string holds an unpaired surrogate, such as the escape `"\ud800"` alone;
6. a number where an integer is expected breaks section 3's rules.

**Writing.** Writers emit compact JSON: no whitespace outside strings. Inside strings they escape `"` as
`\"`, `\` as `\\`, the characters U+0008, U+0009, U+000A, U+000C and U+000D as `\b`, `\t`, `\n`, `\f` and `\r`,
and every other character below U+0020 as `\u00xx` with lowercase hex. Every other character, `/` and
non-ASCII included, is written as its UTF-8 bytes. This is what `JSON.stringify` produces for a well-formed
string; Swift's `JSONEncoder` needs `.withoutEscapingSlashes` and must pass the `serialization` vectors of
section 14, or the implementation writes its own serializer. The **encoded size** of a string is the number
of bytes between its quotes in this form. Readers accept any valid JSON escape.

Writers never produce any of the rejected forms above. `JSON.parse` keeps the last of two duplicate members and
accepts lone surrogates, and Foundation's parser is not specified on either, so each implementation reads with a
strict parser of its own that passes the rejection vectors of section 14. Members a reader does not know are
ignored after these checks; nothing keeps them.

### 3.2 Receive limits

The Mac and the web app read every response as a stream, count its bytes as they arrive, and abort as soon as
it exceeds its limit, before holding it whole or parsing it. A `Content-Length` above the limit is refused
without reading. An over-limit response is invalid.

| Response | Limit |
|---|---|
| `GET /v0/objects/index/{r}`, `GET /v0/objects/views/{id}/{version}` | 1 MiB (1,048,576 bytes) |
| `GET /v0/objects/devices/{D}/outcomes/{r}` | 512 KiB |
| `GET /v0/objects/devices/{D}/keys/{e}`, `GET /v0/pairings/{P}/key` | 4 KiB |
| `GET /v0/objects?prefix=...` (one page) | 16 KiB |
| `GET /v0/pairings/{P}` | 8 KiB |
| `GET /v0/requests/{D}/{R}` | 64 KiB |
| One page of `GET /v0/requests/{D}` | 16 KiB |
| One page of `GET /v0/devices` | 16 KiB |
| Any other response, errors included | 4 KiB |

The relay holds request bodies to the upload limits of section 7 the same way. Each drain on the Mac also has
a total budget of 8 MiB of downloads (section 9.2). The web app downloads only the objects the accepted index
names, at most 100 views (section 8.4), each within its limit.

## 4. Cryptography

### 4.1 Keys

| Key | What it is | Who holds it | Seals |
|---|---|---|---|
| Account key `K` | 32 random bytes, made by the owner, with an **epoch** `e` (section 4.4) | The owner (Keychain) and every active device | `index/{r}` |
| Binder key `Kb` | 32 random bytes per shown binder and epoch, made by the owner | The owner; devices learn it from the index | that binder's view |
| Device key `Kd` | 32 bytes derived during pairing (section 4.3), one per device | The owner (Keychain, filed under the device id) and that device only | `devices/{D}/keys/{e}`, `devices/{D}/outcomes/{r}` and that device's requests |
| Wrap key `W` | 32 bytes derived during pairing | Both sides, until the pairing ends | the pairing's `hello` and `key` |
| Owner signing key `(Ks, S)` | An Ed25519 key pair (RFC 8032), made by the owner when it claims the relay | `Ks`: the owner only (Keychain). `S`: every device, pinned at pairing | signs the index, views, keys and outcomes objects (section 4.5) |

Devices hold `K`, `Kb` and `Kd` as non-extractable WebCrypto keys, and `S` as a WebCrypto `Ed25519` public
key. No secret key is ever sent to the relay in the clear. Because each device seals its requests with its own
`Kd`, no device, and no former device, can send a request in another device's name. Because the owner signs
what it publishes with `Ks`, which no device holds, no device, and no former device, can forge what the owner
publishes. The web app refuses to run in a browser whose WebCrypto lacks X25519 or Ed25519.

### 4.2 Sealed objects

Every payload the relay stores, and every pairing message, is a **sealed object**: the UTF-8 JSON text

```
{"v":0,"kid":"<key id>","e":<epoch>,"n":"<b64 12-byte nonce>","c":"<b64 ciphertext followed by the 16-byte tag>"}
```

- Algorithm: AES-256-GCM, with a fresh random 12-byte nonce for every seal. `c` is the ciphertext with the
  16-byte tag appended (WebCrypto's output as it is; in CryptoKit, `ciphertext` followed by `tag`).
- Writers emit exactly this form: these keys in this order, no whitespace. Readers accept any order.
- `kid`: `"account"` for `K`, the binder's id for `Kb`, `"device"` for `Kd`, `"wrap"` for `W`.
- `e`: the epoch of the key (section 4.4); `0` for `hello` and outcomes. Section 4.4 says how each payload's `e`
  is checked.
- **Associated data**: the UTF-8 bytes of `sprava-companion/v0|<name>|<kid>|<e>`, with `e` in decimal without
  leading zeros. The name is the payload's name from section 8, for example
  `sprava-companion/v0|views/AAAAAAAAAAAAAAAAAAAAAA/7|AAAAAAAAAAAAAAAAAAAAAA|3`. A sealed object therefore fails
  to open under another name, another key or another epoch.
- Plaintext: UTF-8 JSON (section 8).
- A reader rejects a sealed object whose `v` is not `0`, whose `kid` is not the one the name calls for, whose
  `n` is not 12 bytes, or whose `c` is shorter than 16 bytes, before trying to open it.
- A payload the owner signs carries one more member, `s`, last (section 4.5). Any other sealed object carrying
  `s` is rejected.

### 4.3 Key agreement

X25519 public keys are 32 raw bytes. Both sides refuse a public key that is not 32 bytes, and refuse to go on if
the shared secret `Z` is 32 zero bytes (a low-order key).

From `Z`, the pairing id `P` and the transcript (`A`, the owner's public key; `B`, the device's; `D`, the
device id the owner chose, section 5.2), both sides derive three values with HKDF-SHA256 (RFC 5869):

```
salt = UTF-8 bytes of P (its 22 b64 characters)
W    = HKDF(ikm = Z, salt, info = "sprava-companion/v0 wrap"    || A || B || D, length = 32)
Kd   = HKDF(ikm = Z, salt, info = "sprava-companion/v0 device"  || A || B || D, length = 32)
code = HKDF(ikm = Z, salt, info = "sprava-companion/v0 confirm" || A || B || D, length = 4)
```

The `info` strings are their ASCII bytes, followed by the 32 bytes of `A`, the 32 bytes of `B` and the 16 bytes
`D` decodes to, with no separator. The **confirmation code** is `code` read as a big-endian unsigned 32-bit
integer, modulo 1,000,000, written as six decimal digits with leading zeros. Screens show it as two groups of
three (`042 917`).

### 4.4 Epochs and rotation

`K` has an epoch: an integer that is `1` for the first account key and grows by one at each rotation. All
binder keys are made anew at each rotation and share `K`'s epoch. Every sealed object carries its epoch in `e`,
and the associated data binds it.

The owner rotates after it revokes a device, and when the person asks:

1. The owner marks the device revoked in its own records, in the same durable write retires its outcome work
   (section 9.9), deletes that device's `Kd` from the Keychain, and calls `DELETE /v0/devices/{D}`.
2. It makes a new `K` with epoch `e + 1` and a new `Kb` for every shown binder (binder ids stay), and stores
   them in the Keychain before uploading anything. If it stops partway, it finishes the rotation at its next
   start; every step can be repeated.
3. For each remaining active device, it writes `devices/{D}/keys/{e + 1}` (section 8.3), sealed with that
   device's `Kd` and signed, recording the exact bytes durably before the first upload and sending those same
   bytes on every retry, after a restart too (section 9.7, "Write-once uploads"). Only that device can read it.
4. It takes a new snapshot of every shown binder, uploads each as a new view version sealed with its new
   `Kb`, then publishes the index sealed with the new `K` (section 9.7). Old view versions are deleted once
   that index is published.
5. It discards the old `K` and the old binder keys.

A device looks for its keys objects (section 10.3) when it starts, on every refresh, and whenever it meets an
index or a view whose epoch is above its own. If the newest valid one has a higher epoch than the one it holds,
it imports the new `K`, stores it and the epoch, and discards the old key. If it is equal, nothing changes. A
lower one is refused. A device that slept through several rotations reads only the latest keys
object; it needs no epoch in between.

The account epoch concerns only what `K` and the binder keys seal. Each payload's `e` is checked by its own
rule, and no other:

| Payload | Its `e` must be | Checked by |
|---|---|---|
| hello | exactly `0` | the owner |
| key | at least 1 and equal to the payload's `epoch`, which becomes the device's epoch | the device |
| device keys | equal to the payload's `epoch`; higher than the device's is adopted, equal is ignored, lower is refused | the device |
| index, view | exactly the device's current epoch; a higher one makes the device read its keys first; a lower one is refused | the device |
| outcomes | exactly `0`: `Kd` has no epoch. Rollback is refused by the outcomes `revision` (section 10.3) | the device |
| revocation | exactly `0` | the owner |
| request | from 1 to the owner's current epoch | the owner |

A revoked device still holds the old `K`, but it cannot forge anything a device accepts: the index, the views and
the keys and outcomes objects must carry the owner's signature (section 4.5), and no device holds `Ks`. With the
relay's help it can only replay objects the owner once published, which the high-water marks refuse (section
10.3), or read objects from before the rotation, which it could read already. It cannot change anything on the
Mac, because requests are sealed per device.

### 4.5 Owner signatures

The owner signs every object a device trusts: every index, view, keys and outcomes object. It seals
first, then signs, then writes the signature as the last member of the sealed object:

```
{"v":0,"kid":"<key id>","e":<epoch>,"n":"<b64 nonce>","c":"<b64 ciphertext and tag>","s":"<b64 64-byte signature>"}
```

The signed message `m` is the UTF-8 bytes of `sprava-companion/v0 signed|<name>|<kid>|<e>|`, with `e` in decimal
without leading zeros, followed by the 12 raw bytes of the nonce, followed by the raw bytes of `c` (ciphertext
and tag). The signature is Ed25519 (RFC 8032) by `Ks` over `m`: 64 bytes, written in b64. Because `m` is built
from the decoded fields, not from the JSON text, it does not depend on how the envelope is written, and it
covers every member except `s` itself.

A device verifies before it opens: it rebuilds `m` from the name it asked for and the envelope's fields, and
verifies `s` with the pinned `S`. An object without `s`, with an `s` that is not 64 bytes, or with a signature
that does not verify, is refused and never opened. A device never replaces `S`; a new signing key means pairing
again. CryptoKit may produce a different valid signature for the same input each time, so vectors test that
signatures verify, not that they are equal (section 14).

## 5. Pairing

### 5.1 The pairing link

```
<web app URL>#pair=v0.<b64 relay origin>.<P>.<pairing secret>.<b64 A>.<D>
```

The relay origin is the UTF-8 text of an origin: `https://host[:port]`, or `http://localhost[:port]` for
development, with no path, query or fragment. The pairing secret is 16 random bytes in b64. The link is shown
as a QR code on the Mac's screen. The fragment never reaches a server. The web app reads it, then removes it
from the address bar.

The device takes the relay origin, `A` and its device id `D` from the link and from nowhere else. The web app
URL is a setting on the Mac: the shared build's address by default, or a self-hoster's own, whose origin must
be the relay's `SPRAVA_WEB_ORIGIN`.

### 5.2 Steps

1. **Owner.** Makes a new random device id `D`, checks that `D` is in none of its device records, whatever
   their state, and records it durably as `pairing`; a device id is never used twice. It makes an ephemeral
   X25519 key pair `(a, A)`, calls `POST /v0/pairings` with `A` and `D`, and shows the link with the returned
   `P` and secret. The pairing expires 10 minutes after it is made. A pairing that ends without confirmation
   leaves `D`'s record as `abandoned`, never free.
2. **Device.** Parses the link and refuses it if any part is malformed. In one IndexedDB transaction with
   strict durability, it refuses the link if a pairing is installed, and otherwise records a **reservation**: a
   new random pairing generation `G` and `P`, replacing any earlier reservation, whose flow can then no longer
   install anything. It makes an ephemeral X25519 key pair
   `(b, B)` and computes `Z = X25519(b, A)`, then `W`, `Kd` and the code (section 4.3). Its transcript (`P`, `A`,
   `B`, `D`) is now fixed. It seals the `hello` payload (section 8.1) with `W` and calls
   `POST /v0/pairings/{P}/join` with the secret, `B` and the sealed hello. It receives its token and the
   pairing's `expires_at`, refuses the pairing if the response names a device id other than its `D`, and shows
   the confirmation code. If the join's
   response is lost, the device cannot join again: the person starts over with a new QR code.
3. **Owner.** Polls `GET /v0/pairings/{P}` every 2 seconds until its state is `joined`. It keeps the first `B` and
   hello it sees; its transcript (`P`, `A`, `B`, `D`) is now fixed. If any response names a device id other than
   its own `D`, or a later response shows a different `B`, it abandons the pairing. It computes
   `Z = X25519(a, B)`, then `W`, `Kd` and the code, and opens the hello. If the hello does not open or is invalid,
   it abandons the pairing. Only then does it show the code and the device's label, and ask the person whether the
   codes on both screens match.
4. **Owner, the person confirmed.** It checks again that `D`'s record is the `pairing` record it made in step 1;
   it never stores a key under, or resets, the record of another device. It takes the device's rollback floor
   under the publish lock (section 9.7): it first finishes or supersedes any unfinished publication, then takes
   the published revision, which is then the highest revision it ever assigned; 0 only if it never assigned
   one. It seals the `key` payload (section 8.2), which carries that floor and `S`, with `W`. Then, in one
   durable write, it stores `Kd` in the Keychain under `D`, the sealed key payload, and the record changed to
   active with its label and `highest_seq` 0 (section 9.1), so a restart can resend the same bytes. It writes
   `devices/{D}/keys/{e}` for the current epoch `e` (section 8.3), signed, as a write-once upload (section 9.7),
   and calls `PUT /v0/pairings/{P}/key` with the recorded bytes, repeating it after a restart until it gets
   `204`. The relay makes the device active. If the person says the codes differ, the owner calls
   `DELETE /v0/pairings/{P}` instead.
5. **Device.** Polls `GET /v0/pairings/{P}/key` every 2 seconds. When it gets the sealed key, it opens it with `W`
   and validates it (section 8.2). Then, in one IndexedDB transaction with strict durability, and only if its
   reservation is still the current one and no pairing is installed, it installs the pairing: `K`, its epoch,
   `Kd`, `S`, `D`, the token, the relay origin and its instance id (from `GET /v0/health`), the
   `min_index_revision` and `G` as the **pairing generation**, with `P`, its `expires_at` and an
   acknowledgement-pending flag; and it clears the reservation. Otherwise it installs nothing and tells the person
   this pairing was cancelled. It waits for the transaction to complete (section 10.2); `S` is pinned from now on.
   Only then does it call `POST /v0/pairings/{P}/ack`, retrying until it gets `204`, and forget `b` and `W`. At
   every start, a web app whose flag is still set resumes the acknowledgement for the installed `G` and `P`. On
   `204`, or on a `404` after `expires_at` (the Mac then lists the device as not confirmed, step 6), it clears the
   flag in a strict transaction that changes it only if the installed pairing generation and `P` are still the
   flow's `G` and `P`; a stale flow changes nothing.
6. **Owner.** Keeps polling the pairing until it is `acknowledged`, then forgets `a` and `W`. If the pairing
   expires first, it lists the device as "not confirmed by the phone" and offers to remove it.

Abandoning a pairing on either side means forgetting `a` or `b`, `W` and `Kd`. An abandoned pairing on the Mac
is also deleted from the relay.

### 5.3 Why this holds

The QR code carries `A` and `D` from the owner's screen to the device, so the relay cannot replace them, and
`D` is part of every derived value, so a pairing cannot be confirmed under another device's id. `S` reaches the
device inside the key payload, sealed with `W`, so it is as trustworthy as the pairing. The relay can
replace `B` on its way to the owner with a key of its own, `B'`. The owner would then compute its code from
`X25519(a, B')`, and the device from `X25519(b, A)`, which the relay cannot compute because it knows neither `a`
nor `b`. The two codes match only by chance, one time in a million per pairing, and a pairing allows one join.
Both transcripts are fixed before either screen shows the code, so the relay cannot search for a match after
seeing a code. The pairing secret proves to the relay that the joiner saw the QR code; the confirmation code
proves to the person that no one in the middle swapped keys.

## 6. Claiming a relay

A new relay has no owner. Its deployer generates a setup code and sets `SPRAVA_SETUP_CODE` (section 13):

```
openssl rand -base64 32
```

**Format.** A setup code is 44 characters of the standard base64 alphabet, with `=` padding, that decode to
exactly 32 bytes: exactly what that command prints. An unclaimed relay refuses to start if the variable is
missing or not in this form. The relay cannot check that a code is random; the documentation gives only the
command, never an example value, and the repository's templates leave the variable empty.

**Claiming.** Before its first claim request, the owner makes its owner token (section 3) and its signing key
pair (section 4.1), and stores durably, in the Keychain, the owner token itself, the signing key, the relay
origin and the instance it is claiming (read from `GET /v0/health`). Then it writes the claim body, which
refers to those stored credentials, durably, and sends that identical body on every retry, after a restart
too, until the claim is confirmed. If the relay's instance changes meanwhile, the claim is void and the owner
starts over:

```
{"setup_code": "...", "owner_token_sha256": "<64 lowercase hex>"}
```

`POST /v0/claim` with that body, of at most 1 KiB → `204`. The **owner record** `owner.json` (section 7.8) is
derived from the body and nothing else: exactly the bytes `{"owner_token_sha256":"<hex>"}`, with no
whitespace. It holds no time or other value the relay chooses, so any two writes for the same
claim are identical. A correct setup code is never refused because of anyone else's failures. The relay:

1. **Paces.** It processes at most 10 claim requests per second for the whole relay, one at a time. A request
   beyond that waits; one that has waited 5 seconds is answered `503` with `Retry-After: 1`. This bounds load,
   whatever the codes; it never depends on failures, and the Mac simply retries.
2. **Already claimed.** If the owner record exists: `204` if its bytes are exactly the ones this body derives
   (a retry of the claim that won; the relay never discloses the owner token's hash), and `409` otherwise,
   whatever the code.
3. **Checks the code first.** `sha256` of the submitted code is compared in constant time with `sha256` of the
   configured code. A correct code goes on to step 5, whatever has happened before.
4. **Throttles failures by address.** A wrong code is a failure, counted per client address (the address the
   relay's host reports for the connection) over the last 10 minutes. Up to 5 failures are answered `403`;
   later failures from that address are answered `429`, after a 2-second delay that holds only that
   response, not the relay's processing of other claims. Counts live in memory.
5. **Create if absent.** The relay writes the owner record only if it does not exist. The relay runs as
   exactly one instance (§13), so it makes this atomic in its own process: claims, pairing joins and request
   creation take one in-process lock, check that the object is absent, then write. It also sends
   `If-None-Match: *` on S3 and treats a `412` as "already exists", as a second guard on stores that honour it;
   it does not depend on it, because some S3-compatible stores (DigitalOcean Spaces among them) accept the
   header and overwrite anyway. On the filesystem it writes a temporary file in the same directory and `link`s
   it to the final name, which fails if the name exists.

A write the relay started before a crash may land after it restarts; the store does not fence it. For the
owner record this is harmless: a late write from an earlier attempt at the same claim writes the same bytes.
After the claim, the relay ignores `SPRAVA_SETUP_CODE`; the deployer should remove it. Every other claim is
refused with `409`, even after a restart or a change of the variable. While unclaimed, the relay serves
nothing but `health` and `claim`.

**Re-claiming** uses a fresh namespace. Everything the relay stores, the owner record included, lives under the
prefix `SPRAVA_INSTANCE` (section 13), a random id the deployer generates. To re-claim, the deployer stops the
relay, sets a new `SPRAVA_INSTANCE` and a new setup code, and starts it. The new instance reads and writes only
under its own prefix, so nothing of the old one, not even a write that lands late, can reach it; every earlier
token, device, object and request is out of sight at once. The deployer may delete the old prefix by hand. The
devices are then paired again.

## 7. The API

All endpoints are under `/v0/`, over HTTPS (plain HTTP only on `localhost`). Requests carry
`Authorization: Bearer <token>` unless marked public. Bodies are JSON unless marked bytes; bytes are sent as
`application/octet-stream`. Errors are `{"error": "<plain sentence>"}` with a 4xx or 5xx status; the relay
never echoes a request's content in an error. A missing or unknown token is `401`. A known token calling an
endpoint its role does not allow is `403`, except that a device reading an object it may not read gets `404`,
so it cannot learn which objects exist.

The relay drops a request whose body has not fully arrived within 60 seconds, and stores nothing for it. It
reads every request body as a stream and refuses it with `413` as soon as it passes its limit: 1 MiB
for an object, 64 KiB for a request, 1 KiB for a pairing key, and 4 KiB for any JSON body. It reads JSON
bodies strictly (section 3.1).

The relay runs as exactly one instance. Rate limits, the claim throttle and failed-join counts live in its
memory and reset when it restarts; everything else lives in the bucket (section 7.8).

### 7.1 Who may call what

A device is **pending** from its join until the owner posts its key, then **active**.

| Endpoint | Owner | Active device | Pending device | Public |
|---|---|---|---|---|
| `POST /v0/claim` | | | | yes (setup code) |
| `GET /v0/health` | | | | yes |
| `POST /v0/pairings`, `GET /v0/pairings/{P}`, `PUT /v0/pairings/{P}/key`, `DELETE /v0/pairings/{P}` | yes | | | |
| `POST /v0/pairings/{P}/join` | | | | yes (pairing secret) |
| `GET /v0/pairings/{P}/key`, `POST /v0/pairings/{P}/ack` | | its own pairing | its own pairing | |
| `GET /v0/devices`, `DELETE /v0/devices/{D}` | yes | | | |
| `DELETE /v0/devices/self` | | yes | | |
| `GET /v0/devices/{D}/revocation` | yes | | | |
| `PUT /v0/objects/{name}`, `DELETE /v0/objects/{name}` | yes | | | |
| `GET /v0/objects/{name}` | yes | `index/*`, `views/*/*`, its own `devices/{D}/keys/*` and `devices/{D}/outcomes/*` | | |
| `GET /v0/objects?prefix=...` | yes | the prefixes `index/`, its own `devices/{D}/keys/` and `devices/{D}/outcomes/` | | |
| `POST /v0/requests/{R}` | | yes | | |
| `GET /v0/requests/{D}`, `GET /v0/requests/{D}/{R}`, `DELETE /v0/requests/{D}/{R}` | yes | | | |

A pending device's token works for nothing but its own pairing's `key` and `ack`.

### 7.2 Health

`GET /v0/health` → `{"protocol": 0, "claimed": true|false, "instance": "<SPRAVA_INSTANCE>"}`. Nothing else,
so a scan learns nothing more. The instance id names the relay's namespace (section 6); the Mac uses it to tell
a re-claimed relay from the one it claimed.

### 7.3 Pairings

- `POST /v0/pairings` with `{"owner_public_key": "<b64 A>", "device_id": D}` → `{"pairing_id": P, "secret": "<b64
  16 bytes>", "expires_at": time}`. The owner chose `D`; the relay refuses it with `409` if a device or pairing in
  this instance already has it. At most 3 open pairings at once, and at most 20 devices, pending and active
  together (`507` beyond).
- `POST /v0/pairings/{P}/join` with `{"secret": "...", "device_public_key": "<b64 B>", "hello": "<b64 of the
  sealed hello, at most 2 KiB>"}` → `{"device_id": D, "device_token": "<token>", "expires_at": time}`. The relay
  makes the token and
  records the device `D` the owner chose as pending. The response carries no owner key; the device uses only the
  `A` of its QR code. A join works once per pairing (`409` after); a wrong secret is `403` and counts toward the
  pairing's limit of 5 failed joins, after which the pairing is deleted.
- `GET /v0/pairings/{P}` (owner) → `{"state": "open"|"joined"|"keyed"|"acknowledged", "device_id": D|null,
  "device_public_key": "<b64 B>"|null, "hello": "<b64>"|null}`. Once set, `device_id`, `device_public_key` and
  `hello` never change.
- `PUT /v0/pairings/{P}/key` (owner), body bytes: the sealed key payload, at most 1 KiB → `204`. In state
  `joined`, the relay writes, in this order, the device's activation marker, the payload's SHA-256 (`key.sha256`,
  kept until the pairing is deleted) and the payload (section 7.8); the pairing is then `keyed` and the device
  active. In `keyed` or `acknowledged`, an upload whose SHA-256 equals `key.sha256` is a retry: `204`, and the
  payload is written again if it is missing and the pairing is not yet acknowledged. Other bytes are `409`.
- `GET /v0/pairings/{P}/key` (the device that joined `P`) → bytes, the sealed key payload. `404` before the
  owner posts it. Idempotent: it returns the same bytes on every call until the device acknowledges or the
  pairing expires.
- `POST /v0/pairings/{P}/ack` (the device that joined `P`) → `204`, in state `keyed` or `acknowledged`. The
  relay writes the pairing's acknowledgement, which makes it `acknowledged`, then deletes the sealed key
  payload, keeping `key.sha256`. Repeating it is harmless.
- `DELETE /v0/pairings/{P}` (owner) → `204`. Deletes the pairing, and its device if that device is still
  pending.

A pairing is deleted 10 minutes after it was made, whatever its state. A device still pending at that moment
is deleted with it. A device that was made active stays; the owner decides about it (section 5.2, step 6).

**One authority for activation.** A device is active exactly when its activation marker exists and its
revocation marker does not; the pairing's state is the furthest of its write-once parts that exists (section
7.8). There is no separate state field that could disagree. Because the marker is written before the key, a
device that can fetch its key is always active. Admitting a token checks the revocation marker first, then
the record, then, for anything but the device's own pairing, the activation marker.

### 7.4 Devices

- `GET /v0/devices?limit=<n>[&after=<D>]` → `{"devices": [{"device_id": D, "state":
  "pending"|"active"|"revoked", "paired_at": time|null, "last_seen": time|null}], "next": D|null}`, ordered by
  device id, at most `limit` (1 to 50, default 50) devices after `after`; `next` is the `after` for the next
  page, or `null`. It lists only devices that still have a record: pending, active, and self-revoked ones the
  owner has not yet deleted. A device the owner deleted keeps only its revocation marker and is not listed.
  The state is derived as section 7.3 says; a device with a revocation marker is `revoked`. `last_seen` is
  rounded down to the hour. The relay holds no label; the Mac
  keeps labels in its own records.
- `DELETE /v0/devices/{D}` → `204`. The relay writes the device's revocation marker, so its token stops
  working at once and for good, then deletes its record, pending requests, and keys and outcomes objects. No
  cleanup ever deletes the marker; it stays until the instance is retired, so no late write can bring the
  device back.
- `DELETE /v0/devices/self` (an active device, about itself), body bytes: its sealed revocation (section 8.8), at
  most 1 KiB → `204`. The relay stores the revocation at `devices/{D}/revocation`, then writes the calling
  device's revocation marker exactly as above, so its token stops working at once, and deletes its pending
  requests. It keeps the device's record and the revocation until the owner deletes the device. The relay cannot
  read or forge the revocation; the Mac acts only on one that opens with the device's `Kd` (section 9.2).
- `GET /v0/devices/{D}/revocation` (owner) → bytes, the stored revocation, or `404`. The revocation is kept
  until the owner's `DELETE /v0/devices/{D}`, which deletes it with the rest.

### 7.5 Objects

A device may make at most 600 object reads and listings per hour (`429` beyond).

Every object is immutable and named by its revision, so a late write of an older revision can never replace
a newer one: their names differ. Object names are `index/{r}`, `views/{id}/{version}`, `devices/{D}/keys/{e}`
and `devices/{D}/outcomes/{r}`, where `{id}` and `{D}` are ids and `{r}`, `{version}` and `{e}` are unsigned
integers of at least 1, in decimal without leading zeros. Nothing else is accepted.

- `PUT /v0/objects/{name}`, body bytes (a sealed object, at most 1 MiB) → `204`. A `PUT` to a name that exists
  is refused with `409` and changes nothing, unless the stored bytes are identical, which is `204`, so a retry
  is harmless. The check and the write happen under the relay's creation lock.
- `GET /v0/objects/{name}` → bytes.
- `DELETE /v0/objects/{name}` → `204`, also when the name does not exist.
- `GET /v0/objects?prefix=<p>[&limit=<n>][&below=<number>]` → `{"names": ["index/42", ...], "next":
  <number>|null}`. `<p>` is one of `index/`, `views/{id}/`, `devices/{D}/keys/` and `devices/{D}/outcomes/`.
  The names under it come newest first, ordered by their last segment as a number, at most `limit` (1 to 100,
  default 20), and only those whose number is below `below` when it is given. `next` is the number to pass as
  `below` for the next page, or `null`.

**Finding the newest.** A reader lists a prefix and takes the candidates in order, newest first. It takes the
first one whose signature verifies, that opens and is valid, and that is not below its high-water marks
(section 10.3); it tries at most 5 candidates in one refresh. A relay that hides the newest revision is
withholding, which the protocol cannot prevent (section 2); one that lists names that do not exist or do not
verify only costs the reader those tries.

### 7.6 Requests

- `POST /v0/requests/{R}` (active device), body bytes (a sealed object, at most 64 KiB) → `201`. The device
  chooses `R` (section 9.8) before sealing. The relay stores the bytes under `requests/{D}/{R}`, where `D` is
  the calling device. If that name already exists, it refuses with `409` and keeps the stored bytes; a device
  treats `409` as success, because it means its earlier attempt was stored. At most 120 requests per device
  per hour (`429` beyond), and at most 1,000 pending per device (`507` beyond).
- **Ordinals.** Under its creation lock, the relay gives each request it stores the next **ordinal** of its
  device: an unsigned integer, above every ordinal of that device's stored requests, and stores the request
  with it in its name (section 7.8). The relay keeps no counter that a late write could set back: at start,
  before serving, it derives each device's next ordinal from the highest ordinal stored, plus one. A late write
  from before a restart can only add a second copy of a request the device sent again under the same `R`;
  the relay lists both, and the Mac decides the request once and discards the other copy as a duplicate
  (section 9.3). Ordinals of deleted requests may be given again; nothing compares them across drains.
- `GET /v0/requests/{D}?limit=<n>[&after=<ordinal>]` (owner) → `{"requests": [{"request_id": R, "ordinal": n,
  "received_at": time}], "next": <ordinal>|null}`: that device's requests with an ordinal above `after`, in
  ascending ordinal, at most `limit` (1 to 100, default 25). `next` is the last ordinal returned when more may
  follow, and `null` otherwise. Requests are listed and paged by ordinal only: receipt times and names never
  order them. A device sends its next request only after the previous one was stored (section 9.8), so for an
  honest relay ordinal order is the device's sequence order. `received_at` is informative and not trusted.
- `GET /v0/requests/{D}/{R}` → bytes. `DELETE /v0/requests/{D}/{R}` → `204`.
- A request not collected within 30 days is deleted.

### 7.7 Cross-origin requests

The web app runs at another origin, set in `SPRAVA_WEB_ORIGIN` (section 13). The relay:

- refuses with `403`, before anything else, any request whose `Origin` header is present and is not exactly
  `SPRAVA_WEB_ORIGIN`;
- refuses with `403` any request to `POST /v0/claim` or to an owner endpoint that carries an `Origin` header at
  all (the Mac sends none);
- answers a request from the web app's origin with `Access-Control-Allow-Origin: <SPRAVA_WEB_ORIGIN>`,
  `Access-Control-Expose-Headers: ETag` and `Vary: Origin`, and never with `Access-Control-Allow-Credentials`
  (the web app uses bearer tokens, not cookies);
- answers a preflight `OPTIONS` from that origin with `204`, `Access-Control-Allow-Methods: GET, POST` (and
  `GET, POST, DELETE` for `/v0/devices/self` only; every other deletion is an owner endpoint and refused with an
  `Origin` header),
  `Access-Control-Allow-Headers: Authorization, Content-Type, If-None-Match` and
  `Access-Control-Max-Age: 600`.

### 7.8 What the relay keeps in the bucket

A write the relay started before a crash may land after it restarts (section 6). So every object it keeps is
either **write-once** with content fixed by its first writer, so a late write repeats the same bytes, or
**informative** and never used to decide anything, or derived again at start.

| Object, under the prefix `SPRAVA_INSTANCE/` | Kind | Holds |
|---|---|---|
| `owner.json` | write-once, derived from the claim body | the owner token's hash (section 6) |
| `devices/{D}/record.json` | write-once, at join | the token's hash, the pairing id, when it joined |
| `devices/{D}/active` | write-once marker, at key installation, before the key | nothing |
| `devices/{D}/revoked` | write-once marker, at removal, before any deletion; never cleaned up | nothing |
| `devices/{D}/revocation` | write-once, at a device's self-revocation, before the marker; kept until the owner deletes the device | the device's sealed revocation |
| `devices/{D}/last_seen` | informative | the hour the device was last seen; a late write can only set it back an hour |
| `pairings/{P}/created.json` | write-once | `A`, `D`, the secret's hash, `expires_at` |
| `pairings/{P}/joined.json` | write-once | `B` and the sealed hello |
| `pairings/{P}/key.sha256` | write-once, kept until the pairing is deleted | the SHA-256 of the key payload |
| `pairings/{P}/key` | write-once | the sealed key payload, deleted after the acknowledgement |
| `pairings/{P}/ack` | write-once marker | nothing |
| `objects/{name}` | write-once (section 7.5) | a sealed object |
| `requests/{D}/{ordinal}-{R}` | write-once | a sealed request |

A pairing is `open` when only `created.json` exists, `joined` with `joined.json`, `keyed` with `key.sha256`, and
`acknowledged` with `ack`. The ordinal in a request's name is written as 16 decimal digits so that a listing of
the prefix comes back in ordinal order. The relay keeps in memory, for each device, a map from `R` to its ordinal,
rebuilt from that listing at start, so `requests/{D}/{R}` in the API finds the object; when two copies hold the
same `R`, it keeps the one with the lower ordinal and deletes the other.

At start, before serving, the relay repairs and cleans up, in this order, and never deletes a revocation
marker:

1. it gives an activation marker to the device of a pairing that has `key.sha256` or `ack`, unless that device
   has a revocation marker;
2. it deletes the parts of every pairing past its `expires_at`, with the record of its device only if that
   device is still pending (it has neither an activation nor a revocation marker); a self-revoked device's
   record and revocation stay until the owner deletes the device;
3. it deletes any other pairing part whose `created.json` is missing, and any device part whose `record.json`
   is missing, revocation markers excepted.

## 8. Payloads

Each payload is the plaintext JSON of a sealed object. The table gives its name (used in the associated data
and the signature), its key, its epoch, whether the owner signs it (section 4.5), and how it is padded. A
payload that does not open, that is not signed when it must be, or that breaks any rule below, is invalid as a
whole. A field marked optional may be absent or `null`; a field the payload does not define is ignored.

| Payload | Name | kid | e | Signed | Padded to | Written by | Read by |
|---|---|---|---|---|---|---|---|
| hello | `pairings/{P}/hello` | `wrap` | `0` | no | 512 bytes | device | owner |
| key | `pairings/{P}/key` | `wrap` | the epoch it carries | no | | owner | device |
| device keys | `devices/{D}/keys/{e}` | `device` | the epoch it carries | yes | | owner | that device |
| index | `index/{r}` | `account` | current epoch | yes | | owner | devices |
| view | `views/{id}/{version}` | the binder's id | current epoch | yes | | owner | devices |
| outcomes | `devices/{D}/outcomes/{r}` | `device` | `0` | yes | 512 + 128 × entries | owner | that device |
| request | `requests/{D}/{R}` | `device` | the device's epoch when it sealed | no | a multiple of 1,024 bytes | device | owner |
| revocation | `devices/{D}/revocation` | `device` | `0` | no | | device | owner |

**Padding.** A padded payload carries a member `pad`: a string of ASCII spaces (U+0020) only, possibly empty. The
writer serializes the payload with `"pad":""`, measures its length `L` in bytes, and sets `pad` to `T − L` spaces,
where `T` is the target: 512 for hello; for a request, the smallest multiple of 1,024 that is at least `L` (so at
least 1,024); for outcomes, `512 + 128 × n` for `n` entries (section 8.7). Each space adds exactly one byte, so
the plaintext is then exactly `T` bytes. A reader rejects a padded payload whose `pad` is missing, holds anything
but spaces, or whose plaintext length is not the target (512 for hello; a multiple of 1,024 for a request;
`512 + 128 × n` for outcomes). A check-off and a note of a few sentences are then the same size.

**Size limits.** Every text limit below is given twice, in characters (Unicode scalar values) and in encoded
bytes (section 3.1); a value must meet both. The limits are chosen so that every payload that meets them fits
its padding target and its sealed transport limit:

| Payload | Largest plaintext | Sealed object, at most | Transport limit |
|---|---|---|---|
| hello | 512 bytes (the longest label needs 181) | 760 bytes, 1,014 in b64 | 2 KiB in the join body |
| key | 227 bytes | 395 bytes | 1 KiB |
| device keys | 123 bytes | 352 bytes, signed | 4 KiB |
| index | 92,700 bytes (100 binders, the longest names) | 123,800 bytes, signed | 1 MiB |
| view | 778,240 bytes (760 KiB) | 1,037,857 bytes, signed | 1 MiB (1,048,576 bytes) |
| request | 48,128 bytes (47 KiB); the longest note needs under 40,300 | 64,265 bytes | 64 KiB (65,536 bytes) |
| outcomes | 2,000 entries, padded: 256,512 bytes | 342,300 bytes, signed | 512 KiB |

A sealed object's `c` is the plaintext plus 16 bytes, in b64 (4 characters for every 3 bytes, rounded up);
the envelope and signature add under 200 bytes. Writers check the limits before sealing: the web app before it
joins a pairing or enqueues a request, telling the person what is too long; the Mac before it publishes.
Readers check them after opening.

### 8.1 hello

`{"label": "...", "pad": "..."}`. A name the person gives the device ("Pixel"), shown on the Mac and kept only
there. The label has 1 to 40 characters and at most 160 encoded bytes, and no character below U+0020 and no
U+007F.

### 8.2 key

```
{"account_key": "<b64 32 bytes>", "epoch": <integer>, "device_id": D, "min_index_revision": <integer>,
 "owner_signing_key": "<b64 32 bytes>"}
```

Valid when `account_key` decodes to exactly 32 bytes, `epoch` is at least 1 and equals the envelope's `e`,
`device_id` equals the `D` of the pairing link, `min_index_revision` is at least 0, and
`owner_signing_key` decodes to exactly 32 bytes and imports as an Ed25519 public key. The device will accept no
index with a lower revision (section 10.3), and pins `owner_signing_key` as `S` (section 4.5). The owner sets
`min_index_revision` to the latest index revision it has recorded as published, read under the publish lock
when the person confirms the pairing (section 9.7); it is 0 only if the owner has never published an index.

### 8.3 device keys

```
{"account_key": "<b64 32 bytes>", "epoch": <integer>, "device_id": D}
```

Valid when the owner's signature verifies (section 4.5), `account_key` decodes to exactly 32 bytes, `epoch` is
at least 1 and equals both the envelope's `e` and the `{e}` of its name, and `device_id` equals the reading
device's id. Accepted as section
4.4 says.

### 8.4 index

```
{"revision": <integer>, "generated_at": time,
 "binders": [{"id": "<binder id>", "name": "...", "view_version": <integer>, "key": "<b64 32 bytes>"}]}
```

Valid when the owner's signature verifies (section 4.5), `revision` equals the `{r}` of its name, `generated_at`
is a time, `binders` has at most 100 entries, every `id` is an id and unique, every `name` has 1 to 200 characters
and at most 800 encoded bytes (a longer binder name is published cut to fit, on a character boundary, ending in
`…`), every `view_version` is at least 1, and every `key` decodes to exactly 32 bytes. The binder's view is the
object `views/{id}/{view_version}`, exactly that version, sealed with `key` at the index's epoch.

A binder's id is random, made when the person turns "Show on my phone" on, and never derived from its name or
folder. Turning it off removes the entry and the view; the next turn-on makes a new id and key. At most 100
binders are shown at once; the switch refuses a 101st and says why. A shown binder with no version uploaded
at the index's epoch yet is left out of the index until it has one (section 9.7).

### 8.5 view

```
{"version": <integer>, "generated_at": time, "today": "YYYY-MM-DD",
 "binder": {"name": "...", "description": "..."|null}, "notes_omitted": true|false,
 "buckets": {"overdue": [item ids], "today": [...], "next_7_days": [...], "later": [...],
             "no_deadline": [...], "nudge": [...], "waiting": [...]},
 "items": [{"id": <item id>, "changed_in": <integer>, "title": "...", "status": "...", "priority": "..."|null,
            "due": "YYYY-MM-DD"|null, "waiting_on": "..."|null, "follow_up_at": "YYYY-MM-DD"|null,
            "notes": "..."|null, "tags": [...], "contexts": [...]}],
 "closed": [{"id": <item id>, "title": "...", "closed_at": time|null, "how": "done"|"dropped"}],
 "documents": [{"title": "...", "date": "YYYY-MM-DD"|null}]}
```

An item id is the binder's own (binder-v0 §5.6): a string of 1 to 200 characters and
at most 800 encoded bytes, or a non-zero signed integer (section 3). An item whose id breaks this is left out of
the view, and the Mac's Health line names it. Two item ids are the same when they have the same JSON type and the
same value; strings compare as section 3 says, so `7` and `"7"` differ.

`items` holds the binder's open items, except those with `dismissed: true`, which are never published
(binder-v0 §5.7). A view is valid when the owner's signature verifies (section 4.5), `version` equals the
version in its name, item ids are unique across `items` and `closed`, every id in a bucket names an entry of
`items`, every `changed_in` is from 1 to `version`, and its plaintext is at most 778,240 bytes; and when every
field has its type: `generated_at` and `closed_at` are times (or `null` where shown), `today`, `due`,
`follow_up_at` and document dates are dates (section 3) or `null`, `status` is `open`, `waiting` or `blocked`,
`how` is `done` or `dropped`, `tags` and `contexts` are arrays of strings, and every other field shown as
`"..."` is a string, or `null` where shown. `priority` is shown as it is, whatever the string. A `due` that is
not a valid date in the binder is published as `null`. `changed_in` is the version of the first snapshot that
carried the item's current record (section 9.7). If a binder's view would be larger than the limit, the Mac
publishes it with every `notes` set to `null` and `notes_omitted` `true`, and the app says notes are not
shown; if it is still too large, the Mac does not publish that binder and says so on its Health line.

Buckets and their order follow binder-v0 §5.2, computed by the owner for the day in `today`; the eighth
bucket, Recently closed, is `closed`, which holds the last 7 days.

### 8.6 request

```
{"seq": <integer>, "type": "done"|"drop"|"follow_up"|"arrived"|"postpone"|"note", "made_at": time,
 "binder": "<binder id>"|null, "item": <item id>|null, "seen_version": <integer>|null,
 "date": "YYYY-MM-DD"|null, "text": "..."|null, "pad": "..."}
```

`seq` is at least 1, `made_at` is a time (the device's clock; informative only), and `pad` follows the padding
rule above. By type:

| Type | `binder` | `item` | `seen_version` | `date` | `text` |
|---|---|---|---|---|---|
| `done`, `drop`, `arrived` | required | required | required, at least 1 | absent or null | absent or null |
| `follow_up`, `postpone` | required | required | required, at least 1 | required | absent or null |
| `note` | optional | absent or null | absent or null | absent or null | required: 1 to 10,000 characters, at most 40,000 encoded bytes, no character below U+0020 except U+0009 and U+000A |

A request that breaks this table is invalid. Section 9.5 says what each type does.

### 8.7 outcomes

```
{"device_id": D, "revision": <integer>, "generated_at": time,
 "outcomes": [{"request_id": R, "seq": <integer>,
               "outcome": "applied"|"conflict"|"rejected"|"unknown", "decided_at": time}],
 "pad": "..."}
```

**Padding.** The plaintext is padded, by the rule of section 8, to exactly `512 + 128 × n` bytes, where `n` is
the number of entries. The largest header (with `"pad":""`) takes 127 bytes and the largest entry with its
comma 120, so every payload fits, and its size depends only on `n`: not on the outcomes, the sequence numbers,
the revision or the dates. A reader rejects one of any other length.

Valid when the owner's signature verifies (section 4.5), `device_id` equals the reading device's id, `revision`
equals the `{r}` of its name, `outcomes` has at most 2,000 entries with unique request ids, and every `seq` is at
least 1. Only a request with a valid `seq` gets an outcome (section 9.3). Section 9.9 says what it lists.
`applied`, `conflict` and `rejected` are final. `unknown` is not: it says the Mac received the request again
but no longer knows how it decided it (section 9.4); the device keeps the action unresolved.

### 8.8 revocation

```
{"type": "revoke-self", "device_id": D, "instance": "<the relay's instance id>", "pairing_generation": "<b64 G>",
 "made_at": time}
```

Sealed with the device's `Kd` under the name `devices/{D}/revocation`, so it is domain-separated from every
request and bound to the device. Valid when it opens, `type` is `revoke-self`, `device_id` is `D`, and
`instance` is the instance the owner claimed (section 6); the web app reads the instance from
`GET /v0/health` when it installs the pairing and keeps it with the pairing. `pairing_generation` and
`made_at` are informative.

## 9. The Mac's side: publishing and draining

The relay's checks protect the relay from abuse. They do not protect the Mac: the Mac makes every decision
below from its own records, whatever the relay says.

### 9.1 What the Mac keeps

- The relay origin, its instance id and the owner token (Keychain), stored before claiming (section 6).
- The account key and its epoch; the current binder keys; the owner signing key `Ks` (Keychain).
- For each device: its id, its label, its state (`pairing`, `active`, `revoked` or `abandoned`; an id is never
  reused, section 5.2), its `Kd` (Keychain), when it was
  paired, whether it acknowledged, and `highest_seq`, the highest sequence number decided for it (0 at
  pairing). A revoked device's record is kept, without its key, so its requests are recognised.
- **Decision records**, only for authenticated requests (section 9.3): for each `(D, R)` being decided, its
  intended outcome, its `seq`, the validated request payload, the full effect and its effect id (section 9.6).
  A record exists only while its state is `deciding`; when the decision commits, it is replaced by its
  tombstone. A device has at most one at a time.
- **Outcome tombstones**: for each device, for as long as its record exists, one compact entry per decided
  request: `R`, its `seq`, its outcome and the time it was decided, about 30 bytes. A tombstone outlives
  the full decision record and is never changed. Each device also keeps `tombstone_floor`, the lowest `seq` from
  which its tombstones are complete, starting at 1. The Mac may prune tombstones more than a year old to save
  space; it then raises `tombstone_floor` to one above the highest `seq` it pruned, in the same write.
- For each device, its outcomes counters and revisions (section 9.9).
- For each shown binder, its snapshot record and its view versions, each `uploading` or `uploaded`; and, for
  as long as the relay instance is in use, the id of every binder recorded as `removed`, a few bytes each
  (section 9.7).
- The last index revision assigned, and `published_revision`, the last one whose upload completed.
- For each device, in memory: its retry backoff (section 9.2).
- **Diagnostics** for requests that fail authentication (section 9.3), bounded: a counter per device and
  reason, and a ring of the last 100 such failures (time, device id, request id, reason). Nothing else is kept
  for them.
- For each device, how many decisions it committed today, for the daily cap (section 9.2).

### 9.2 One drain

A drain has a budget: at most 100 requests and 8 MiB of downloads in all (section 3.2), and for each device at
most one listing page and 25 requests. The relay's own limits are not relied on. Devices are served in turn,
so one device's mailbox never uses another's share. A device also has a **daily cap** of 500 committed
decisions, which bounds what even an abusive authenticated device can make the Mac store (about 15 KB of
tombstones a day). A device at its cap is skipped until the next day, its requests wait on the relay, and the
Health line says so.

1. **Reconcile.** Read `GET /v0/devices`, page by page, at most 5 pages. A device the relay lists as active but
   the Mac's records do not (it was revoked, or is unknown) is deleted with `DELETE /v0/devices/{D}`, which
   deletes its requests too. A device active in the Mac's records that the relay lists as `revoked` may have
   removed itself (section 9.8, step 4); the Mac handles at most 10 of these per drain, and the rest at the next.
   It fetches its revocation with `GET /v0/devices/{D}/revocation`. Only if that is valid (section 8.8) does the
   Mac revoke the device in its records and rotate keys exactly as for its own revocation (section 4.4). Otherwise
   the relay's status alone changes nothing: the Health line shows it as a relay anomaly ("the relay says Pixel
   was removed, without proof"), and the person decides.
2. **Visit devices in turn.** Take the devices that are active in the Mac's records, in a fixed order, starting
   one place after where the previous drain started, and skip any that is backing off. For each one, until
   the drain's budget is spent:
   1. **Recover** any decision record of that device still `deciding` (section 9.6). If it cannot be
      finished, the device stops here.
   2. **List** one page: `GET /v0/requests/{D}?limit=25`.
   3. **Check.** Fetch each listed request and run the checks of section 9.3 on it, on its own.
   4. **Decide** the requests that passed, in ascending `seq` (sections 9.4 and 9.5).
   5. **Record** each outcome (section 9.6), then delete the request from the relay. A deletion that fails is
      repeated by the next run, which finds the request already decided.
3. **Publish outcomes** for every device whose outcomes changed (section 9.9), whatever happened above.
4. The rest waits for the next run.

**Retryable failures** leave the request on the relay and record nothing. There are two kinds:

- **Device failures**: a binder that is busy or needs attention, met while deciding one of this device's
  requests. The Mac stops that device for this drain: it takes no later step for any other request of that
  device, whether or not it was fetched or opened, and leaves them all on the relay. So a request is never
  overtaken by a later one from the same device, and the sequence check of section 9.4 stays strict. The
  device then backs off: it is skipped for 1 minute, then 2, 4 and so on up to 1 hour, and the backoff resets
  after a drain in which the device decided a request. Device failures never count toward the companion
  job's breaker; the Health line names the device and the binder it waits for.
- **Job failures**: the relay unreachable or answering `5xx`, a download cut short, a disk error. They end the
  drain for every device and count toward the companion job's breaker.

A rejected or discarded request is neither: it never stops anything.

### 9.3 Checks before opening

In order; the first that fails decides. A request that fails a check up to step 6 either has not been shown to
come from the device at all (the relay, or anyone, could have made it) or carries no sequence number to decide
it under. It is **discarded**: the Mac deletes it from
the relay and counts it in its bounded diagnostics (section 9.1), with no decision record, no tombstone, no
outcome and no journal line of its own. Only an authenticated request is ever decided.

1. `D` and `R` are ids. Otherwise **discarded** (`bad-id`).
2. `(D, R)` has a tombstone or a decision record: a **duplicate**. Delete it from the relay and record nothing
   more.
3. `D` is `active` in the Mac's records (not merely on the relay). Otherwise **discarded** (`not-active`).
4. The body came whole and within 64 KiB (section 3.2). A body over the limit is **discarded** (`too-large`);
   one cut short is a job failure (section 9.2).
5. The bytes are strict JSON (section 3.1) and a sealed object without `s`, with `kid` `"device"` and an `e`
   from 1 to the current epoch, and they open with `Kd` of `D` under the name `requests/{D}/{R}`. Otherwise
   **discarded** (`unreadable`). From here on the request is authenticated.
6. The payload is strict JSON, an object, with a valid `seq` (section 8.6). Otherwise **discarded**
   (`no-seq`): it never moves `highest_seq` and gets no outcome.
7. The rest of the payload is valid (section 8.6), padding included. Otherwise **rejected** (`invalid`): the
   device sent it under a sequence number, so it is decided, with a tombstone and an outcome.

### 9.4 Order and replay

For each device, the requests that passed section 9.3 are taken in ascending `seq`; two with the same `seq` are
taken in the bytewise order of `R`. A request whose `seq` is not above the device's `highest_seq` (and whose
`(D, R)` has no tombstone, section 9.3) is **rejected** (a replay, or one the relay held back), or gets `unknown`
as the next paragraph says. Every other request, once decided, whatever its outcome, raises `highest_seq` to its
`seq`. A retryable failure stops the device at once (section 9.2): its later requests wait, undecided, so they
never raise `highest_seq` past one that will be retried.

Because the relay lists a device's requests by ordinal (section 7.6), and the device stores each request before
sending the next, a later page never holds a request with a lower `seq` than one already decided, unless the relay
misbehaves. A gap in sequence numbers is allowed; the Mac journals it as a request that never arrived.

The Mac never issues a second final outcome for a request it has decided: a request it has a tombstone for is a
duplicate and gets nothing new. A request with no tombstone whose `seq` is at least `tombstone_floor` and not
above `highest_seq` was never decided (its number was skipped, or the relay held it back), so `rejected` is its
first and only decision. Only a request whose `seq` is below `tombstone_floor`, where the Mac's knowledge is
incomplete, gets the non-final outcome `unknown` instead: the Mac deletes it, applies nothing, and records a
tombstone saying `unknown`.

### 9.5 Authorization, conflicts and effects

Under the binder's write lock (binder-v0 §4.9), for every type but `note`, in order; the first rule that
decides, decides:

1. The binder is currently shown, by its id in the Mac's own records. Otherwise **rejected** (`not-shown`). A
   binder turned off and on again has a new id, so a request for the old one is rejected.
2. The item is in that binder, open or closed. Otherwise **rejected** (`not-in-binder`).
3. `seen_version` is not above the binder's `reserved` version (section 9.7). Otherwise **rejected**
   (`future-version`).
4. **Closed items.** A `done` on an item closed as done, or a `drop` on an item closed as dropped, is
   **applied** with no change. Any other request on a closed item is a **conflict**.
5. **Status.** The item's status must be one the table below allows for the type. Otherwise **conflict**.
6. **Dates.** For `follow_up` and `postpone`, a `date` earlier than the Mac's today is a **conflict**.
7. **As the person saw it.** The hash of the item's current record (section 9.7) must equal the hash in the
   binder's snapshot record, and its recorded `changed_in` must not be above `seen_version` (section 9.7).
   Otherwise **conflict**: the item changed since the person saw it, or since the last snapshot, even while
   that snapshot is still uploading, or it has no snapshot record.
8. Otherwise the request is **applied**: the Mac writes the op of the table as the person's own action
   (actor kind `user`), with Undo, exactly as its own buttons would.

| Type | Item status | The op, and nothing else |
|---|---|---|
| `done` | `open`, `waiting`, `blocked` | `complete`, with `closed_at` the op's `at` and `source` `user`. On a recurring item, `occurrence_due` and `next_due` as binder-v0 §5.4 says, and the item stays open. |
| `drop` | `open`, `waiting`, `blocked` | `drop`, with `closed_at` the op's `at` and `source` `user`. |
| `follow_up` | `waiting`, `blocked` | `update_item` setting `follow_up_at` to `date`. The status, `due`, `waiting_on` and `expected_by` stay; `derived` loses `follow_up_at` (binder-v0 §5.3). The person chased and is waiting again. |
| `arrived` | `waiting`, `blocked` | `set_status` to `open` with no other argument: `waiting_on`, `follow_up_at` and `expected_by` are removed (binder-v0 §5.3); `due` stays. |
| `postpone` | `open`, with a valid `due` | `update_item` setting `due` to `date`. Everything else stays; `derived` loses `due`. |

These are the three answers of a Nudge card (binder-v0 §5.3): a new `follow_up_at`, `set_status` to `open`, or
`complete`; plus Drop, and Postpone for an open item with a deadline.

A **conflict** changes nothing in the binder. The Mac shows a card naming the device, the item and the action
("you marked this done on your phone, but it changed since"), from which the person can apply it or dismiss
it. There is at most one card for each `(D, R)`: creating a card that exists does nothing.

For `note`: the note is **applied**. The Mac writes a capture event exactly as capture-event-v0 §8.1 (in-app
text) says, with a `source.ref` UUID minted when it decides (section 9.6) and the SHA-256 of `text` as
`source.revision`, plus `binder_hint` when `binder` is given and that binder is currently shown, and
`extensions.sprava.companion` `{"device_id": D, "request_id": R}`. The event's id is the effect id, so writing
it twice makes one capture (capture-event-v0 §5.4).

### 9.6 Recording outcomes and recovering

Every decision goes through a durable decision record under `(D, R)`, so a crash never applies a request
twice, never loses one, and never takes a logged op for one that took effect.

1. **Intend.** Before any effect, the Mac writes and flushes the record, holding everything needed to finish
   the decision without the relay: state `deciding`; the `seq`; the validated request payload (section 8.6),
   so the request can be decided again even after the relay deleted or expired it; the decided outcome; and
   the effect in full, under a stable **effect id**:
   - for an op: the complete op as it will be written (its id, a new UUID per binder-v0 §6.2, its type and
     every `args` value, its `at`, and its `note` `companion:{D}/{R}`), and the binder it goes to;
   - for a note: the complete capture event of section 9.5, with its id and `source.ref`;
   - for a conflict: the card's key `(D, R)` and its full contents (the device's label, the binder, the
     item's id and title as they were, the action and its date);
   - for a rejection: the reason only (for `invalid`, the record holds the `seq` but no payload).
2. **Apply.** Write that op under the binder's lock (binder-v0 §4.9 and §6.9), or that capture event, or the
   card for `(D, R)`, exactly as recorded.
3. **Commit.** In one durable write: replace the decision record by the request's tombstone, raise
   `highest_seq` (section 9.4), count the decision toward the device's daily cap, and mark the device's outcomes
   as changed (section 9.9).
4. **Delete** the request from the relay.

**Recovery.** A record left `deciding` by a crash is finished from the record alone. The Mac does this per
device, at the start of that device's turn in a drain (section 9.2), before taking any new request of that
device:

- **An op.** The Mac first lets the binder recover under its lock (binder-v0 §6.7), with one change for a
  trailing write whose op is tagged `companion:{D}/{R}` (the op's `note`, step 2): in §6.7 step 3 (`H = b` and
  `S = b`), Sprava does not roll it forward, because a write that never reached the catalog and one that did,
  after which an outside edit restored the exact earlier catalog, look the same. It appends an `abort` naming
  the op, with `reason` `companion-review`, and leaves the decision to the person. Ops without the tag keep
  §6.7 as it is. Then the Mac classifies the op with the effect id:
  - **Took effect**: it is in a complete write of the op log, no `abort` names it, and the binder's recovery
    has finished. The outcome is `applied`.
  - **Proven not applied**: it is in no complete write of the op log (it was never logged, or only in a torn
    line, binder-v0 §6.9). The op log is written before the catalog is renamed, so the catalog never saw it.
    Only then does the Mac decide the recorded request again from section 9.5, because the item may have
    changed meanwhile, and replace the record's outcome and effect, with a new effect id, before applying.
  - **Unknown**: an `abort` names it (`companion-review` above, or binder-v0 §6.7 step 5's abort after an
    outside edit), so the write may or may not have taken effect. The Mac never applies anything again. The
    outcome becomes `conflict`, with a card for `(D, R)` that says what is known: the action, the item, and
    that a crash came in the middle, so the change may or may not be in the binder. The person checks and
    decides.

  `highest_seq` has not moved in the meantime. A logged op alone never counts as applied.
- **A note.** If a capture event with the effect id exists, the outcome is `applied`; otherwise the recorded
  event is written now.
- **A conflict.** The recorded card is created if no card for `(D, R)` exists.
- **A rejection.** Nothing to apply.

Then it commits as in step 3. If recovery cannot finish now (the binder is busy or needs attention), that is
a device failure (section 9.2): that device waits and backs off, and no other device is held up.

So a crash in the middle of a companion op never leads to a second application, nor to one the person
undid: whenever the catalog cannot prove which happened, the person decides.

A rejected request is journalled as one line naming the device id, the request id and a reason, never its
content: `invalid`, `stale-seq`, `not-shown`, `not-in-binder` or `future-version`; the daily cap bounds these
lines. A discarded request gets no line of its own: the Health line shows the diagnostics' counts (`bad-id`,
`not-active`, `too-large`, `unreadable`, `no-seq`).

### 9.7 Publishing

Every index, view, keys and outcomes object is sealed, then signed (section 4.5). A view is republished
whenever its binder changes, and at least once a day so its buckets stay current; the index is republished
with it.

**Snapshots and versions.** Each shown binder has a snapshot record, stored durably on the Mac: `reserved`,
the highest view version ever reserved for it (0 when the binder is turned on), and for each open item of the
last snapshot, the hash of its record and its `changed_in`. The **hash of an item's record** is SHA-256 of the
canonical JSON (binder-v0 §4.8) of the whole item object in `open_items[]`, every field included, unknown
fields too. It therefore covers what changes a request's meaning but is not published, such as `recurrence`,
`dismissed`, `expected_by` and `derived`, as well as everything the view shows, `status` and `due` included.
Any change to the item's record turns a request made before it into a conflict.

To publish a view, the Mac takes a snapshot under the binder's write lock, in one step:

1. Reserve the next version: `v = reserved + 1`.
2. Read the binder. For each open item, hash its record. If the hash differs from the one recorded for the
   item, or there is none, the item's `changed_in` becomes `v`; otherwise it keeps its recorded `changed_in`.
3. Build the view payload with `version` `v` from this reading.
4. Write the new `reserved`, hashes and `changed_in` values durably, as one atomic write, before releasing the
   lock.

A change made after step 2, even while version `v` is still uploading, makes the item's hash differ from the
recorded one, so a request against it is a conflict (section 9.5), and the next snapshot gives it a `changed_in`
above `v`. Versions are never reused: after a crash, `reserved` is already advanced, and an unfinished
snapshot is replaced by a new one with a higher version.

**Uploading views.** Version `v` of a binder is the object `views/{id}/{v}` (section 7.5). Each binder has an
**upload lock**, separate from its write lock. Holding it, the uploader:

1. records `v` as `uploading`, with its sealed and signed bytes, unless the binder is `removed` or a newer
   snapshot of it exists, in which case it uploads nothing;
2. sends the `PUT`, each attempt bounded to 60 seconds, retrying with the same bytes;
3. records `v` as `uploaded` on success; if it gives up, or a newer snapshot appeared before `v` was stored, it
   drops `v`'s record.

At start, a version still `uploading` is resumed with its recorded bytes if it is still its binder's newest
snapshot; otherwise its record is dropped. Only an uploader holding the lock sets `uploaded`, and an index names
only versions recorded as `uploaded`. Because each version has its own name, an upload that finishes late never
replaces a newer one.

**Removing a binder.** When the person turns "Show on my phone" off, the Mac records the binder as `removed`,
durably, holding both the binder's write lock and its upload lock, so no snapshot or upload of it can follow.
Then it publishes an index without it.

**Write-once uploads.** For every object the Mac uploads (keys, index, view and outcomes objects), it records
the exact sealed and signed bytes durably, under the object's name, before the first attempt. Every attempt,
including one after a restart, sends those bytes, so a retry of a stored object is answered `204` (section
7.5). The Mac does not read objects back. A `409` means the relay holds other bytes under a name only this Mac
writes, which the Mac never sent: the relay misbehaves. The Mac then reports it on its Health line and moves
on: an index or outcomes object is published again at the next revision, a view version's record is dropped and a
new snapshot taken, and a keys object, whose name is fixed by its epoch, is replaced by rotating again (section
4.4). Recorded bytes are dropped once their object is superseded and deleted.

**Publishing the index.** Under the **publish lock**, one lock for the whole companion:

1. Assign the next revision `r`, the last assigned plus one. Build the index at the current epoch, naming,
   for each shown binder, its highest version recorded as `uploaded` that is sealed at that epoch; a binder
   with none yet is left out until it has one. Seal and sign it. Record `r` and those bytes durably in one
   write. From now on `r` counts as possibly published. An index never names a version not recorded as
   `uploaded`, nor one of another epoch.
2. Upload the recorded bytes as `index/{r}`.
3. Record `r` as `published_revision`, and release the lock.

The index's revision never goes back, across rotations. A device that reads an index before its views are in
place retries (section 10.3).

**Cleanup.** Nothing is ever overwritten, so cleanup only deletes what nothing can use any more, always behind
a newer revision recorded as published. It runs after each publication and at the end of each drain, works
from listings of the relay (section 7.5), is idempotent, and simply repeats; a `404` on delete is success, and
an old object that reappears after a late write is deleted again at the next pass. Under the publish lock, and
each binder's upload lock while it works on that binder, it deletes:

- `index/{r'}` for every `r'` below `published_revision`;
- for a shown binder, `views/{id}/{w}` for every `w` below the version the last published index names for it,
  and nothing else: every other version is kept, named or not yet named, and nothing while no published index
  names the binder yet;
- for a binder recorded as `removed`, once an index without it is published, every version. The removed id is
  kept, and its prefix listed again at each pass, so a late write under it is deleted when it appears;
- `devices/{D}/keys/{e'}` for every `e'` below the current epoch, once an index at the current epoch is
  published, and every keys object of a removed device;
- `devices/{D}/outcomes/{r'}` for every `r'` below the device's last recorded published outcomes revision.

After a rotation (section 4.4), the old-epoch versions are below the newly named ones and go by the second
rule. A device that holds an older index and gets `404` for a view lists the index again and finds the newer
one.

**After a crash.** Any assigned revision may have reached the relay. At start, if the last assigned revision
is not recorded as published, the Mac, under the publish lock, uploads its recorded bytes again and records it
as published. (If that upload is refused, it publishes a fresh index at the next revision, as above.)

**The floor for a new device.** When the person confirms a pairing, the Mac takes the publish lock, finishes
any unfinished publication as just said, and gives the device `published_revision`, which is then the highest
revision it ever assigned; 0 only if it never assigned one. A publication that starts after gets a higher
revision, which the device accepts.

### 9.8 The device's side of requests

Several windows and tabs of one browser profile share one pairing. They coordinate through IndexedDB
transactions, all with strict durability (section 10.2), and one Web Lock. An outbox entry is
`{pairing generation, seq, R, type, state, sealed bytes}`, where the state is `queued` (never attempted),
`attempted` (a network attempt may have reached the relay), `sent`, `not sent` (only ever for an entry never
attempted), `conflict`, `rejected` or `unresolved`.

1. **Number and enqueue.** When the person acts, the window first checks the request against section 8
   (a note's length in characters and encoded bytes included) and tells the person if it is too long; nothing
   is numbered for a request that fails. In one read transaction it reads the pairing generation `G`, `D`, the
   relay origin, `Kd`, the epoch and `next_seq` (starting at 1). The action now belongs to `G` for good. It
   chooses a new random `R`, and pads and seals the request under `requests/{D}/{R}` with that `Kd` and epoch.
   Then, in one `readwrite` transaction over the state and the outbox, it reads the values again:
   - if `G`, `D` and the relay origin are unchanged and `next_seq` too, it writes `next_seq + 1` and adds the
     entry, state `queued`; the transaction commits both or neither;
   - if only `next_seq` changed (another window took the number), it writes nothing and seals again under the
     same `G`, with the new number and a new `R`;
   - if `G`, `D` or the relay origin changed (the pairing was removed or replaced), the action ends: it adds an
     entry of generation `G`, state `not sent`, without sealed bytes, and tells the person. It is never sealed
     for another pairing.

   An entry still `queued` 30 days after it was made becomes `not sent` and is never sent.

   (WebCrypto calls cannot run inside an IndexedDB transaction, which commits as soon as it waits on anything
   else, so sealing comes first.) The action shows as pending only once the transaction has completed.
2. **Send.** Sending happens in attempts. Each attempt takes the Web Lock `sprava-companion-send`
   (`navigator.locks.request`, exclusive), and holds it for that attempt only:
   1. In one read transaction, it reads the current pairing generation and the lowest-`seq` entry that is
      `queued` or `attempted`. If the entry's generation is not the current one, or there is none, or sending
      is suspended for the pairing (step 4 below), it sends nothing and releases the lock.
   2. If the entry is `queued`, it sets it to `attempted`, in one transaction with strict durability, and
      waits for it to complete. No byte leaves the device before that.
   3. It sends that entry once, bounded to 30 seconds, with an `AbortController` that a removal can trigger.
   4. It records the result in one transaction with strict durability that is **conditional**: it looks up the
      entry by pairing generation, `R` and `seq`, and changes it only if it still exists and is still
      `attempted`. An entry an outcome has already resolved (set to `conflict` or `rejected`, or removed after
      `applied`) is left as it is, and a removed entry is never recreated. On `201` or `409` the entry becomes
      `sent` with the time, and its sealed bytes are dropped. On any other `4xx` (`400`, `413` and so on) the
      relay's answer is not trusted to mean the request went nowhere: the entry becomes `unresolved` and is not
      retried, and a matching outcome can still resolve it. On `401` or `403` the app also suspends sending for
      the whole pairing and keeps every key and entry: the relay's answer is not proof that the device was
      removed. It tells the person that the relay no longer accepts this phone, and leaves removal to them
      (step 4). On `429`, `507`, any `5xx`, a timeout
      or a network error, it stays `attempted`. The window waits for the
      transaction to complete before it releases the lock.
   5. It releases the lock before waiting. Backoff (2 seconds, doubling up to 5 minutes) happens without the
      lock, and the next attempt takes it again and rechecks everything from step 1.

   A retry sends the same bytes, so the same `R` and `seq`. A browser without Web Locks is not supported.
3. **Outcomes.** On every refresh the device finds its newest outcomes object and accepts it as section 10.3
   says. An outcome resolves an entry that is `attempted`, `sent` or `unresolved`, belongs to the current
   pairing generation, and has the same `R` and the same `seq`; an outcome whose `seq` differs is ignored, and
   so is `unknown`, which leaves the entry `unresolved` ("your Mac no longer knows what became of this").
   `applied` removes the entry; `conflict` and `rejected` set its state, and the app shows it ("your Mac wants
   you to look at this", "your Mac refused this") until the person dismisses it. A `sent` or `attempted` entry
   with no outcome 30 days after its first attempt becomes `unresolved` and stays visible ("your Mac never
   confirmed this") until dismissed; an outcome that arrives later still resolves it. Until then the action
   shows as pending.
4. **Removing or replacing the pairing.** This happens only when the person asks. At the start the window
   reads, in one transaction, the pairing generation `G`, `D`, the token, `Kd` and the instance, and works on
   that pairing only:
   1. It seals a revocation (section 8.8) with that `Kd` and calls `DELETE /v0/devices/self` with that token,
      bounded to 30 seconds, so the device is revoked and the Mac rotates keys at its next drain. If the call
      fails, removal goes on locally, and the app tells the person to also remove this phone on the Mac.
   2. It asks any attempt in flight for generation `G` to stop, with a message naming `G` on the
      `BroadcastChannel` `sprava-companion`, which aborts that attempt's request.
   3. It takes the send lock, which an attempt holds for at most 30 seconds. In one transaction, and only if
      the installed pairing generation is still `G`, it deletes the token, the keys, `S`, the high-water marks
      and the pairing generation, and changes the entries of generation `G`: every one still `queued`, never
      attempted, becomes `not sent`; every one `attempted` or `sent` becomes `unresolved` ("may have reached
      your Mac"), because no outcome can arrive any more. If the installed generation is no longer `G`
      (another window removed it, and perhaps a new pairing is installed), it changes nothing.

   The app says how many actions were not sent and how many are unresolved. A new pairing has a new pairing
   generation, and `next_seq` starts again at 1.

### 9.9 Outcomes for the device

Each device record on the Mac holds `outcomes_changes`, a counter that the commit of each decision for that
device raises in the same durable write (section 9.6, step 3); `outcomes_built`, the counter value the last
published outcomes object was built from; and the outcomes revisions reserved and published. The device's
outcomes are **dirty** while `outcomes_changes` is above `outcomes_built`.

At start, and at the end of every drain, the Mac publishes the outcomes of every dirty device that is active
in its records. A revoked device has no outcome work: revoking it sets `outcomes_built` to `outcomes_changes`
and drops any reserved, unpublished revision and its bytes, in the same write that marks it revoked, so
nothing is ever built, published or retried for it without its `Kd`.

1. Read `outcomes_changes`, then build the payload (section 8.7) from that device's tombstones decided in the
   last 30 days, newest first, at most 2,000, padded (section 8.7), with the next revision, the last reserved
   plus one. Seal it with `Kd` (`e` = 0) and sign it.
2. Record that revision as reserved, with its bytes, durably in one write, before anything is uploaded.
3. Upload the recorded bytes as `devices/{D}/outcomes/{revision}`.
4. Record, in one durable write, the revision as published and `outcomes_built` as the counter value read in
   step 1. A decision committed meanwhile leaves the device dirty, so it is published at the next turn.

A crash anywhere leaves the device dirty. At the next start the Mac first uploads the recorded bytes of a
reserved revision not yet recorded as published, then publishes again if still dirty, at a revision above
every one reserved; so a committed outcome is always published eventually and a revision is never reused.
Only committed decisions appear, and each request appears with the outcome its tombstone holds, which never
changes; so an outcome the device sees as final is final. A request the relay expired or lost never
gets an outcome, and stays visibly unresolved on the device (section 9.8).

**A v0 limit.** A device's outcomes object holds at most 2,000 outcomes, covering 30 days. A device with more
decisions than that in 30 days (the daily cap allows up to 15,000) loses the oldest from its object, and the
phone actions they answer stay `unresolved`. Paging outcomes, or letting the device acknowledge what it has
seen, is a later option.

## 10. The web app

### 10.1 Hosting and trust

- The web app is built from this public repository by GitHub Actions, from a release tag, and published to
  GitHub Pages. The relay serves only the API, never the web app.
- A self-hoster may use that shared build or host the same build at an origin of their own; they then trust
  that host instead. Either way, the web app learns its relay's address from the pairing link (section 5.1).
- The web app's origin serves nothing else: every page at the same origin can use the keys stored there. A
  Pages site therefore uses a custom domain, or a `github.io` address that publishes no other site.
- GitHub Pages cannot set response headers, so the page carries its policy in a `<meta>` element:
  `Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:;
  connect-src https: http://localhost:*; manifest-src 'self'; worker-src 'self'; base-uri 'none';
  form-action 'none'`. `connect-src` cannot name the relay, which is learned at pairing. The app refuses to run
  inside a frame. No third-party scripts, and no analytics.
- The app shows its release version and the commit it was built from, so anyone can compare it with the
  repository.

### 10.2 What it stores

In IndexedDB: the pairing generation, the relay origin, `D`, the device token, `K`, its epoch, `Kd`, `S`, `P` with
its `expires_at` and the acknowledgement-pending flag, a reservation while a pairing is in progress, `next_seq`,
the outbox, the highest outcomes revision accepted, the accepted index (its sealed bytes, revision, epoch, and the
view version it requires for each binder), the highest view version accepted for each binder, and the last
accepted sealed views. `K`, `Kd` and every `Kb` are non-extractable CryptoKeys. Sealed objects are opened in
memory only.

**Durability.** Every `readwrite` transaction that writes pairing state, keys, `next_seq`, the outbox or a
high-water mark is opened with `{ durability: "strict" }`, and the window waits for its `complete` event
before it acts on it: before sending, before acknowledging a pairing, and before showing newly accepted data.
Browsers otherwise may report a transaction complete before it reaches the disk, and a power loss could then
bring back a used sequence number or a lower high-water mark.

**Accepting an object.** Validation needs WebCrypto, which cannot run inside an IndexedDB transaction, so a
window accepts an index, a view or a keys object in three steps:

1. **Read.** In one read transaction, read what validation depends on: the pairing generation, `D`, the epoch
   and `K`, the accepted
   index (revision, epoch, required versions), the view high-water marks, and `min_index_revision`.
2. **Validate** the object against that reading, outside any transaction (section 10.3).
3. **Commit.** In one `readwrite` transaction over the state and the stored objects, recheck every prerequisite
   step 2 used: the same pairing generation and `D`; the same epoch as in step 1; for an index, a revision not
   lower than the stored one or the floor; for a view, the same accepted index revision, which still lists this
   binder and names exactly this view's version, and a view high-water mark not above this view's version;
   for a keys object, a stored epoch that is still lower than the new one; for an outcomes object, a revision not
   lower than the stored one. If all still hold, write the object together with everything it moves forward (for
   an index, its revision, epoch and required versions; for a view, its high-water mark; for a keys object, `K`
   and the epoch, together; for outcomes, its revision and the states of the entries it resolves). If any changed,
   write nothing and start again at step 1; after three restarts in a row, wait for the next refresh.

Values only move forward, and an object is stored only with the marks that admitted it, so two windows
refreshing at once can never bring back an older value or show an object the current index forbids. `next_seq`
moves forward as section 9.8 says.

A browser profile holds one pairing, installed only as section 5.2 says: from a reservation that is still
current, with no pairing installed. A pairing link, for the same relay or another, is refused while one is
held; the person first removes this device's pairing in the app, which deletes everything above except the
outbox, whose entries change as section 9.8, step 4 says.

### 10.3 Accepting what the owner published

The device finds the newest index, keys object and outcomes object by listing their prefixes (`index/`,
`devices/{D}/keys/`, `devices/{D}/outcomes/`) and trying candidates newest first (section 7.5); views are
fetched by the exact name the index gives. Before anything else, it verifies the owner's signature on every
object (section 4.5); an unsigned or wrongly signed object is refused and never opened. Then it accepts:

- an **index** `index/{r}` that opens with `K` at the epoch it holds, is valid, and whose `revision` is not lower
  than the highest it accepted, nor than the pairing's `min_index_revision`. A lower revision is refused as a
  rollback. An index at a higher epoch makes the device read its keys first (section 4.4); a lower epoch is
  refused.
- a **view** fetched by the exact name the accepted index gives, `views/{id}/{view_version}`, that opens with
  the index's `key` for it at the index's epoch, is valid, and whose `version` equals that `view_version` and
  is not lower than the highest version it accepted for that binder. A `404` means a newer index exists: the
  device reads the index again.
- an **outcomes** object, outside the account-epoch rule (section 4.4): its `e` is exactly 0, its owner
  signature verifies, it opens with the device's `Kd` under its name `devices/{D}/outcomes/{r}`, it is valid
  (section 8.7), its padding included, and its `revision` is not lower than the highest it accepted. It is
  used as section 9.8, step 3 says.
- a **keys** object `devices/{D}/keys/{e}` as section 4.4 says.

Everything it accepts raises the stored high-water marks, in the commit transaction of section 10.2, before it is
shown. The app shows a view only while it matches the currently accepted index: same epoch, a binder the index
lists, and exactly the version the index names. A view that a newly accepted index outdates is hidden ("updating")
until a newer one is accepted. When an accepted index no longer lists a binder, the same commit transaction
deletes its cached views and its key. A refused object is never shown. Since only the owner can sign, no one else
can set a revision or version, and a refused object never moves a high-water mark.

### 10.4 How old the data is

The device shows when the owner last published (the accepted index's `generated_at`) and when it last
reached the relay. If the index is more than 26 hours old, it says so plainly ("Your Mac last published 2
days ago"): the relay can withhold updates, and the device cannot tell that apart from a Mac that is off.

## 11. What the relay can observe

Encryption hides content, not traffic. The relay, its host, the bucket and their logs can observe:

- **Object names, and so their kinds**: index revisions, the view versions of each shown binder (so how many
  binders are shown, under random ids, and how often each changes), and each device's keys epochs and outcomes
  revisions, with how often each is published and listed.
- **Sizes**: of each view (roughly how much each shown binder holds) and of the index. Requests are padded to
  multiples of 1 KiB (section 8), so a check-off, a follow-up and a note of a few sentences look the same; a long
  note shows its length to the nearest KiB, and so does a request whose item id is unusually long. A device's
  outcomes object is padded, so its size shows how many requests it decided in the last 30 days, and not how
  they were decided.
- **Timing**: when the owner publishes, which views change together and how often, when it drains, and when it
  rotates keys (every object is rewritten soon after a device is removed).
- **Which binder a request concerns.** A request that changes an item usually makes the Mac republish that
  binder's view soon after it drains. The relay can make this exact: it can hold back every request, release
  one at a quiet moment, and watch which view is rewritten next. v0 does not hide this. Rewriting every shown
  view on a fixed schedule, whether it changed or not, would hide it; that is a possible later option.
- **Devices**: their ids, how many there are, when each was paired, joined, activated, last seen and removed,
  which objects each one reads and when, and how many requests each sends and when.
- **Pairings**: when they are made, joined, confirmed or abandoned, and failed join and claim attempts.
- **Network**: the addresses and user agents of the Mac and of each device, unless a proxy hides them.

It cannot observe binder names, item titles or any other content, device labels (the hello is padded to
512 bytes), which item a request concerns, a request's type beyond what its padded size and its effect on
publishing show, the confirmation code, or any key. v0 pads requests and the hello, not the index, views or
keys objects.

## 12. What the relay logs

Method, endpoint pattern (never a concrete id, name or path), status, duration, and an hourly count per
device. Never a token, an id, a body, a setup code or a fragment.

## 13. Configuration

The relay reads only environment variables. None has a default that points anywhere.

| Variable | Meaning |
|---|---|
| `SPRAVA_INSTANCE` | A random id for this relay's data: 32 lowercase hex characters, as `openssl rand -hex 16` prints. Required. Every object the relay keeps lives under it (section 7.8); a new one means a fresh relay (section 6). |
| `SPRAVA_SETUP_CODE` | The one-time code the owner claims the relay with: 32 random bytes in standard base64, as `openssl rand -base64 32` prints (section 6). Required until claimed, ignored after. |
| `SPRAVA_WEB_ORIGIN` | The web app's origin, exactly, for example `https://companion.example.org`. Required. The only origin allowed to call the relay from a browser (section 7.7). |
| `SPRAVA_STORAGE` | `s3` or `fs:<absolute directory>` (development and tests). |
| `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET` | The bucket, for `s3`. The relay does not depend on conditional writes (section 6). |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | A key limited to that bucket. |
| `PORT` | The port to listen on (default 8080). |

The relay runs as one instance (section 7). It answers `404` at `/` and any path outside `/v0/`.

## 14. Test vectors

The first implementation to reach each case writes its inputs and outputs, as hex or b64, to
`companion/testdata/companion-v0-vectors.json`. The other implementation's tests must reproduce the same bytes.
A vector, once committed, changes only with the protocol version. The cases:

1. `b64`: encodings of 0, 1, 2, 3 and 32 bytes, and inputs that must be refused (padding, `+`, `/`, non-zero
   trailing bits).
2. `associated-data`: the exact bytes for each payload kind of section 8.
3. `seal-index`: `K` = bytes `00` to `1f`, nonce = bytes `00` to `0b`, name `index/1`, epoch 1, a fixed index
   payload: the exact sealed object bytes. The same for a view, a device keys payload and a request.
4. `open-fails`: the `seal-index` output opened under another name, another `kid`, another epoch, and with one
   bit of the tag flipped: each must fail.
5. `pairing-derivation`: fixed private keys `a` and `b` (raw 32 bytes; WebCrypto imports them as JWK `d`), a fixed
   `P` and a fixed `D`, and the same with `D` changed, which changes every derived value: `A`, `B`, `Z`, `W`, `Kd`
   and `code`, the confirmation code, and the sealed hello and key payloads with a fixed nonce.
6. `low-order-key`: `B` = 32 zero bytes must be refused by both sides.
7. `confirmation-code`: the formatting alone, from the 4 bytes of `code`:

   | `code` (hex) | Confirmation code |
   |---|---|
   | `00000000` | `000000` |
   | `0001e240` | `123456` |
   | `000f423f` | `999999` |
   | `000f4240` | `000000` |
   | `ffffffff` | `967295` |

8. `payload-validation`: for each payload, one valid example and one invalid example for each rule of section 8,
   padding included: a request of exactly 1,024 bytes, one of 1,025 bytes (invalid), one whose `pad` holds a
   tab (invalid), and a note that needs 2,048.
9. `token-hash`: the token made of bytes `00` to `1f` is `AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8`; its hash
   is `ea866a757e4c38babfa8127cbe9a409d3e1f93a00ff1488ff735fcf917afffd0`. (SHA-256 of the 32 decoded bytes,
   `630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd`, is the wrong reading.) The hash in uppercase
   hex must be refused as `owner_token_sha256`, and the token with `=` padding as a bearer value.
10. `signature`: the RFC 8032 §7.1 test 1 key, message and signature verify in both implementations. A signed
    index made by the Mac verifies in the web app; the same object fails when its name, `kid`, `e`, nonce, one
    byte of `c` or one bit of `s` changes, and when `s` is removed.
11. `strict-json`: texts every reader must refuse: a duplicate member (`{"a":1,"a":2}`), a duplicate after
    escapes (`{"a":1,"\u0061":2}`), a lone surrogate (`{"a":"\ud800"}`), malformed UTF-8 (the byte `c3`
    followed by `28`), a byte order mark, nesting 17 levels deep, and an over-limit body. And numbers: `-7` is a
    valid item id and an invalid `seq`; `0` is a valid epoch and an invalid item id; `-0`, `1.0`, `1e2`, `01`
    and 2^53 are invalid everywhere.
12. `serialization`: the exact bytes of a string holding `"`, `\`, `/`, each of U+0008, U+0009, U+000A,
    U+000C, U+000D, U+0001 and U+001F, `é` and an emoji, written as section 3.1 says, and its encoded size.
13. `limits`: labels of 40 `é` (80 encoded bytes) and of 40 four-byte emoji (160) are valid and pad to exactly
    512 bytes; a label of 41 characters, and any label holding U+0001 or U+007F, is invalid. A note of 10,000
    emoji (40,000 encoded bytes) is valid and seals within 64 KiB; a note of 10,001 characters is invalid.
14. `ids`: `"7"` and `7` are different item ids; `"é"` written as one scalar (U+00E9) and as two (`e` and
    U+0301) are different strings.
15. `epochs`: an outcomes object with `e` 0 is accepted by a device at epoch 3, and one with `e` 3 is refused;
    an index at the device's epoch is accepted, one below it is refused, one above it makes the device read
    its keys; a keys object one epoch below the device's is refused.
16. `outcomes-padding`: outcomes payloads of 0, 1 and 2,000 entries, each padded to `512 + 128 × n` bytes; the
    same entries with every outcome changed have the same length.
17. `tombstones`: a request replayed after its full decision record expired gets no new outcome; a skipped
    `seq` that arrives late gets `rejected`; one below `tombstone_floor` without a tombstone gets `unknown`.
18. `recovery`: a companion-tagged op whose catalog rename succeeded, then a crash before the snapshot update,
    then an outside edit that restores the exact earlier catalog (`H = b`, `S = b`): the op is not rolled
    forward, an `abort` with `companion-review` is appended, and the outcome is a conflict card. The same op
    never logged is decided again; an untagged op in the same state is rolled forward as binder-v0 §6.7 says.
19. `effects`: for each request type and each item status (`open` with and without `due`, `waiting`,
    `blocked`, closed as done, closed as dropped), the expected result of section 9.5: the op with its exact
    `args`, `applied` with no change, or a conflict. These are Mac-side cases; the web app uses them to decide
    which actions to offer.

## 15. Versioning

The path prefix `/v0/`, the `"v":0` of sealed objects, the `v0.` of the pairing link and the
`sprava-companion/v0` of associated data, signatures and key derivation change together. A relay serves one
protocol version; the owner reads `GET /v0/health` before anything else and says plainly when the versions differ.
