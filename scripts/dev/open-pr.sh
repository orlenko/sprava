#!/bin/sh
# Opens a PR for the current branch (or <branch>) against <base> (default main):
#   ./scripts/dev/open-pr.sh [<branch> [<base>]]
# The title is the first commit's subject; the body is the shape line of scripts/pr-check.sh measured against the
# base, the commit messages without their trailers, a note when the PR is stacked on another branch, and the
# attribution line. The branch must be pushed. Prints the PR's URL.
set -eu
cd "$(git rev-parse --show-toplevel)"
b=${1:-$(git branch --show-current)}; base=${2:-main}
git fetch -q origin
range="origin/$base..origin/$b"
shape=$(SPRAVA_MAIN_REF="origin/$base" ./scripts/pr-check.sh "origin/$b" 2>/dev/null | head -1 || true)
title=$(git log --reverse --format=%s "$range" | head -1)
[ -n "$title" ] || { echo "open-pr: origin/$b has no commits beyond origin/$base" >&2; exit 1; }
body=$( [ -n "$shape" ] && printf '`%s`\n\n' "$shape"
        git log --reverse --format='%B' "$range" | grep -v '^Co-Authored-By:'
        [ "$base" = main ] || printf '\nStacked on `%s`; review only this PR'"'"'s own commits.\n' "$base"
        printf '\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' )
gh pr create --base "$base" --head "$b" --title "$title" --body "$body"
