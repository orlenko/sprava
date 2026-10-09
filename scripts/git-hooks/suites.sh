# Shared by pre-push and test-tree.sh (sourced, not run): which suites a commit needs, where it is tested, and the
# cache of trees that passed.
# A commit needs the Swift suite (./scripts/test.sh) when its own changes touch what the package builds from or
# how it is tested: Sources/, Tests/, Resources/ (the manifest links a plist from there), Package.swift, the
# dependency lockfile Package.resolved, scripts/test.sh, or any .swift file; and the companion suite (companion/test.sh) when they touch companion/. Its own changes are
# those against its first parent (for a merge, what it brings to that line), or every file for a root commit;
# renames count as a removal and an addition, so both paths are seen.
# A suite passes only when its runner exits with status zero; the summary line is only reported. A pass is then
# recorded as "<suite> <tree hash>" in <common git dir>/sprava-hooks/passed-trees, and a suite already recorded
# for a commit's tree is not run again: the suites read nothing but the tree. The cache is shared by every
# worktree of the repository; delete the file to forget it.
# A commit is always tested in a detached worktree kept in this checkout's git directory (sprava-hooks/push-tree),
# reset to exactly that commit each time and keeping its .build, so its builds stay incremental from one run to
# the next. Never in the person's checkout, which may move on (a commit, a checkout, an edit) while a run lasts.
# A commit whose changes cannot be tested (it lacks the test script for what it changes) fails.
#
# Runs that test a commit take turns: each holds <git dir>/sprava-hooks/push-tree.lock from checkout through
# the suite run and the recording of its pass, so no run can change the kept worktree under another's suite.
#
# The caller is at the top of the checkout, has unset GIT_DIR and friends, has sourced lock.sh, and defines
# fail <message> and a scratch folder $work. Counters: suites_run, suites_cached, commits_skipped.

hooks="$(git rev-parse --absolute-git-dir)/sprava-hooks"
tree="$hooks/push-tree"
cache_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/sprava-hooks
cache="$cache_dir/passed-trees"
suites_run=0; suites_cached=0; commits_skipped=0

# Puts the commit in the persistent worktree: a forced detached checkout, then removal of everything untracked
# except .build. A missing or broken worktree is recreated.
checkout_tree() {
    if [ -f "$tree/.git" ] && top=$(git -C "$tree" rev-parse --show-toplevel 2>/dev/null) \
        && [ "$(cd "$top" && pwd -P)" = "$(cd "$tree" && pwd -P)" ]; then
        git -c core.hooksPath=/dev/null -C "$tree" checkout --detach --force --quiet "$1" \
            && git -C "$tree" clean -ffdxq -e /.build
    else
        rm -rf "$tree" && git worktree prune && mkdir -p "$hooks" \
            && git -c core.hooksPath=/dev/null worktree add --detach --force --quiet "$tree" "$1"
    fi
}

run_suite() {    # <folder> <runner> <log>
    (cd "$1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX && "$2") > "$3" 2>&1 </dev/null 9>&-
}

drop_cached() {  # clears need_swift and need_companion for suites already recorded as passed for $tree_sha
    if [ "$need_swift" -eq 1 ] && passed_before swift "$tree_sha"; then
        need_swift=0; suites_cached=$((suites_cached + 1))
        echo "$who: $short ($label): Swift tests already passed for this tree" >&2
    fi
    if [ "$need_companion" -eq 1 ] && passed_before companion "$tree_sha"; then
        need_companion=0; suites_cached=$((suites_cached + 1))
        echo "$who: $short ($label): companion tests already passed for this tree" >&2
    fi
}

passed_before() { [ -f "$cache" ] && grep -qx "$1 $2" "$cache"; }    # <suite> <tree>
record_pass() {                                                       # <suite> <tree>
    mkdir -p "$cache_dir" && echo "$1 $2" >> "$cache" || echo "note: could not record the pass in $cache" >&2
}

# Tests one commit: <sha> <label for messages> <prefix for messages>.
test_commit() {
    sha=$1; label=$2; who=$3
    short=$(git rev-parse --short "$sha")
    tree_sha=$(git rev-parse "$sha^{tree}") || fail "$who: could not read the tree of $short ($label)"
    if git rev-parse -q --verify "$sha^1" >/dev/null; then
        git diff -z --name-only --no-renames --no-relative --no-ext-diff "$sha^1" "$sha" > "$work/changed.z" \
            || fail "$who: could not list the changes of $short ($label)"
    else
        git ls-tree -r -z --name-only "$sha" > "$work/changed.z" || fail "$who: could not list the files of $short ($label)"
    fi
    tr '\0' '\n' < "$work/changed.z" > "$work/changed"
    need_swift=0; need_companion=0
    grep -qE '^(Sources|Tests|Resources)/|^Package\.(swift|resolved)$|^scripts/test\.sh$|\.swift$' "$work/changed" && need_swift=1    # as in pre-commit
    grep -q '^companion/' "$work/changed" && need_companion=1
    if [ "$need_swift" -eq 0 ] && [ "$need_companion" -eq 0 ]; then commits_skipped=$((commits_skipped + 1)); return 0; fi
    drop_cached
    [ "$need_swift" -eq 0 ] && [ "$need_companion" -eq 0 ] && return 0

    # One run at a time per git directory, from checkout through recording the pass: otherwise another run could
    # check out its own commit into the kept worktree while this one's suite is reading it.
    mkdir -p "$hooks" || fail "$who: could not create $hooks"
    hold_lock "$hooks/push-tree.lock" "$who" || fail "$who: could not lock $hooks/push-tree.lock"
    drop_cached                                     # another run may have passed this tree while this one waited
    if [ "$need_swift" -eq 0 ] && [ "$need_companion" -eq 0 ]; then release_lock; return 0; fi

    checkout_tree "$sha" > "$work/git.log" 2>&1 \
        || fail "$(tail -5 "$work/git.log")
$who: could not check out $short ($label) to test it"
    [ "$(git -C "$tree" rev-parse HEAD)" = "$sha" ] && [ -z "$(git -C "$tree" status --porcelain --untracked-files=no)" ] \
        || fail "$who: the kept worktree $tree does not hold exactly $short ($label)"
    dir=$tree

    if [ "$need_swift" -eq 1 ]; then
        if [ -f "$dir/Package.swift" ] && [ -x "$dir/scripts/test.sh" ]; then
            suites_run=$((suites_run + 1))
            if run_suite "$dir" ./scripts/test.sh "$work/out"; then
                record_pass swift "$tree_sha"
                summary=$(grep "^All test runs passed" "$work/out" | tail -1 || true)
                echo "$who: $short ($label): ${summary:-Swift tests passed}" >&2
            else
                status=$?
                details=$(grep -E "✘|error:|^Tests failed" "$work/out" | head -20 || true)
                [ -n "$details" ] || details=$(tail -30 "$work/out")
                fail "$details
$who: Swift tests failed for $short ($label): scripts/test.sh exit status $status"
            fi
        elif [ -e "$dir/Package.swift" ] || [ -e "$dir/Sources" ] || [ -e "$dir/Tests" ]; then
            fail "$who: $short ($label) changes Swift code but has no Package.swift or executable scripts/test.sh to test it"
        fi
    fi
    if [ "$need_companion" -eq 1 ]; then
        if [ -x "$dir/companion/test.sh" ]; then
            suites_run=$((suites_run + 1))
            if run_suite "$dir" companion/test.sh "$work/out"; then
                record_pass companion "$tree_sha"
                echo "$who: $short ($label): companion tests passed" >&2
            else
                status=$?
                fail "$(tail -30 "$work/out")
$who: companion tests failed for $short ($label): companion/test.sh exit status $status"
            fi
        elif [ -e "$dir/companion" ]; then
            fail "$who: $short ($label) changes companion/ but has no executable companion/test.sh"
        fi
    fi
    release_lock
}
