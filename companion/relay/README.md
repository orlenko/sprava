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

## Crashes and late writes

A process can stop at any moment, and with an S3-compatible store a write it sent may land later, even after a
new process has started (spec section 6). The relay holds to four invariants, and every endpoint is checked
against them:

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

## Layout

- `src/encoding.ts`: b64, ids, tokens and their hashes, times (spec section 3).
- `src/json.ts`: the strict JSON reader and the writer (section 3.1).
- `src/config.ts`: the environment variables (section 13).
- `src/store/`: the storage interface, the write-once rule (section 7.8) and the backends.
