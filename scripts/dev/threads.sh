#!/bin/sh
# The PR's review threads (AGENTS.md, step 4):
#   ./scripts/dev/threads.sh list <pr>                        unresolved threads: comment id, place, text
#   ./scripts/dev/threads.sh reply <pr> <comment id> <text>   answers and resolves the thread
#   ./scripts/dev/threads.sh file <pr> <comment id> <title>   records the finding in a new issue, answers with
#                                                             its link and resolves the thread (non-blocking findings)
set -eu
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
owner=${repo%/*}; name=${repo#*/}
threads() {    # <pr>: thread id, first comment id, resolved, path, line, body as JSON lines
    gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{databaseId path line body url}}}}}}}' \
        -f o="$owner" -f r="$name" -F n="$1" --jq '.data.repository.pullRequest.reviewThreads.nodes[] | {id, isResolved, c: .comments.nodes[0]}'
}
resolve() {    # <pr> <comment id> <reply text>
    gh api -X POST "repos/$repo/pulls/$1/comments/$2/replies" -f body="$3" --jq .html_url
    thread=$(threads "$1" | jq -r --argjson c "$2" 'select(.c.databaseId == $c) | .id')
    [ -n "$thread" ] && gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -f t="$thread" > /dev/null
}
case "${1:-}" in
list) threads "$2" | jq -r 'select(.isResolved | not) | "---- \(.c.databaseId) \(.c.path):\(.c.line)\n\(.c.body)\n"' ;;
reply) resolve "$2" "$3" "$4" ;;
file)
    body=$(threads "$2" | jq -r --argjson c "$3" 'select(.c.databaseId == $c) | "From the review of #'"$2"' (\(.c.url)), not blocking under AGENTS.md \"Review guidelines\":\n\n\(.c.body)"')
    [ -n "$body" ] || { echo "threads: no comment $3 on #$2" >&2; exit 1; }
    issue=$(gh issue create --title "$4" --body "$(printf '%s\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)' "$body")")
    resolve "$2" "$3" "Not blocking under AGENTS.md \"Review guidelines\"; recorded as $issue." ;;
*) sed -n '2,6p' "$0" >&2; exit 2 ;;
esac
