#!/bin/sh
# Tests for prune-worktrees.sh in a throwaway repository: a pushed, clean worktree goes; one holding uncommitted,
# untracked or ignored handwritten files, or commits not on origin, stays. Run: ./scripts/dev/test-prune.sh
set -eu
dev=$(cd "$(dirname "$0")" && pwd -P)
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
root=$(mktemp -d "${TMPDIR:-/tmp}/sprava-prune-tests.XXXXXX")
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q --bare "$root/remote.git"
git init -q -b main "$root/repo" && cd "$root/repo"
git config user.name "Test Person"; git config user.email "test@example.invalid"; git config commit.gpgsign false
printf '.build/\n.claude/\nnotes/\n' > .gitignore; echo one > a.txt
git add -A && git commit -q -m Start && git remote add origin "$root/remote.git" && git push -q origin main
for w in clean built edited untracked ignored local; do git worktree add -q -b "$w" ".claude/worktrees/$w" main; done
mkdir .claude/worktrees/built/.build && echo object > .claude/worktrees/built/.build/a.o
echo two >> .claude/worktrees/edited/a.txt
echo new > .claude/worktrees/untracked/b.txt
mkdir .claude/worktrees/ignored/notes && echo "a plan written by hand" > .claude/worktrees/ignored/notes/plan.md
(cd .claude/worktrees/local && echo three >> a.txt && git commit -q -am Local)
"$dev/prune-worktrees.sh" --apply > "$root/out" 2>&1
passed=0; failed=0
check() { if [ -d ".claude/worktrees/$1" ]; then now=kept; else now=gone; fi; if [ "$now" = "$2" ]; then
    passed=$((passed + 1)); echo "ok   - $1: $2"; else failed=$((failed + 1)); echo "FAIL - $1: not $2"; sed 's/^/       /' "$root/out"; fi; }
check clean gone; check built gone; check edited kept; check untracked kept; check ignored kept; check local kept
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
