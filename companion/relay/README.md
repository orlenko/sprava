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
an older process that finds one stops writing (`503`) and exits. A process that finds an earlier lease waits 50
seconds before it reads its state or writes anything, so whatever the old one began has ended. During that wait
it answers `/v0/health` and nothing else (`503` with `Retry-After`), so a restart or a deploy makes the relay
unavailable for about a minute. Keep the health check on `/v0/health`, which answers throughout.

1. Make a private bucket and an access key limited to it.
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
5. In the Mac app, Settings › Phone: the relay's address and the setup code.

Starting over means a new `SPRAVA_INSTANCE` and a new setup code; the old data stays behind under the old
prefix, which you may delete by hand.

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

## Layout

- `src/main.ts`: reads the environment, opens the store, serves.
- `src/relay.ts`: the relay's shared state, what it checks before serving, and its routes.
- `src/lease.ts`: one writer at a time, even while a host runs two containers.
- `src/http.ts`: routing, cross-origin rules (section 7.7), tokens and roles (7.1), body limits, errors.
- `src/log.ts`: structured logs without content (section 12).
- `src/encoding.ts`: b64, ids, tokens and their hashes, times (section 3).
- `src/json.ts`: the strict JSON reader and the writer (section 3.1).
- `src/config.ts`: the environment variables (section 13).
- `src/store/`: the storage interface, the write-once rule (section 7.8), and the local-folder and S3 backends
  (`s3.ts` signs with AWS Signature Version 4 using only `node:crypto`).
