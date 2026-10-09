# Sprava companion relay

The relay is the small HTTP API between a person's Mac and their phone. It stores encrypted objects and
requests, checks tokens, and never reads anything: it holds no key that decrypts what it stores, and it serves
no web pages. The design is in [`docs/companion.md`](../../docs/companion.md); the protocol, which this code
follows, is [`docs/spec/companion-v0.md`](../../docs/spec/companion-v0.md). Every rule the code enforces cites
its section there.

One relay serves one person. Nothing in this code names a particular relay, domain or bucket: each person
deploys their own from the same code.

## Development

TypeScript on Node 26 or later, which runs `.ts` files directly; the only dependencies are the pinned
TypeScript compiler and Node's type definitions, used for checking.

```sh
cd companion/relay
npm ci
npm test        # type-checks, then runs the node:test suites
```

The git hooks run `companion/test.sh` for every commit that touches `companion/` (`scripts/git-hooks/suites.sh`).

The test vectors shared with the Mac and the web app are in
[`companion/testdata/companion-v0-vectors.json`](../testdata/companion-v0-vectors.json) (spec section 14).

## Running it locally

The relay reads only environment variables (spec section 13). For development it keeps its data in a local
folder instead of a bucket:

```sh
export SPRAVA_INSTANCE=$(openssl rand -hex 16)
export SPRAVA_SETUP_CODE=$(openssl rand -base64 32)
export SPRAVA_WEB_ORIGIN=http://localhost:5173      # where the web app is served from
export SPRAVA_STORAGE=fs:$HOME/sprava-relay-dev     # an absolute folder
npm start                                           # listens on PORT, 8080 by default
curl -s http://localhost:8080/v0/health
```

It refuses to start, naming the variable, when one is missing or malformed. It logs one JSON line per request
with the method, the endpoint pattern, the status and the duration, never a token, an id or a body (section 12).

## Deploying your own

A relay is one small container and one private S3-compatible bucket (DigitalOcean Spaces, Amazon S3,
Cloudflare R2, MinIO). It must run as **exactly one instance**: its rate limits, claim throttle and creation
lock live in its memory (spec sections 6 and 7), and two instances would break them. Serve it over HTTPS; plain
HTTP is only for `localhost`.

Hosts that redeploy by starting the new container before stopping the old one (App Platform does, with no
option to stop first) briefly run two. The relay guards against that itself (`src/lease.ts`): each process takes
a lease in the bucket, ranked above every earlier one, and checks before every write that no newer lease exists;
an older process that finds one stops writing (`503`) and exits. Every new process waits 50 seconds and checks
again before it reads its state or writes anything, so of two processes starting together only the higher one
goes on. During that wait it answers `/v0/health` and nothing else (`503` with `Retry-After`), so a start, a
restart or a deploy makes the relay unavailable for about a minute. Keep the health check on `/v0/health`, which
answers throughout. A write that lands after its process stopped cannot replace stored bytes either way: each
write-once object records its bytes' intent first (`src/store/store.ts`).

1. Make a private bucket and an access key limited to it. The store must be **strongly consistent**: a write,
   once completed, shows in every later read and listing (spec section 13). Amazon S3 promises this; with
   another S3-compatible store, check that its documentation does. The lease, the claims, the ordinal
   reservations and every create-if-absent check depend on it. A relay whose store does not show its own lease
   right after writing it refuses to start, and one whose lease disappears stops writing; neither can catch
   every lapse.
2. Generate the two values only you should know. Keep them out of any file in a repository:
   ```sh
   openssl rand -hex 16       # SPRAVA_INSTANCE
   openssl rand -base64 32    # SPRAVA_SETUP_CODE
   ```
3. Run the container built from `companion/relay/Dockerfile` with these variables:

   | Variable | Value |
   |---|---|
   | `SPRAVA_INSTANCE` | from step 2; every object lives under it |
   | `SPRAVA_SETUP_CODE` | from step 2; remove it once the Mac has claimed the relay |
   | `SPRAVA_WEB_ORIGIN` | the web app's origin, such as `https://companion.example.org` |
   | `SPRAVA_STORAGE` | `s3` |
   | `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET` | the bucket, such as `https://<region>.digitaloceanspaces.com` |
   | `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | the key from step 1 |
   | `PORT` | the port to listen on, 8080 by default |

4. Point the host's health check at `GET /v0/health`. It answers `200` with
   `{"protocol":0,"claimed":false,"instance":"..."}` until the Mac claims the relay.
5. In the Mac app, Settings › Phone: the relay's address and the setup code. The Mac claims the relay
   (`POST /v0/claim`, spec section 6) and `/v0/health` then says `"claimed":true`. From then on the relay
   ignores the setup code and refuses every other claim, even after a restart; remove `SPRAVA_SETUP_CODE` from
   the host's settings. Until it is claimed, the relay serves nothing but health and claim.

Wrong setup codes are answered `403`, and after five from one address within ten minutes, `429`. Behind a
proxy that hides client addresses (App Platform's included) every client shares one address, so the count is
in effect relay-wide; a correct code is never refused because of it.

Starting over means a new `SPRAVA_INSTANCE` and a new setup code; the old data stays behind under the old
prefix, which you may delete by hand. It is also the only way out when a claim was begun and its body lost: once
a claim's intent is written, the relay accepts no other claim (trade-off A below), and the Mac keeps its claim
body and resends it until the claim is confirmed (spec section 6).

**DigitalOcean App Platform**, as one example: [`deploy/digitalocean-app.yaml`](deploy/digitalocean-app.yaml)
is an app spec with placeholders. Copy it outside the repository, fill it in (or leave the values empty and set
them in the control panel, with the secrets as encrypted variables), and create the app with
`doctl apps create --spec <your copy>`. It builds the Dockerfile, runs one instance, and checks
`/v0/health`. The relay talks to Spaces path-style and does not rely on conditional writes, which Spaces
ignores (spec section 6).

## Crashes and late writes

A process can stop at any moment, and with an S3-compatible store a write it sent may land later, even after a
new process has started (spec section 6); so may a deletion. The relay holds to six invariants, and every
endpoint is checked against them:

1. **Every object is fixed by its first writer, or informative.** A write-once object never changes once
   written, and every writer of a name derives the same bytes, so a late write repeats them. Informative
   objects (`last_seen`) decide nothing.
2. **Nothing is acknowledged before it is durable and verified.** A write is confirmed by the store (on disk:
   the file and its folder synced) before the answer; a retry that finds the object already there makes it
   durable again before saying so; a record that cannot be read is an error, never taken for a missing one.
3. **Every decision a late write could change is fenced**: by the writer's lease rank, or by a name whose bytes
   every writer derives alike, or by an intent recorded before the write, so other bytes are refused while an
   earlier write's outcome is unknown.
4. **Every check-then-act runs under one lock**, the one its counterpart takes (a device's lock for anything
   a revocation must not overtake), in a single documented order.
5. **A name is never reused for other bytes, and a deletion is final and durable.** A name that has ever held a
   write-once object, or an intent, never takes different bytes. Deleting an object that could be written again
   first leaves a durable tombstone, which refuses every later write and makes every reader treat a copy that a
   late write brings back as deleted; a late deletion then only removes what is already dead. A deletion is
   acknowledged only once it is durable, a repeated one included.
6. **Every object the relay keeps is bounded by live data, with a stated bound.** Bookkeeping (intents,
   tombstones, reservations, markers, folders) is removed once nothing needs it, or covered by a floor that
   stands for everything below it; a folder left empty is removed.

**Accepted trade-offs.** These are settled; they follow from the invariants and are not defects:

- **A. A claim binds the slot for good.** A client's timeout cannot prove that a write it sent will never land, so
  a claim intent is never voided or deleted, by time or by lease rank. A claim's intent (`claims/{digest}`) and
  its owner record (`owner/{digest}`) are both named by the SHA-256 of the record. The binding claim is the
  lowest-named claim intent, and the owner is its record, when that exists. A claim, first try or retry, is
  acknowledged only when its own intent is the lowest at that moment, under the creation lock; a record of any
  other claim is never adopted, and that claim gets 409.

  The guarantee is that one claimer retrying always ends as the owner: the Mac keeps its claim body and resends it
  (spec section 6), and its claims all have one digest. Two different holders of the setup code racing a claim with
  delayed writes is outside the threat model, since the setup code is held by one person, and whoever holds it
  could simply claim first. In that race a later, lower claim can still become binding; the Mac then sees its owner
  token refused (401) and shows the relay as needing a reset, a new `SPRAVA_INSTANCE`. Nothing is silently lost.
  The same reset applies if the binding claim's holder never retries: claiming is a one-time setup.
- **B. A failed upload holds its prefix's floor until the owner deletes that revision.** Its intent keeps the name
  live, because the relay never declares an object deleted that the owner did not delete. Tombstones above it wait
  for the floor meanwhile. Only the owner uploads objects, and the Mac deletes every revision it assigned (spec
  section 9.7), so this growth is bounded by the owner's own behaviour; no device can cause it.

### Every endpoint against the six invariants

Every write-once object below goes through `writeOnce` (`src/store/store.ts`): it is acknowledged only once the
store confirmed it, a retry that finds it makes it durable first (invariant 2), and its intent fixes its bytes
before they are sent (invariant 3). Every write is also refused once a newer process holds the lease. The table
adds what is particular to each endpoint.

| Endpoint | What it writes | Fixed by (1, 3) | Under (4) |
|---|---|---|---|
| `GET /v0/health` | nothing | | |
| `POST /v0/claim` | `claims/{digest}`, then `owner/{digest}` | names are the record's SHA-256; the owner is the record of the lowest claim intent, and only that claim is acknowledged (trade-off A); a known owner never changes in memory | the claim queue, then the creation lock |
| `POST /v0/pairings` | `created.json` under a new random id | a new name | the device's lock, then the creation lock |
| `POST /v0/pairings/{P}/join` | a token marker, `record.json`, `joined.json` | the token's own name; a record every join writes alike; an earlier transcript's intent consumes the pairing | the device's lock, then the creation lock (device count) |
| `GET /v0/pairings/{P}` | an expired pairing's deletion | its tombstone `deleted` first, kept for good | the device's lock |
| `PUT /v0/pairings/{P}/key` | `active`, `key.sha256`, `key` | an empty marker; the key's hash | the device's lock, revocation checked there |
| `GET /v0/pairings/{P}/key`, `POST .../ack` | `ack` | an empty marker | the device's lock (guard), after the body |
| `DELETE /v0/pairings/{P}` | its tombstone, then deletions | a pairing with a tombstone reads as missing everywhere; a retry, the sweep and the start delete what is left | the device's lock |
| `GET /v0/devices` | a missing revocation marker | an empty marker | each device's lock |
| `DELETE /v0/devices/{D}` | `revoked`, then deletions | an empty marker, never deleted | the device's lock |
| `DELETE /v0/devices/self` | `revocation`, then `revoked` | the marker only once this revocation is the one stored | the device's lock (guard), after the body |
| `GET /v0/devices/{D}/revocation` | nothing | | |
| `PUT /v0/objects/{name}`, `DELETE` | the object; on deletion its marker `intents/objects/{name}/deleting`, its tombstone, then the object, then the prefix's floor | revision names; a deleted name, one below the floor, or one whose deletion has begun (its marker written, so a tombstone that lands late hides no upload acknowledged meanwhile) refuses every PUT with 410 (409 means other bytes are stored), and a copy brought back is never served or listed, and is deleted when met | the creation lock |
| `GET /v0/objects...` | nothing | | the device's lock (guard), so no revoked device reads |
| `POST /v0/requests/{R}` | `ordinals/{D}/{block}`, the request | a block holds one process's lease name; an ordinal is never given twice; 409 only when the stored copy is there and synced | the device's lock (guard), after the body |
| `GET /v0/requests/{D}...`, `DELETE` | a deletion: tombstone, copy, then intents; then the device's floor | a DELETE answers 204 only once the tombstone is durable, and finds the name in the bucket when memory lacks it, so a retry after any failure finishes the deletion, and a name with no copy, intent or tombstone is 204 with nothing written; the intents are the durable record of what is pending, so a missing copy stays listed across restarts; a copy brought back after deletion reads as deleted; the floor `floors/requests/{D}/{ordinal}`, raised to the lowest pending ordinal, covers every name below it, so tombstones below it are deleted and what deletion leaves stays bounded | the device's lock |

### The floor protocol

A floor, `floors/{scope}/{n}` (`src/store/store.ts`), stands for every name of its scope numbered below `n`: each
counts as deleted, so the tombstones, intents and copies below it can be deleted and stay bounded.

- **Who raises it, and when.** Only the relay, after a deletion and in the hourly sweep: a request floor
  (`requests/{D}`) under the device's lock, an object floor (`objects/{prefix}`) under the creation lock, the
  locks every write to those names takes.
- **To what.** Never above a name not deleted: the relay never retires an object on its own. A request floor
  rises to the device's lowest pending ordinal (or its next, with none pending). An object floor rises to the
  lowest uploaded name of the prefix (one with an upload's intent or a copy) that has no tombstone, or, with none,
  just above the highest uploaded name: every upload writes its intent first and only the floor removes it, so a
  copy the store has lost for a while, or an upload that failed, keeps its name live until the owner deletes it. A
  name never uploaded is passed only below an uploaded one, so deleting a name that never existed retires nothing
  else. A floor never exceeds the highest valid number (§3); that name's own tombstone then
  stays.
- **In what order.** The floor is raised in memory, then written durably, then the lower floors (never a higher
  one) and everything it covers are deleted. Every name it covers was deleted by the owner or never existed, so
  refusing them first loses nothing, and a cleanup step that fails leaves every live name live. A floor only ever rises: a reader merges what it reads with what it knows by taking the
  higher, so a read that finishes after a raise never lowers it.
- **What readers do.** A write checks the tombstone and the floor under the same lock as the raise, and refuses
  a deleted name (410 for an object, 503 for a request). A read takes the bytes first, then checks the tombstone,
  then the floor, so a tombstone deleted by a raise meanwhile is always covered by the floor it then sees. A copy
  that counts as deleted is deleted when met.

Each object prefix against it: `index/` and `views/{id}/` and `devices/{D}/outcomes/` hold revisions the owner
publishes in rising order and deletes from below once a newer one is named (spec section 9.7), so the floor only
covers what the owner retired; `devices/{D}/keys/` holds epochs, which only rise, and the floor covers epochs the
owner deleted. A PUT below its floor is 410: the owner never publishes below what it keeps. A removed device's
prefixes, floors included, go with it.

### What each kind of object is bounded by (invariant 6)

Live data is what the owner keeps published, the devices it keeps paired, the pairings open now and the
requests pending. Three kinds of marker are the stated exception: they outlive their device, pairing or binder,
one empty object each, because a late write could otherwise bring it back, and their number grows only with what
the owner itself makes (devices paired, pairings opened, binders shown).

| Object | Bound |
|---|---|
| `claims/{digest}`, `owner/{digest}` | one per claim sent with the setup code: only the person who deployed the relay makes them |
| `leases/{rank}-{id}` | one per process alive; a ready process deletes every lower one |
| `devices/{D}/record.json`, `tokens/`, `active`, `last_seen`, `revocation` | per device kept (at most 20 pending and active, plus self-revoked ones until the owner deletes them); deleted, intents included, with the device |
| `devices/{D}/revoked` (and its intent), `tombstones/devices/{D}/revocation` | **exception**: one each per device id the owner ever removed or abandoned |
| `pairings/{P}/` parts (and their intents) | per pairing open (at most 3, for 10 minutes); deleted with the pairing |
| `pairings/{P}/deleted` | **exception**: one per pairing the owner ever made |
| `objects/{name}` | what the owner keeps published; a late copy of a deleted name is deleted when met, and by the hourly sweep |
| `tombstones/objects/...`, `intents/objects/...` | per prefix, names at or above its floor: what is published, uploads in progress, deletions' markers, and the owner's failed uploads, which only the owner can make and which the Mac deletes (spec section 9.7), so no device can grow them, names deleted out of order above the lowest kept, and names the owner deleted above every uploaded one; the floor deletes everything below it |
| `floors/objects/{prefix}` | one per prefix in use: the index, each binder shown, each device kept; **exception**: a removed binder's views floor stays, one per binder ever shown (its id is never reused, so nothing new arrives under it, and a late copy is refused only by it). A removed device's go with it |
| `requests/{D}/`, `intents/requests/{D}/` | pending requests: at most 1,000 per device |
| `tombstones/requests/{D}/` | names deleted out of order above the device's floor: with its pending requests, at most 10,000 names per device, whatever the rate or the restarts (a device at the bound gets 507 until the Mac collects its oldest request) |
| `floors/requests/{D}/` | one per device kept; deleted with the device, as is everything of a revoked device here |
| `ordinals/{D}/{block}` (and their intents) | the blocks above the device's floor plus its highest, which a device kept always keeps (it says where the next process starts). Each process start that gives the device an ordinal reserves a fresh block, so while an old request stays pending the blocks number at most its pending span over 1,024 plus one per start since it was made; the request expires within 30 days, and every start takes the warm-up. All go with the device |
| folders (local store) | only those holding an object; a folder left empty is removed |

## Layout

- `src/main.ts`: reads the environment, opens the store, serves.
- `src/relay.ts`: the relay's shared state, what it checks before serving, and its routes.
- `src/lease.ts`: one writer at a time, even while a host runs two containers.
- `src/claim.ts`: claiming the relay (section 6).
- `src/devices.ts`: admitting device tokens, listing and revoking devices (sections 7.3, 7.4), and the lock
  order: every action of a device runs under that device's lock, its authorization checked again there; a
  device's lock comes before the creation lock, and code holding the creation lock never takes a device lock.
- `src/pairings.ts`: pairing a device: open, join, key, acknowledge, expire (section 7.3).
- `src/objects.ts`: what the owner publishes, immutable by name, and who may read it (section 7.5).
- `src/requests.ts`: each device's mailbox of sealed requests, with ordinals (sections 7.6, 7.8), taken from
  blocks reserved in the bucket so that no ordinal is ever given twice, even across a restart.
- `src/startup.ts`: the repairs and cleanups before serving (section 7.8).
- `src/layout.ts`: the names of what the relay keeps (section 7.8); `src/limits.ts`: in-memory counts.
- `src/http.ts`: routing, cross-origin rules (section 7.7), tokens and roles (7.1), body limits, errors.
- `src/log.ts`: structured logs without content (section 12).
- `src/encoding.ts`: b64, ids, tokens and their hashes, times (section 3).
- `src/json.ts`: the strict JSON reader and the writer (section 3.1).
- `src/config.ts`: the environment variables (section 13).
- `src/store/`: the storage interface, the write-once rule (section 7.8), and the local-folder and S3 backends
  (`s3.ts` signs with AWS Signature Version 4 using only `node:crypto`).
