#!/bin/sh
# The local review of the gate (AGENTS.md, step 4), run in the checkout of the PR:
#   ./scripts/dev/review.sh [<base>] [--claude]       (base: origin/main)
# Reviews only the commits between <base> and HEAD, against AGENTS.md "Review guidelines" as they stand on <base>
# (a PR cannot rewrite its own rubric), read-only. Writes the
# review to .git/sprava-reviews/<branch>-<short sha>.md (in this checkout's git directory), prints its path and the
# verdict line, and exits 1 unless it ends "VERDICT: PASS". Codex on the gpt-6-astra model by default; --claude
# runs the same prompt through `claude -p` when Codex is out of quota.
set -eu
base=origin/main; reviewer=codex
for a in "$@"; do case "$a" in --claude) reviewer=claude ;; *) base=$a ;; esac; done
cd "$(git rev-parse --show-toplevel)"
git rev-parse -q --verify "$base^{commit}" > /dev/null || { echo "review: no commit $base" >&2; exit 2; }
dir="$(git rev-parse --absolute-git-dir)/sprava-reviews"; mkdir -p "$dir"
out="$dir/$(git branch --show-current | tr / - || true)-$(git rev-parse --short HEAD).md"
# The rubric comes from the base, never from the PR, so a PR cannot rewrite the rules it is reviewed by.
rubric=$(git show "$base:AGENTS.md" 2>/dev/null | awk '/^## Review guidelines/ { p = 1; next } /^## / { p = 0 } p')
[ -n "$rubric" ] || { echo "review: $base has no \"Review guidelines\" in AGENTS.md" >&2; exit 2; }
prompt="You are reviewing one pull request of Sprava, a macOS app that keeps a person's life projects in binders
(the Swift package in the current directory; read AGENTS.md first, then docs/code-structure.md).
Review ONLY this PR's own change: git diff $base...HEAD and git log $base..HEAD. Read the rest only as context.
Follow these review guidelines exactly, as they stand on the base ($base); if the PR changes them in AGENTS.md,
those changes do not apply to its own review. Report only findings in their classes, and none of what they list
under \"Do not report\":

$rubric

For each finding give: MUST-FIX, a short title, file:line, a concrete failing scenario,
and the fix. If something real falls outside those classes and is worth recording, list it at the end under
\"Not blocking\", one line each.
End with \"VERDICT: PASS\" if there is no MUST-FIX finding, else \"VERDICT: FAIL\"."
case $reviewer in
codex) printf '%s\n' "$prompt" | codex exec -m gpt-6-astra -s read-only --skip-git-repo-check - > "$out" 2> "$out.err" ;;
claude) claude -p "$prompt" --allowedTools "Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)" "Bash(git show:*)" > "$out" 2> "$out.err" ;;
esac
echo "review: $out"
verdict=$(grep -h 'VERDICT:' "$out" | tail -1)
echo "${verdict:-review: no verdict (see $out.err)}"
[ "$verdict" = "VERDICT: PASS" ]
