#!/bin/sh
# Runs the suites pre-push would run for each given commit, oldest first as given, and records each pass in the
# cache of tested trees, so a later push skips them. Usage, for a whole stack before pushing it:
#   ./scripts/git-hooks/test-tree.sh $(git rev-list --reverse origin/main..HEAD)
# Which suites a commit needs, where it runs and how passes are recorded are described in suites.sh.
set -eu
hook_dir="$(cd "$(dirname "$0")" && pwd -P)"
[ "$#" -gt 0 ] || { echo "usage: $0 <commit>..." >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
work=$(mktemp -d "${TMPDIR:-/tmp}/sprava-test-tree.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() { echo "$1" >&2; exit 1; }
for lib in lock.sh suites.sh; do [ -r "$hook_dir/$lib" ] || fail "test-tree: $hook_dir/$lib is missing"; . "$hook_dir/$lib"; done

for arg in "$@"; do
    sha=$(git rev-parse -q --verify "$arg^{commit}") || fail "test-tree: $arg is not a commit"
    test_commit "$sha" "$arg" test-tree
done
echo "test-tree: $# commit(s): $suites_run suite run(s), $suites_cached already passed for the same tree, $commits_skipped commit(s) skipped (no Swift or companion changes)" >&2
