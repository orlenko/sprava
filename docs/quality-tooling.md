# Shared quality tooling

This is a partial source setup for the shared
[Software Quality standard](https://github.com/orlenko/software-quality/blob/0124cfcdc345bd631e83ab6f776186893d3f155c/docs/development-standard.md).
It records the tool selection and inspection plan. It does not replace Sprava's
native gates, install a tool, enable command execution, or establish full adoption.
[AGENTS.md](../AGENTS.md) remains authoritative, including its review rubric,
review rounds and privacy rules. No pending review-policy change is adopted here.

## Immutable selection

| Component | Identity |
| --- | --- |
| Publisher | `orlenko/software-quality` |
| Core | `software-quality-0.1.2-root-alias.pyz`, policy `0.1`, schema `1` |
| Artifact build source | `db120201d3f38d1c6e444bc4d1ca9586c3d8eee0` (R2) |
| Artifact SHA-256 | `7b87b9c23fbaf43941729f8bb2b0e1969fbf6872b02d8dbd23e074714bc526b0` |
| `quality_launch.py` SHA-256 | `14d77ae4dd7a9fa69197f970fc7c98a716b65c1e7486ceb668b7b8f7a621aaf6` |
| `quality_trust.py` SHA-256 | `4c3ebc346b1428e1d226180ecbb05a249c90de48ae25cdc8438b89bb901f6c2e` |

The later shared source `0124cfcdc345bd631e83ab6f776186893d3f155c`
documents the rollout; it is not this archive's build source. There is no adapter
or source-review controller in this setup. Do not rebuild, select `latest`, or use
an older artifact merely because its version matches.

The committed lock selects the artifact, not its trusted bootstrap. Obtain the
existing immutable bytes through an authenticated maintainer route and compare
their hashes with the identities above before loading them. A checksum downloaded
beside an arbitrary archive cannot authenticate it. Verify archive inventory,
manifest source and member bytes against the pinned source as well.

## Inspection entry point

Use a reviewed, owner-approved interpreter and the two verified bootstrap files
together outside the target repository. Initial qualification uses native
CPython 3.14.7 on Darwin with isolated startup and site loading disabled (`-I -S`),
standard-library imports only, and the tool's actual nonreaping process-capability
probe. Python's version alone is insufficient. Never weaken the capability guard
or silently provision a global runtime to make it run.

Create new private, owned, mutually separate bootstrap, cache, state and evidence
directories outside the target and toolkit source. Keep one state root per target
for lock coordination. Do not reuse another session's directory or put raw reports
in the public repository. These are operator-supplied paths, not discovered from
target-side code:

```sh
PYTHON=/path/to/approved/python3
TOOLKIT=/path/to/verified/bootstrap
ARCHIVE=/path/to/verified/software-quality-0.1.2-root-alias.pyz
CACHE=/path/to/owned/cache
STATE=/path/to/owned/state
TARGET=/path/to/sprava

"$PYTHON" -I -S "$TOOLKIT/quality_launch.py" install \
  --artifact "$ARCHIVE" \
  --sha256 7b87b9c23fbaf43941729f8bb2b0e1969fbf6872b02d8dbd23e074714bc526b0 \
  --source db120201d3f38d1c6e444bc4d1ca9586c3d8eee0 --cache "$CACHE"

BASE=REPLACE_WITH_FULL_ACCEPTED_COMMIT
HEAD=REPLACE_WITH_FULL_SUBJECT_COMMIT
"$PYTHON" -I -S "$TOOLKIT/quality_launch.py" doctor \
  --repo "$TARGET" --base "$BASE" --head "$HEAD" \
  --identity orlenko/sprava --cache "$CACHE" --state "$STATE"
```

`install` writes only the selected private cache entry; it does not register a
plugin, contact a provider or install an application. `doctor` reads committed
source and repository status and writes private plan/context reports and locks.
It does not run target checks. Its expected result here is **incomplete**, exit 2.
Preserve that result, including any capability or input refusal; do not turn it
into a pass by suppressing the exit code.

Both config and lock come from the **accepted base**. This first setup must pass
the existing native source-integration gates before its commit can serve as that
base. Before integration, validate candidate JSON and metadata only; a branch
commit is not an accepted base. After integration, record exact base/head/tree,
config/lock and artifact hashes from `doctor`. An initial inspection may use the
same accepted commit for base and head; it is not evidence about a product change.

## Sprava gates and effects

| Requirement | Authoritative native route | Shared-runner limitation |
| --- | --- | --- |
| Staged content and filename privacy; staged package build | `scripts/git-hooks/pre-commit` on the real index | Git-free exports have no real index or private-token-list guarantee. Never fabricate an index or treat a skipped privacy scan as a pass. |
| Commit-message privacy | `scripts/git-hooks/commit-msg` | Runs on the actual message through the native hook. |
| Every new pushed commit; dependent tests, companion and hook suites when affected | `scripts/git-hooks/pre-push`, `suites.sh`, `scripts/affected-tests.sh` | Schema 1 cannot represent this conditional history/cache gate. |
| Branch size and target boundaries | `scripts/pr-check.sh` | Requires the actual Git graph and current main. |
| Local Astra and cloud review | `scripts/dev/review.sh`, native PR review and thread resolution under AGENTS.md | Both routes are required in config. No external attestation is supplied by this setup. |
| Current-main integration and full Swift suite when Swift inputs change | `scripts/merge-pr.sh` | Keep outside runner checks: it can merge remote state. Exact native cached passes and conditional skips retain their native meaning. |
| Product behavior, accessibility and release checks as applicable | Existing tests and `docs/manual-checks.md` | Source metadata and a runner verdict do not establish workflow or release evidence. |

The inspection plan declares the full `./scripts/test.sh` command, with execution
disabled (`trusted_local: false`, `isolation: unavailable`). It is not a replacement
for the other gates above. Even `--execute-trusted` cannot enable checks under this
config. Changing those controls requires separate review and exact command,
dependency, import/startup and effects approval. Unknown code needs actual
containment; a worktree or disposable snapshot is not containment.

The native Swift script uses invented temporary fixtures, overrides the support
and registry locations, and puts backup keys in a temporary file. It builds Swift
products, starts tests and helper processes, and writes an uncapped temporary test
log. The shared runner's capture limit does not bound that native log. A fresh HOME
or environment does not isolate the platform Keychain, other host files or network.
There is no new permission for credential/private-data access, disclosure, provider
calls or spend. Native hooks still use their real privacy configuration.

The core's 600-second ceiling stays in place. Full tests can exceed it. A timeout,
missing fixture tool, missing required review or unsupported boundary is incomplete;
do not substitute a filtered suite, extend the core bound or label a subset a full
gate. These config/docs-only files do not trigger native Swift builds or suites
under the existing path-based hooks and merge script; report that as a conditional
skip, not a newly executed full-suite pass.

## Review evidence and adoption status

The two `boundary` objects declare **requirements**, not observations or granted
permissions. A successful native Astra/cloud review alone does not prove enforced
tracked-source-only access, independence, actual disclosure or every recorded-v1
field. Keep missing controls and envelopes incomplete. Never manufacture an
attestation, silently weaken those requirements or use a new live reviewer API.
Only public tracked source is in scope; no binder, profile, credential, private
media or private output is approved for review or upload by this setup.

Report stages separately: source configured, exact tooling installed, metadata
inspected, checks executed, reviews evidenced, and full adoption verified. This
source change establishes only the first stage after native integration. Local
installation or `doctor` evidence must identify their own exact pins and subject.
Execution containment, full-suite timing, all native/manual gate representation
and recorded-review enforcement remain gaps. Missing required evidence cannot
yield verified full adoption, regardless of a command's exit status.
