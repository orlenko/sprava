#!/bin/sh
# The last step of the gate (AGENTS.md, step 4):  ./scripts/merge-pr.sh <PR number>
# Refuses a PR that is not open against main, whose tip does not contain the current origin/main (so the tree
# tested is the tree merged; rebase first), or that has review threads left unresolved. Then runs the whole Swift
# suite once on the tip, in the hooks' kept worktree (skipped when that tree already passed), checks main again
# (a merge that landed during the run means a rebase), and merges with a merge commit, only if the tip has not
# moved meanwhile.
set -eu
[ $# -eq 1 ] || { echo "usage: scripts/merge-pr.sh <PR number>" >&2; exit 2; }
n=$1
cd "$(git rev-parse --show-toplevel)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
hook_dir="$PWD/scripts/git-hooks"
work=$(mktemp -d "${TMPDIR:-/tmp}/sprava-merge.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "$1" >&2; echo "merge-pr: #$n was not merged" >&2; exit 1; }
for lib in lock.sh suites.sh; do . "$hook_dir/$lib"; done

info=$(gh pr view "$n" --json state,baseRefName,headRefOid --jq '"\(.state) \(.baseRefName) \(.headRefOid)"') \
    || fail "merge-pr: cannot read PR #$n"
state=${info%% *}; rest=${info#* }; base=${rest%% *}; head=${rest#* }
[ "$state" = OPEN ] || fail "merge-pr: #$n is $state"
[ "$base" = main ] || fail "merge-pr: #$n is based on $base; retarget it to main once its base has merged"
git fetch -q origin "$head" main || fail "merge-pr: cannot fetch #$n"
git merge-base --is-ancestor origin/main "$head" || fail "merge-pr: #$n does not contain the current main; rebase it and push"
open=$(gh api graphql --paginate -f query='query($n:Int!,$endCursor:String){repository(owner:"orlenko",name:"sprava"){pullRequest(number:$n){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}' \
    -F n="$n" --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length') \
    || fail "merge-pr: cannot read the review threads of #$n"
open=$(echo "$open" | awk '{ s += $1 } END { print s + 0 }')
[ "$open" -eq 0 ] || fail "merge-pr: #$n has $open review thread(s) unresolved"

# Swift code changed anywhere in the PR: the whole suite on its tip.
git diff --name-only "origin/main...$head" > "$work/changed"
if grep -qE '^(Sources|Tests|Resources)/|^Package\.(swift|resolved)$|^scripts/test\.sh$|\.swift$' "$work/changed"; then
    test_full "$head" merge-pr
else
    echo "merge-pr: #$n changes no Swift code" >&2
fi
git fetch -q origin main || fail "merge-pr: cannot fetch main"
git merge-base --is-ancestor origin/main "$head" || fail "merge-pr: main moved while the suite ran; rebase #$n and push"
gh pr merge "$n" --merge --match-head-commit "$head" || fail "merge-pr: GitHub refused the merge"
echo "merge-pr: #$n merged" >&2
