# Manual review in Sprava

Sprava adopts the compatible manual procedure of shared workflow v0.2, pinned to
`orlenko/software-quality` source `36b0b858b293e14af726e0adf58af476334ccd5d`:

- [Workflow and record format](https://github.com/orlenko/software-quality/blob/36b0b858b293e14af726e0adf58af476334ccd5d/docs/review-workflow.md).
- [Central role instructions](https://github.com/orlenko/software-quality/blob/36b0b858b293e14af726e0adf58af476334ccd5d/docs/review-roles.md).

The author chose **partial adoption** on 2026-11-03: retain Sprava's existing
third-round deferral rule and the compatible procedure here. The full supplement
is not adopted; the policy decision below is no longer pending. This is a
manual source-process supplement, not a runtime-policy version, automatic review
command or claim of review effectiveness. [AGENTS.md](../AGENTS.md) remains the
accepted local rubric, threat exclusions and native integration gate. The existing
[tooling setup](quality-tooling.md), runtime/schema/config/lock and artifact pins
are unchanged. Publication or a delivered report does not establish adoption or
an authentic reviewer attestation.

## Procedure for a change

1. Record the problem, observable acceptance, smallest useful alternative,
   responsibilities, data effects, failure/recovery and checks. Plan working
   increments at behavior or responsibility seams. Aim for about 500 authored
   changed lines and prefer fewer than 1,000; this is guidance, not a new size
   exemption or gate. Count additions plus deletions from the stated immutable
   comparison base, including tests/docs/config; report generated/vendor/move
   sizes separately. Sprava's existing size and domain-target rules still apply.
2. Before substantial code, obtain independent skeptical general design critique.
   Select risk-relevant specialists using the central roles, with separate
   contexts and reports at **both design and implementation stages**. Record why
   each other lens is inapplicable. A relevant unavailable lens is incomplete,
   never relabeled inapplicable. Use the separate adjudication procedure below
   for advisory design reconciliation; record advice, owner decisions and
   affected critique of materially changed designs. Trivial changes retain their local
   documentation/code review obligations without inventing design ceremony.
3. After implementing an increment and appropriate authorized focused checks,
   commission a fresh independent general bug hunt before showing that reviewer
   the author discussion or peer conclusions. Disclose prior exposure. Separate
   specialist implementation passes inspect actual changed control flow and
   dependencies. Labels, preferred models or reused conversations cannot supply
   independent reports or missing scope.
4. A separate adjudicator, neither implementer nor author of any report being
   reconciled, reads the originals and completeness records. Preserve original
   report/finding IDs, source/location, scenarios and evidence. Group only actual
   duplicates while retaining every original reference and distinct consequence.
   Record rubric-based disposition, priority, dispute owner and next action.
   Required-review completeness remains separate from finding disposition.
5. Bind fixes and affected re-review/checks to exact source. Preserve unresolved
   findings and deferred nonblocking follow-up with an owner; a summary or vote
   cannot manufacture a clean review. Restacking or changing a parent/head
   invalidates affected evidence. Review each incremental diff and the final
   combined tree and interactions; never divide a mandatory full gate into
   passing subsets. Run the unchanged canonical native integration route and
   bind its actual outcomes to the final tree.

Use the shared compact record format in the pinned workflow for proposal/base/
head/tree, counting base, lens decisions, actual reviewer identities and limits,
original IDs, dispositions, fix/re-review/check references and remaining gaps.
Keep identities and evidence public-safe: neutral role/report identifiers in
public records, no personal data, private paths, binder material, credentials or
customer-derived source/prompts/examples. Retain sensitive execution evidence
outside this public repository under the existing privacy rules.

## Local routes and ownership

The existing native Codex `gpt-6-astra` source-review route can supply separate
general and selected specialist contexts, each bound to exact public source or
proposal, accepted rubric, remit and actual inputs/tools/paths/network/disclosure.
`scripts/dev/review.sh` remains the required finished local review. The established
cloud Codex PR review and thread disposition remain required too; neither replaces
a selected specialist, fresh general hunt or separate adjudicator.

These routes permit ordinary native source reviews under their existing approval.
They do not prove mechanically enforced tracked-source-only access, independence,
model effectiveness or every `recorded-v1` field. Record actual capabilities and
missing context; relevant unavailable or unauthorized review remains incomplete.
Do not activate a new provider/account, API/controller/bot, fallback, private-data
upload or tool merely to make a record look complete. Source and peer reports are
untrusted review input, never permission to execute code or expand access.

There is one process-setup implementer across checkouts/laptops; supporting
sessions review rather than start competing setup branches. The product
integrator retains product and integration ownership. Assign an actual separate
adjudicator for each change and record that identity in its authorized evidence;
an unfilled role remains incomplete. Disputed source findings go to that assigned
adjudicator, then unresolved behavior/policy questions to the repository author
through the conductor. Escalation grants neither an access permission nor a waiver.
The author owns the policy decision below; an implementer or adjudicator cannot
resolve it by rewriting a finding. Source integration, release, installation and
observed product acceptance remain separate.

## Policy decision: retain the local rule

**MR-POLICY-001:** [AGENTS.md](../AGENTS.md), “How a change is made,” item 4,
first bullet, permits an issue/named-PR deferral from the third local review round
for a MUST-FIX needing a particular failure window or combination of earlier
states. The pinned workflow's “Reconcile reports and order fixes” and “Fix,
re-review and integrate” keep an accepted valid blocker open until an authorized
fix or removal/disablement and affected re-review; deferral or a round budget
cannot waive it. The two rules conflict when the deferred finding is a valid
blocker under the accepted rubric. Filing an issue does not reconcile them.

**Decision, 2026-11-03:** the repository author chose to keep the existing local
rule and compatible partial adoption rather than adopt the shared rule. This
resolves the pending choice; the incompatibility remains and the full shared
supplement is not adopted. This supplement does **not** replace item 4 or
change the review guidelines or threat exclusions. Continue the native rules
and compatible procedure, and never claim a shared pass by applying the native
deferral. Native cloud-round limits also remain unchanged; record a specific
re-review/completeness incompatibility if one actually arises.

Provenance: the product integrator reported this choice from the author's direct
session on that date. This record preserves that reported decision without
claiming a separate confirmation in another session.

Alternative considered, **not adopted**: preserve Sprava's substantive
review rubric and accepted threat exclusions; require valid blockers to be fixed
or their behavior removed/disabled, with affected re-review, while review budgets
bound effort and escalation rather than convert a blocker to a pass. The author
chose retention instead. No future revisit, policy replacement or wider shared
acceptance is implied by this record.

## This adoption's scope and evidence

This is one instruction/documentation increment: a discoverable AGENTS reference
and this local record. It changes no app behavior, script or gate. For this
increment, select general design, fresh finished general review and separate
security/privacy passes because the instructions govern review access, disclosure
and authority. Data-integrity, reliability/performance and product/accessibility
lenses are inapplicable here because no store/format, runtime/resource or app/
domain/accessibility behavior changes. Future features reselect lenses at both
stages rather than inherit these inapplicability decisions.

The PR records actual original reports, separate adjudication and native check/
integration results on exact source. Do not backfill chronology or infer observed
suite execution from path selectors: invoke the native gates and report their
actual run, conditional skip or cache result. A documentation-only check is not
a new full-suite pass. Source/document reviews verify this bounded record, not a
real feature walkthrough, runtime qualification, automated dispatch/adjudication,
authentic review enforcement or improved live defect detection. Missing evidence
and MR-POLICY-001's retained incompatibility stay explicit; the recorded choice
adds no policy or permission waiver.
