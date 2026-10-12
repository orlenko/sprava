#!/bin/sh
# Tests for the split gate (AGENTS.md, steps 3 and 4): scripts/affected-tests.sh, the targeted Swift tests pre-push
# runs, and scripts/merge-pr.sh. Throwaway repositories under a temporary folder; `swift` and `gh` are stubs on
# PATH, and each repository's scripts/test.sh records the arguments it was run with. Every value is invented.
# Run: ./scripts/git-hooks/test-gate.sh
set -eu
hooks_dir=$(cd "$(dirname "$0")" && pwd -P)
scripts_dir=$(cd "$hooks_dir/.." && pwd -P)
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR SPRAVA_FULL_SUITE SPRAVA_MAIN_REF
root=$(mktemp -d "${TMPDIR:-/tmp}/sprava-gate-tests.XXXXXX")
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 SPRAVA_PRIVATE_TOKENS="$root/no-token-list"

# The package: A, B on A, and their tests; C with its tests; shared support S that only CTests uses.
mkdir "$root/bin"
cat > "$root/bin/swift" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "package dump-package" ]; then cat <<'JSON'
{"targets": [
 {"name": "A", "type": "regular", "dependencies": []},
 {"name": "B", "type": "regular", "dependencies": [{"byName": ["A", null]}]},
 {"name": "C", "type": "regular", "dependencies": []},
 {"name": "S", "type": "regular", "path": "Tests/S", "dependencies": []},
 {"name": "ATests", "type": "test", "dependencies": [{"byName": ["A", null]}]},
 {"name": "BTests", "type": "test", "dependencies": [{"target": ["B", null]}]},
 {"name": "CTests", "type": "test", "dependencies": [{"byName": ["C", null]}, {"byName": ["S", null]}]}
]}
JSON
fi
exit 0
EOF
# gh: answers from files the test writes; records merges.
cat > "$root/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
"pr view") cat "$GH_STATE/view" ;;
"api graphql") cat "$GH_STATE/open" ;;
"pr merge") echo "$*" >> "$GH_STATE/merged" ;;
esac
EOF
chmod +x "$root/bin/swift" "$root/bin/gh"
export PATH="$root/bin:$PATH" GH_STATE="$root/gh"
mkdir "$GH_STATE"

passed=0; failed=0

# The key the hooks record a Swift pass under (suites.sh swift_key): the package's inputs at <commit>.
skey() {
    git -C "$repo" ls-tree "$1" -- Sources Tests Resources Package.swift Package.resolved scripts/test.sh |
        git -C "$repo" hash-object --stdin
}
ok()  { passed=$((passed + 1)); echo "ok   - $1"; }
bad() { failed=$((failed + 1)); echo "FAIL - $1"; [ -f "$root/out" ] && sed 's/^/       /' "$root/out"; }

repo="$root/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name "Test Person"
git -C "$repo" config user.email "test@example.invalid"
git -C "$repo" config commit.gpgsign false
mkdir -p "$repo/Sources/A" "$repo/Sources/B" "$repo/Sources/C" "$repo/Tests/S" "$repo/scripts"
for t in A B C; do printf 'let %s = 1\n' "$(echo $t | tr ABC abc)" > "$repo/Sources/$t/$t.swift"; done
printf 'let s = 1\n' > "$repo/Tests/S/S.swift"
printf '// swift-tools-version:6.0\n' > "$repo/Package.swift"
cp "$scripts_dir/affected-tests.sh" "$scripts_dir/merge-pr.sh" "$repo/scripts/"
# merge-pr.sh sources the two hook libraries beside it; a stub stands in for the hook suite.
mkdir -p "$repo/scripts/git-hooks" && cp "$hooks_dir/lock.sh" "$hooks_dir/suites.sh" "$repo/scripts/git-hooks/"
printf '#!/bin/sh\nexit 0\n' > "$repo/scripts/git-hooks/test-hooks.sh" && chmod +x "$repo/scripts/git-hooks/test-hooks.sh"
cat > "$repo/scripts/test.sh" <<'EOF'
#!/bin/sh
echo "test.sh $*" >> "${TEST_LOG:?}"
[ -z "${ON_TEST:-}" ] || sh -c "$ON_TEST"
echo "All test runs passed: 1 tests in 1 test target(s)."
EOF
chmod +x "$repo/scripts/test.sh"
export TEST_LOG="$root/test.log"
git -C "$repo" add -A && git -C "$repo" commit -q -m "Start"
change() { echo "// $2" >> "$repo/$1"; git -C "$repo" add -A; git -C "$repo" commit -q -m "Change $1"; }
scope() { (cd "$repo" && ./scripts/affected-tests.sh HEAD~1 HEAD); }

change Sources/A/A.swift one
[ "$(scope)" = "ATests|BTests" ] && ok "scope: A's change tests A and B, which depends on it" || { echo "$(scope)" > "$root/out"; bad "scope: A"; }
change Sources/B/B.swift two
[ "$(scope)" = "BTests" ] && ok "scope: B's change tests B only" || { echo "$(scope)" > "$root/out"; bad "scope: B"; }
change Tests/S/S.swift three
[ "$(scope)" = "CTests" ] && ok "scope: shared test support tests whatever uses it" || { echo "$(scope)" > "$root/out"; bad "scope: S"; }
echo "notes" > "$repo/notes.md"; git -C "$repo" add -A; git -C "$repo" commit -q -m "Notes"
[ "$(scope)" = "NONE" ] && ok "scope: a change outside every target tests nothing" || { echo "$(scope)" > "$root/out"; bad "scope: notes"; }
change Package.swift four
[ "$(scope)" = "ALL" ] && ok "scope: the package itself runs the whole suite" || { echo "$(scope)" > "$root/out"; bad "scope: package"; }

# pre-push runs only the affected targets, and records the part that passed.
git -C "$repo" config core.hooksPath "$hooks_dir"
git init -q --bare "$root/remote.git" && git -C "$repo" remote add origin "$root/remote.git"
git -C "$repo" push -q origin main 2>/dev/null; git -C "$repo" fetch -q origin
: > "$TEST_LOG"
change Sources/B/B.swift five
if git -C "$repo" push -q origin main > "$root/out" 2>&1 && grep -qx 'test.sh --filter BTests' "$TEST_LOG" \
    && grep -q "swift:BTests $(skey HEAD)" "$repo/.git/sprava-hooks/passed-trees"; then
    ok "pre-push: a push changing B runs BTests only and records that part"
else bad "pre-push: the targeted run did not happen"; fi

# merge-pr.sh: refusals, then the whole suite once and the merge.
git -C "$repo" checkout -q -b work
change Sources/C/C.swift six
head=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" push -q origin work 2>/dev/null
merge() { (cd "$repo" && ./scripts/merge-pr.sh 7) > "$root/out" 2>&1; }
echo "OPEN main $head" > "$GH_STATE/view"; echo 2 > "$GH_STATE/open"
if ! merge && grep -q '2 review thread(s) unresolved' "$root/out" && [ ! -f "$GH_STATE/merged" ]; then
    ok "merge: unresolved threads refuse the merge"
else bad "merge: merged with unresolved threads"; fi
echo 0 > "$GH_STATE/open"
git -C "$repo" checkout -q main && change Sources/A/A.swift seven && git -C "$repo" push -q origin main 2>/dev/null
git -C "$repo" checkout -q work
if ! merge && grep -q 'does not contain the current main' "$root/out" && [ ! -f "$GH_STATE/merged" ]; then
    ok "merge: a tip that lacks the current main is refused"
else bad "merge: a stale tip was merged"; fi
git -C "$repo" rebase -q main && head=$(git -C "$repo" rev-parse HEAD) && git -C "$repo" push -q -f origin work 2>/dev/null
echo "OPEN main $head" > "$GH_STATE/view"
: > "$TEST_LOG"
if merge && grep -qx 'test.sh ' "$TEST_LOG" && grep -q -- "--match-head-commit $head" "$GH_STATE/merged"; then
    rm "$GH_STATE/merged"; : > "$TEST_LOG"
    if merge && [ ! -s "$TEST_LOG" ] && grep -q 'already passed for these sources' "$root/out"; then
        ok "merge: the whole suite runs once on the tip, the merge names that tip, and a tree that passed is not run again"
    else bad "merge: the passed tree was tested again"; fi
else bad "merge: the whole suite did not run, or the merge did not name the tip"; fi

# Another PR merges while the suite runs: the merge is refused, since the merged tree would not be the tested one.
git clone -q -b main "$root/remote.git" "$root/other"
git -C "$root/other" config user.name "Test Person"; git -C "$root/other" config user.email "test@example.invalid"
change Sources/C/C.swift eight
head=$(git -C "$repo" rev-parse HEAD) && git -C "$repo" push -q -f origin work 2>/dev/null
echo "OPEN main $head" > "$GH_STATE/view"; rm -f "$GH_STATE/merged"
export ON_TEST="cd '$root/other' && echo nine >> notes.md && git add -A && git commit -q -m Other && git push -q origin main"
if ! merge && grep -q 'main moved while the suite ran' "$root/out" && [ ! -f "$GH_STATE/merged" ]; then
    ok "merge: main moving during the run refuses the merge"
else bad "merge: merged although main moved during the run"; fi
unset ON_TEST

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
