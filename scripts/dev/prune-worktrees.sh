#!/bin/sh
# Lists the worktrees under .claude/worktrees that hold nothing unmerged, and removes them with --apply:
#   ./scripts/dev/prune-worktrees.sh [--apply]
# A worktree goes when it has no uncommitted, untracked or ignored files other than build products (.build/, .swiftpm/,
# build/, .DS_Store; git's own removal check does not look at ignored files, so this one does) and its HEAD is already in origin/main or in one of
# origin's branches (so nothing in it exists only there). Its local branch is deleted only when merged into
# origin/main. The main checkout and anything outside its .claude/worktrees are never touched; it works the same
# from the main checkout or from any worktree.
set -eu
apply=0; [ "${1:-}" = --apply ] && apply=1
top=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
git fetch -q --prune origin
git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}' | while read -r wt; do
    case "$wt" in "$top"/.claude/worktrees/*) ;; *) continue ;; esac
    if ! changes=$(git -C "$wt" status --porcelain --untracked-files=normal --ignored 2>/dev/null); then echo "keep  $wt (status failed)"; continue; fi
    if [ -n "$(printf '%s\n' "$changes" | grep -vE '^!! (\.build/|\.swiftpm/|build/|(.*/)?\.DS_Store)$' | grep -v '^$')" ]; then
        echo "keep  $wt (uncommitted, untracked or ignored files)"; continue
    fi
    head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || continue
    branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    if git merge-base --is-ancestor "$head" origin/main 2>/dev/null || [ -n "$(git branch -r --contains "$head" 2>/dev/null)" ]; then
        echo "prune $wt${branch:+ ($branch)}"
        if [ "$apply" = 1 ]; then
            git worktree remove "$wt" || { echo "keep  $wt (git refused to remove it)"; continue; }
            [ -n "$branch" ] && git merge-base --is-ancestor "$branch" origin/main && git branch -q -D "$branch" || true
        fi
    else
        echo "keep  $wt (commits not on origin)"
    fi
done
[ "$apply" = 1 ] || echo "(dry run; --apply removes the worktrees marked prune)"
