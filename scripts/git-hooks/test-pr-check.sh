#!/bin/sh
# Tests for scripts/pr-check.sh and its use by pre-push, in throwaway repositories under a temporary folder. Every
# file and value is invented. Run: ./scripts/git-hooks/test-pr-check.sh
set -eu
hooks_dir=$(cd "$(dirname "$0")" && pwd -P)
check="$hooks_dir/../pr-check.sh"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR SPRAVA_ALLOW_LARGE SPRAVA_MAIN_REF
root=$(mktemp -d "${TMPDIR:-/tmp}/sprava-pr-check-tests.XXXXXX")
trap 'rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# pre-commit builds every commit of the pre-push case: a stub `swift` stands in for the toolchain.
mkdir "$root/bin" && printf '#!/bin/sh\nexit 0\n' > "$root/bin/swift" && chmod +x "$root/bin/swift"
export PATH="$root/bin:$PATH" SPRAVA_PRIVATE_TOKENS="$root/no-token-list"

passed=0; failed=0
ok()  { passed=$((passed + 1)); echo "ok   - $1"; }
bad() { failed=$((failed + 1)); echo "FAIL - $1"; sed 's/^/       /' "$root/out"; }

# <name>: a repository with one commit on main, published as origin/main, and a branch "work" checked out.
new_repo() {
    repo="$root/$1"
    git init -q -b main "$repo"
    git -C "$repo" config user.name "Test Person"
    git -C "$repo" config user.email "test@example.invalid"
    git -C "$repo" config commit.gpgsign false
    mkdir -p "$repo/Sources/Shelf" "$repo/Tests/ShelfTests"
    printf 'let shelf = 1\n' > "$repo/Sources/Shelf/Shelf.swift"
    printf 'let tested = 1\n' > "$repo/Tests/ShelfTests/ShelfTests.swift"
    git -C "$repo" add -A && git -C "$repo" commit -q -m "Start"
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
    git -C "$repo" checkout -q -b work
}
lines() { seq 1 "$1" | sed 's/^/let invented = /'; }                    # <count>: that many lines of Swift
add() { mkdir -p "$(dirname "$repo/$1")"; lines "$2" > "$repo/$1"; git -C "$repo" add -A; git -C "$repo" commit -q -m "Add $1"; }
run() { (cd "$repo" && "$check" "$@") > "$root/out" 2>&1; }             # the check's exit status; its report in out

new_repo small
add Sources/Shelf/Rows.swift 40
if run && grep -qx '+40/-0 in Shelf, 1 domain target(s), base 0 behind origin/main' "$root/out"; then
    ok "small: one target, 40 lines, passes with its summary line"
else bad "small: refused, or the summary line is wrong"; fi

new_repo companion
add Sources/Companion/Wire.swift 10
add Tests/CompanionTests/WireTests.swift 7
if run && grep -q '+17/-0 in Companion, 1 domain target(s)' "$root/out"; then
    add Sources/BinderStore/Store.swift 5
    if ! run && grep -q 'touches 2 domain targets (BinderStore Companion)' "$root/out"; then
        ok "companion: code and tests count as one domain; a BinderStore dependency is a second"
    else bad "companion: another domain target was not counted"; fi
else bad "companion: new domain was not counted"; fi

new_repo large
add Sources/Shelf/Large.swift 1001
if run; then bad "large: 1,001 lines passed"
elif grep -q '1001 changed lines, over 1000' "$root/out" && (SPRAVA_ALLOW_LARGE=1; export SPRAVA_ALLOW_LARGE; run); then
    ok "large: over 1,000 lines is refused, and SPRAVA_ALLOW_LARGE=1 lets it through"
else bad "large: refused for another reason, or the override did not work"; fi

new_repo note
add Sources/Shelf/Medium.swift 600
if run && grep -q 'note: 600 changed lines, over 500' "$root/out" && grep -q 'over 400 lines: Sources/Shelf/Medium.swift (600 lines)' "$root/out"; then
    ok "note: 600 lines and a file over 400 lines are reported, not refused"
else bad "note: refused, or the notes are missing"; fi

new_repo moved
git -C "$repo" checkout -q main && add Sources/Shelf/Big.swift 1200 && git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q -B work && mkdir -p "$repo/Sources/Shelf/Rows"
git -C "$repo" mv Sources/Shelf/Big.swift Sources/Shelf/Rows/Big.swift && git -C "$repo" commit -q -m "Move"
if run && grep -q '^+0/-0 in Shelf' "$root/out"; then ok "moved: a moved file counts as a rename, not 2,400 lines"
else bad "moved: a move was counted as changed lines"; fi

new_repo targets
add Sources/Shelf/Rows.swift 10
add Sources/SpravaKit/Kit.swift 10
add Sources/Services/ShelfCommands.swift 10
if run && grep -q '1 domain target(s)' "$root/out"; then
    add Sources/Hub/Lane.swift 10
    if run; then bad "targets: Shelf and Hub together passed"
    elif grep -q 'touches 2 domain targets (Hub Shelf)' "$root/out"; then
        ok "targets: SpravaKit and Services are not counted; a second domain target is refused"
    else bad "targets: refused for another reason"; fi
else bad "targets: one domain target with SpravaKit and Services was refused"; fi

# Non-ASCII names, which git quotes unless asked not to, still count toward targets and long files.
# A domain target's tests count as that target: Shelf's code with Hub's tests touches two.
new_repo testtargets
add Sources/Shelf/Rows.swift 10
add Tests/ShelfTests/RowsTests.swift 10
if run && grep -q '+20/-0 in Shelf, 1 domain target(s)' "$root/out"; then
    add Tests/HubTests/LaneTests.swift 10
    if ! run && grep -q 'touches 2 domain targets (Hub Shelf)' "$root/out"; then
        ok "test targets: a target's tests count as it; another target's tests count as a second"
    else bad "test targets: Hub's tests were not counted"; fi
else bad "test targets: Shelf's code and tests counted as more than Shelf"; fi

new_repo unicode
add "Sources/Shelf/Résumé.swift" 450
add Sources/Hub/Lane.swift 10
if ! run && grep -q 'touches 2 domain targets (Hub Shelf)' "$root/out" && grep -q 'over 400 lines: Sources/Shelf/Résumé.swift (450 lines)' "$root/out"; then
    ok "unicode: a non-ASCII name counts its target and its length"
else bad "unicode: a non-ASCII name was missed"; fi

new_repo reviewnamed
printf 'let more = 1\n' >> "$repo/Tests/ShelfTests/ShelfTests.swift"
git -C "$repo" commit -q -am "Extend"
add Tests/ShelfTests/AstraReview7Tests.swift 5
if run; then bad "review name: a new AstraReview7Tests.swift passed"
elif grep -q 'named after a review round: Tests/ShelfTests/AstraReview7Tests.swift' "$root/out"; then
    git -C "$repo" mv Tests/ShelfTests/AstraReview7Tests.swift Tests/ShelfTests/ShelfOrderTests.swift
    git -C "$repo" commit -q -m "Name by behavior"
    if run; then ok "review name: a new review-named test file is refused; named by behavior, it passes"
    else bad "review name: the renamed file was still refused"; fi
else bad "review name: refused for another reason"; fi
# Renaming an old file to a review name counts as adding one; prefixed names are caught too.
git -C "$repo" mv Tests/ShelfTests/ShelfTests.swift Tests/ShelfTests/ShelfBugbotTests.swift
git -C "$repo" commit -q -m "Rename"
if ! run && grep -q 'ShelfBugbotTests.swift' "$root/out"; then ok "review name: a rename to a prefixed review name is refused"
else bad "review name: a rename to ShelfBugbotTests.swift passed"; fi

new_repo stale
git -C "$repo" checkout -q main
for i in $(seq 1 21); do printf 'let n = %s\n' "$i" > "$repo/Sources/Shelf/Count.swift"; git -C "$repo" add -A; git -C "$repo" commit -q -m "Count $i"; done
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q work && add Sources/Shelf/Rows.swift 5
if run && grep -q 'base 21 behind origin/main' "$root/out" && grep -q 'note: the base is 21 commits behind' "$root/out"; then
    ok "stale: a base 21 commits behind is reported"
else bad "stale: the stale base was refused or not reported"; fi

new_repo nomain
git -C "$repo" update-ref -d refs/remotes/origin/main
if run && grep -q 'no origin/main to compare with; skipped' "$root/out"; then ok "no main: skipped with a note"
else bad "no main: refused without an origin/main"; fi

# pre-push runs the check from the pushed checkout and refuses before any suite runs. The checkout's own
# scripts/pr-check.sh is used, so it is committed into the repository under test.
new_repo prepush
git -C "$repo" config core.hooksPath "$hooks_dir"
git init -q --bare "$root/prepush.remote.git" && git -C "$repo" remote add origin "$root/prepush.remote.git"
mkdir -p "$repo/scripts" && cp "$check" "$repo/scripts/pr-check.sh"
printf '// swift-tools-version:6.0\n' > "$repo/Package.swift"
printf '#!/bin/sh\necho "All test runs passed: 1 tests in 1 test target(s)."\n' > "$repo/scripts/test.sh" && chmod +x "$repo/scripts/test.sh"
git -C "$repo" add -A && git -C "$repo" commit -q -m "Checker and a stub test runner"
git -C "$repo" push -q origin work:main 2>/dev/null; git -C "$repo" fetch -q origin
add Sources/Shelf/Rows.swift 10 && add Sources/Hub/Lane.swift 10
if git -C "$repo" push -q origin work > "$root/out" 2>&1; then bad "pre-push: a branch touching two domain targets was pushed"
elif grep -q 'pre-push: work: pr-check: touches 2 domain targets' "$root/out" && grep -q 'work is refused by scripts/pr-check.sh' "$root/out" \
    && ! git -C "$repo" ls-remote --exit-code origin refs/heads/work > /dev/null; then
    git -C "$repo" reset -q --hard HEAD~1
    if git -C "$repo" push -q origin work > "$root/out" 2>&1 && grep -q 'pre-push: work: +10/-0 in Shelf' "$root/out"; then
        ok "pre-push: a refused branch is not pushed; once fixed it is, with its summary line"
    else bad "pre-push: the fixed branch was not pushed"; fi
    # Pushed by commit id, the branch is named by the remote ref and checked all the same.
    add Sources/Hub/Lane.swift 10
    if git -C "$repo" push -q origin "$(git -C "$repo" rev-parse HEAD):refs/heads/other" > "$root/out" 2>&1; then
        bad "pre-push: a commit id pushed to a branch skipped the check"
    elif grep -q 'pre-push: other: pr-check: touches 2 domain targets' "$root/out"; then
        ok "pre-push: a commit id pushed to a branch is checked as that branch"
    else bad "pre-push: the commit id push was refused for another reason"; fi
else bad "pre-push: refused for another reason, or something was pushed"; fi

# A commit that changes the hooks runs the hook suite (here a stub that fails on BROKEN) and is refused when it fails.
git -C "$repo" fetch -q origin && git -C "$repo" reset -q --hard origin/work
mkdir -p "$repo/scripts/git-hooks"
printf '#!/bin/sh\n! grep -qs BROKEN scripts/git-hooks/notes.txt\n' > "$repo/scripts/git-hooks/test-hooks.sh"
chmod +x "$repo/scripts/git-hooks/test-hooks.sh"
echo "fine" > "$repo/scripts/git-hooks/notes.txt"
git -C "$repo" add -A && git -C "$repo" commit -q -m "Hook notes"
if git -C "$repo" push -q origin work > "$root/out" 2>&1 && grep -q 'hook tests passed' "$root/out"; then
    echo "BROKEN" > "$repo/scripts/git-hooks/notes.txt"
    git -C "$repo" commit -q -am "Break the hooks"
    if git -C "$repo" push -q origin work > "$root/out" 2>&1; then bad "hook suite: a commit failing the hook tests was pushed"
    elif grep -q 'hook tests failed for' "$root/out"; then ok "hook suite: a hook change runs the hook tests, and a failing one is not pushed"
    else bad "hook suite: refused for another reason"; fi
else bad "hook suite: the hook change was not pushed, or its tests did not run"; fi

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
