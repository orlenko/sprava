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

## Layout

- `src/encoding.ts`: b64, ids, tokens and their hashes, times (spec section 3).
- `src/json.ts`: the strict JSON reader and the writer (section 3.1).
- `src/config.ts`: the environment variables (section 13).
- `src/store/`: the storage interface, the write-once rule (section 7.8) and the backends.
