#!/bin/sh
# Where each open PR stands in the gate (AGENTS.md, step 4):  ./scripts/dev/status.sh
# Per PR: number, branch, base, the cloud review's last state and the commit it saw, unresolved threads, whether
# the head contains the current main, and the title.
set -eu
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
git fetch -q origin
printf '%-5s %-34s %-24s %-22s %-6s %-5s %s\n' PR BRANCH BASE CLOUD OPEN MAIN TITLE
gh pr list --state open --limit 100 --json number,headRefName,baseRefName,headRefOid,title \
    --jq '.[] | "\(.number)\t\(.headRefName)\t\(.baseRefName)\t\(.headRefOid)\t\(.title)"' |
while IFS="$(printf '\t')" read -r n head base oid title; do
    cloud=$(gh api "repos/$repo/issues/$n/comments" --jq '.[] | select(.user.login | test("codex")) | .body' 2>/dev/null |
        grep -E '^\| 📝' | sed -E 's/<relative-time[^>]*>[^<]*<\/relative-time>//; s/ since//' |
        awk -F'|' '{ gsub(/[*📝 `]/, "", $3); gsub(/[` ]/, "", $4); print $3 "@" substr($4, 1, 7) }' | tail -1)
    open=$(gh api graphql --paginate -f query='query($n:Int!,$o:String!,$r:String!,$endCursor:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}' \
        -F n="$n" -f o="${repo%/*}" -f r="${repo#*/}" --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length' |
        awk '{ s += $1 } END { print s }') || open='?'
    git merge-base --is-ancestor origin/main "$oid" 2>/dev/null && main=yes || main=no
    printf '%-5s %-34s %-24s %-22s %-6s %-5s %s\n' "#$n" "$head" "$base" "${cloud:--}" "$open" "$main" "$title" | cut -c1-170
done
