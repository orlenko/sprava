#!/bin/sh
# Tests for the git hooks, in throwaway repositories under a temporary folder. Every value here is invented:
# the private-token list is a temporary file holding a made-up sentinel, passed through SPRAVA_PRIVATE_TOKENS.
# The Swift toolchain is replaced by stubs: a `swift` on PATH whose build fails when a source holds BROKEN, and a
# committed scripts/test.sh that fails when a source holds FAIL. Run: ./scripts/git-hooks/test-hooks.sh
set -eu
hooks_dir=$(cd "$(dirname "$0")" && pwd -P)
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
root=$(mktemp -d "${TMPDIR:-/tmp}/sprava-hook-tests.XXXXXX")
trap 'chmod -R u+rwx "$root" 2>/dev/null; rm -rf "$root"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export SPRAVA_PRIVATE_TOKENS="$root/tokens"
printf 'invented_sentinel_[0-9]+\n' > "$SPRAVA_PRIVATE_TOKENS"

mkdir "$root/bin"
cat > "$root/bin/swift" <<'EOF'
#!/bin/sh
# Stub build: fails when any source under Sources/ contains BROKEN, takes a while on SLOWBUILD; records where it ran.
pwd -P >> "${STUB_LOG:?}"
if grep -rqs SLOWBUILD Sources; then sleep 2; fi
! grep -rqs BROKEN Sources
EOF
chmod +x "$root/bin/swift"
export PATH="$root/bin:$PATH"
export STUB_LOG="$root/stub.log"

passed=0; failed=0
ok()  { passed=$((passed + 1)); echo "ok   - $1"; }
bad() { failed=$((failed + 1)); echo "FAIL - $1"; [ -f "$root/err" ] && sed 's/^/       /' "$root/err"; }

new_repo() {     # <name>: a repository with the hooks installed, one commit, and a bare remote "origin"
    repo="$root/$1"
    git init -q -b main "$repo"
    git -C "$repo" config user.name "Test Person"
    git -C "$repo" config user.email "test@example.invalid"
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config core.hooksPath "$hooks_dir"
    git init -q --bare "$root/$1.remote.git"
    git -C "$repo" remote add origin "$root/$1.remote.git"
}

commit() { git -C "$repo" commit -q -m "$1" > "$root/out" 2> "$root/err"; }
push()   { git -C "$repo" push -q origin HEAD:main > "$root/out" 2> "$root/err"; }

# A Swift package whose stub test runner fails on FAIL, and exits 1 after printing the success summary on SUMMARY_THEN_EXIT_1.
swift_package() {
    mkdir -p "$repo/Sources/Demo" "$repo/scripts"
    printf '// swift-tools-version:6.0\n' > "$repo/Package.swift"
    printf 'let greeting = "hello"\n' > "$repo/Sources/Demo/Demo.swift"
    cat > "$repo/scripts/test.sh" <<'EOF'
#!/bin/sh
pwd -P >> "${STUB_LOG:?}"
if grep -rqs SLOW Sources; then sleep 2; fi
if grep -rqs FAIL Sources; then echo "Tests failed: 1 of 1 test runs failed." >&2; exit 1; fi
echo "All test runs passed: 1 tests in 1 test target(s)."
if grep -rqs SUMMARY_THEN_EXIT_1 Sources; then exit 1; fi
exit 0
EOF
    chmod +x "$repo/scripts/test.sh"
    git -C "$repo" add -A
    commit "Package" || { echo "setup: the package commit was rejected:"; cat "$root/err"; exit 1; }
}

# 1. Context between hunks (diff.interHunkContext) must not hide an added line from the scan. Hostile settings
#    for prefixes, colour and blank context lines are set too.
new_repo context
for i in $(seq 1 30); do echo "line $i"; done > "$repo/notes.txt"
git -C "$repo" add notes.txt && commit "Notes"
git -C "$repo" config diff.interHunkContext 1
git -C "$repo" config diff.noprefix true
git -C "$repo" config diff.mnemonicPrefix true
git -C "$repo" config color.ui always
git -C "$repo" config diff.suppressBlankEmpty true
awk 'NR == 3 { print "changed 3"; next } NR == 5 { print "changed 5"; next }
     NR == 20 { print "changed 20"; print "added invented_sentinel_42"; next } { print }' "$repo/notes.txt" > "$root/tmp" && mv "$root/tmp" "$repo/notes.txt"
git -C "$repo" add notes.txt
if commit "Nearby edits and a token"; then
    bad "interHunkContext: a commit with a private token was accepted"
elif grep -q 'notes.txt:21$' "$root/err" && ! grep -q invented_sentinel "$root/err"; then
    ok "interHunkContext: the token on notes.txt:21 is found, its text withheld"
else
    bad "interHunkContext: rejected, but not by file and line alone"
fi
git -C "$repo" reset -q --hard
awk 'NR == 3 { print "changed 3"; next } NR == 5 { print "changed 5"; next } { print }' "$repo/notes.txt" > "$root/tmp" \
    && mv "$root/tmp" "$repo/notes.txt"
git -C "$repo" add notes.txt
if commit "Nearby edits"; then ok "interHunkContext: a clean commit passes"; else bad "interHunkContext: a clean commit was rejected"; fi

# A malformed pattern rejects the commit instead of skipping the scan.
printf 'unclosed[\n' > "$root/bad-tokens"
echo "more" >> "$repo/notes.txt"; git -C "$repo" add notes.txt
if (SPRAVA_PRIVATE_TOKENS="$root/bad-tokens"; export SPRAVA_PRIVATE_TOKENS; commit "More"); then bad "malformed pattern: the commit was accepted"
else ok "malformed pattern: the commit is rejected"; fi
git -C "$repo" reset -q --hard

# Binary content and files marked -diff are scanned too, by file name.
printf 'header\000\001\002 invented_sentinel_7 \377\n' > "$repo/blob.bin"
git -C "$repo" add blob.bin
if commit "A binary file with a token"; then bad "binary: a binary file with a private token was accepted"
elif grep -q '^blob.bin (in its staged content; no line number)$' "$root/err" && ! grep -q invented_sentinel "$root/err"; then
    ok "binary: a file with a NUL byte and a token is rejected by name, its text withheld"
else bad "binary: rejected, but not by file name alone"; fi
git -C "$repo" reset -q --hard
echo 'opaque.txt -diff' > "$repo/.gitattributes"
git -C "$repo" add .gitattributes && commit "Attributes"
echo "plain text with invented_sentinel_8" > "$repo/opaque.txt"
git -C "$repo" add opaque.txt
if commit "A -diff file with a token"; then bad "binary: a file marked -diff with a private token was accepted"
elif grep -q '^opaque.txt (in its staged content; no line number)$' "$root/err" && ! grep -q invented_sentinel "$root/err"; then
    ok "binary: a file marked -diff with a token is rejected by name, its text withheld"
else bad "binary: the -diff file was rejected, but not by file name alone"; fi
git -C "$repo" reset -q --hard

# The token list: only a list that is certainly absent skips the scan.
with_list() {    # <list path> <message>: commits the staged change with that token list
    (SPRAVA_PRIVATE_TOKENS="$1"; export SPRAVA_PRIVATE_TOKENS; commit "$2")
}
echo "listed invented_sentinel_9" > "$repo/listed.txt"
git -C "$repo" add listed.txt
mkdir "$root/locked" && cp "$SPRAVA_PRIVATE_TOKENS" "$root/locked/tokens" && chmod 000 "$root/locked"
if with_list "$root/locked/tokens" "Through a locked folder"; then bad "token list: a list in an unsearchable folder skipped the scan"
elif grep -q "cannot be looked up" "$root/err"; then ok "token list: a list in an unsearchable folder rejects the commit"
else bad "token list: a list in an unsearchable folder was rejected for another reason"; fi
chmod 700 "$root/locked"
ln -s "$root/nowhere/tokens" "$root/dangling"
if with_list "$root/dangling" "Through a dangling symlink"; then bad "token list: a dangling symlink skipped the scan"
elif grep -q "is not a readable file" "$root/err"; then ok "token list: a dangling symlink rejects the commit"
else bad "token list: a dangling symlink was rejected for another reason"; fi
ln -s "$SPRAVA_PRIVATE_TOKENS" "$root/linked"
if with_list "$root/linked" "Through a good symlink"; then bad "token list: a symlink to a readable list skipped the scan"
elif grep -q '^listed.txt:1$' "$root/err"; then ok "token list: a symlink to a readable list is used for the scan"
else bad "token list: a symlink to a readable list was rejected for another reason"; fi
git -C "$repo" reset -q --hard
echo "listed without a token" > "$repo/listed.txt"
git -C "$repo" add listed.txt
if with_list "$root/absent/tokens" "Without a list" && grep -q "the privacy scan was skipped" "$root/err"; then
    ok "token list: a list that is certainly absent skips the scan, and says so"
else bad "token list: an absent list did not skip the scan as expected"; fi
git -C "$repo" reset -q --hard

# The commit message is scanned too, with the same rules: reported by line, its text withheld.
echo "message test" > "$repo/msg.txt"; git -C "$repo" add msg.txt
if git -C "$repo" commit -q -m "Clean subject" -m "Body naming invented_sentinel_11" > "$root/out" 2> "$root/err"; then
    bad "message: a commit message with a private token was accepted"
elif grep -q '^message line 3$' "$root/err" && ! grep -q invented_sentinel "$root/err"; then
    ok "message: a token in the commit message is found on line 3, its text withheld"
else bad "message: rejected, but not by message line alone"; fi
# A line that looks like a comment is scanned: with -m, git keeps it in the message.
if git -C "$repo" commit -q -m "Clean subject" -m "# invented_sentinel_12" > "$root/out" 2> "$root/err"; then
    bad "message: a token on a comment-like line of the message was accepted"
else ok "message: a token on a comment-like line of the message is rejected"; fi
# The hook alone, since pre-commit would reject a dangling list first.
printf 'Clean\n' > "$root/msg-file"
if SPRAVA_PRIVATE_TOKENS="$root/dangling" "$hooks_dir/commit-msg" "$root/msg-file" > "$root/out" 2> "$root/err"; then
    bad "message: a dangling token list skipped the scan of the message"
elif grep -q "is not a readable file" "$root/err"; then ok "message: a dangling token list rejects the commit"
else bad "message: a dangling token list was rejected for another reason"; fi
echo "message test" > "$repo/msg.txt"; git -C "$repo" add msg.txt
if commit "A clean message" && ! grep -q "the scan of the message was skipped" "$root/err"; then
    ok "message: a clean message passes the scan"
else bad "message: a clean message was rejected or not scanned"; fi
# `git commit -v`: the staged diff below the scissors line is not the message. Removing a line that holds a
# token, committed earlier without a list, shows it there as a removed line; that does not reject the commit.
echo "old invented_sentinel_13" > "$repo/legacy.txt"; git -C "$repo" add legacy.txt
with_list "$root/absent/tokens" "Legacy line" || { cp "$root/err" "$root/err-setup"; bad "message: setup commit failed"; }
echo "cleaned" > "$repo/legacy.txt"; git -C "$repo" add legacy.txt
if GIT_EDITOR='f() { printf "Remove the legacy line\n" | cat - "$1" > "$1.new" && mv "$1.new" "$1"; }; f' \
    git -C "$repo" commit -q -v > "$root/out" 2> "$root/err"; then
    ok "message: commit -v that removes a token passes; the diff under the scissors line is not scanned"
else bad "message: commit -v was rejected for the removed line in its diff"; fi

# 2. Partial staging: the build sees the index, not the working tree.
new_repo staging
swift_package
printf 'let greeting = "BROKEN"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources
printf 'let greeting = "fixed but unstaged"\n' > "$repo/Sources/Demo/Demo.swift"
if commit "Broken staged, fixed unstaged"; then bad "partial staging: a broken staged snapshot was committed"
else ok "partial staging: a broken staged snapshot is rejected though the working tree builds"; fi
printf 'let greeting = "good"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources
printf 'let greeting = "BROKEN in the working tree only"\n' > "$repo/Sources/Demo/Demo.swift"
snap="$repo/.git/sprava-hooks/staged"
inode_before=$(ls -i "$snap/Package.swift" | awk '{ print $1 }')
if commit "Good staged, broken unstaged"; then ok "partial staging: a good staged snapshot is committed though the working tree is broken"
else bad "partial staging: a good staged snapshot was rejected"; fi
inode_after=$(ls -i "$snap/Package.swift" | awk '{ print $1 }')
if [ "$inode_before" = "$inode_after" ] && [ "$(tail -1 "$STUB_LOG")" = "$(cd "$snap" && pwd -P)" ]; then
    ok "partial staging: the build ran in the snapshot, whose unchanged files were left in place"
else
    bad "partial staging: the snapshot was rebuilt from scratch or the build ran elsewhere"
fi
if git -C "$repo" commit -q -a -m "Commit the broken working tree" > "$root/out" 2> "$root/err"; then
    bad "partial staging: commit -a committed a broken working tree"
else ok "partial staging: commit -a builds what it commits (the working tree) and rejects it"; fi
git -C "$repo" checkout -q -- Sources

# Staging during the hook: a file with a token staged while the (slow) build runs must not ride into the commit.
printf 'let greeting = "SLOWBUILD"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources
(git -C "$repo" commit -q -m "Slow build" > "$root/out-slow" 2> "$root/err-slow") &
run_commit=$!
sleep 0.7
echo "sneaked in with invented_sentinel_10" > "$repo/sneaky.txt"
add_status=0; git -C "$repo" add sneaky.txt 2> "$root/err-add" || add_status=$?
commit_status=0; wait "$run_commit" || commit_status=$?
if [ "$add_status" -ne 0 ]; then
    cp "$root/err-add" "$root/err"; bad "staging during the hook: could not stage while the hook ran (test setup)"
elif [ "$commit_status" -ne 0 ] && grep -q "the staged files changed while the hook ran; commit again" "$root/err-slow" \
    && ! git -C "$repo" cat-file -e HEAD:sneaky.txt 2>/dev/null; then
    ok "staging during the hook: a file staged while the hook ran rejects the commit"
else
    cp "$root/err-slow" "$root/err"; bad "staging during the hook: the commit took a file that was never scanned (exit $commit_status)"
fi
git -C "$repo" reset -q --hard; rm -f "$repo/sneaky.txt"

# Package.resolved alone changes what is built: pre-commit builds it, pre-push tests it.
push || true
echo '{ "pins" : [ ], "version" : 3 }' > "$repo/Package.resolved"
git -C "$repo" add Package.resolved
builds_before=$(wc -l < "$STUB_LOG")
commit "Lockfile only" || true
builds_after=$(wc -l < "$STUB_LOG")
if [ "$builds_after" -gt "$builds_before" ] && push && grep -q "1 new commit(s): 1 suite run(s)" "$root/err"; then
    ok "lockfile: a commit changing only Package.resolved is built and tested"
else bad "lockfile: a commit changing only Package.resolved skipped the build or the tests"; fi

# 3. A runner that prints the success summary but exits non-zero fails the push.
new_repo exitstatus
swift_package
push || true
printf 'let greeting = "SUMMARY_THEN_EXIT_1"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Runner exits 1 after its summary"
if push; then bad "exit status: a failing runner with a success summary passed the push"
elif grep -q "exit status 1" "$root/err" \
    && ! grep -qs "$(git -C "$repo" rev-parse 'HEAD^{tree}')" "$repo/.git/sprava-hooks/passed-trees"; then
    ok "exit status: a failing runner with a success summary rejects the push and is not recorded as passed"
else bad "exit status: the push was rejected for another reason"; fi

# 4. A pushed commit that fails, followed by its revert: the failing commit is tested and rejects the push.
new_repo revert
swift_package
if push; then ok "revert: the first push passes"; else bad "revert: the first push was rejected"; fi
printf 'let greeting = "FAIL"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Break the tests"
broken=$(git -C "$repo" rev-parse --short HEAD)
git -C "$repo" revert --no-edit HEAD > /dev/null 2> "$root/err"
echo "docs" > "$repo/README.md"; git -C "$repo" add README.md && commit "Docs only"
if push; then bad "revert: a failing commit followed by its revert was pushed"
elif grep -q "Swift tests failed for $broken" "$root/err"; then ok "revert: the failing commit $broken is caught under its revert"
else bad "revert: the push was rejected, but not for the failing commit"; fi
# Once the failing commit is dropped, the push passes and only the commit with Swift changes is tested.
git -C "$repo" reset -q --hard HEAD~3
echo "docs" > "$repo/README.md"; git -C "$repo" add README.md && commit "Docs only"
printf 'let greeting = "better"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Better greeting"
if push && grep -q "2 new commit(s): 1 suite run(s), 0 already passed for the same tree, 1 commit(s) skipped" "$root/err"; then ok "revert: a good push tests the Swift commit and skips the docs commit"
else bad "revert: the good push was rejected or tested the wrong commits"; fi

# 5. The push worktree is reused: every pushed commit, the checkout's own HEAD included, is tested there, its
#    .build kept, untracked files removed.
tree="$repo/.git/sprava-hooks/push-tree"
mkdir -p "$tree/.build" && touch "$tree/.build/kept" "$tree/stray"
printf 'let greeting = "first"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "First"
printf 'let greeting = "second"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Second"
tree_real=$(cd "$tree" && pwd -P)
if push && grep -q "2 new commit(s): 2 suite run(s)" "$root/err" && [ -f "$tree/.build/kept" ] && [ ! -e "$tree/stray" ] \
    && [ "$(tail -2 "$STUB_LOG" | grep -cx "$tree_real")" -eq 2 ] \
    && [ "$(git -C "$tree" rev-parse HEAD)" = "$(git -C "$repo" rev-parse HEAD)" ]; then
    ok "reuse: both commits, HEAD included, are tested in the kept worktree, whose .build survives"
else bad "reuse: the kept worktree was not reused as expected"; fi

# 6. The pass cache: a tree tested by test-tree.sh is not tested again by the push, even under another commit.
cache="$repo/.git/sprava-hooks/passed-trees"
printf 'let greeting = "cached"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Cached greeting"
if (cd "$repo" && "$hooks_dir/test-tree.sh" HEAD) > "$root/out" 2> "$root/err" \
    && grep -qx "swift $(git -C "$repo" rev-parse 'HEAD^{tree}')" "$cache"; then
    ok "cache: test-tree.sh records the passed tree"
else bad "cache: test-tree.sh did not record the passed tree"; fi
git -C "$repo" commit -q --amend -m "Cached greeting, reworded" > /dev/null 2>&1
runs_before=$(wc -l < "$STUB_LOG")
if push && grep -q "1 new commit(s): 0 suite run(s), 1 already passed for the same tree" "$root/err" \
    && [ "$(wc -l < "$STUB_LOG")" -eq "$runs_before" ]; then
    ok "cache: a tree that passed is skipped on the next push, under a reworded commit"
else bad "cache: a tree that passed was tested again"; fi

# 7. A tree that fails is never recorded, so the push tests it again and rejects it.
printf 'let greeting = "FAIL again"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Break the tests again"
failing_tree=$(git -C "$repo" rev-parse 'HEAD^{tree}')
if (cd "$repo" && "$hooks_dir/test-tree.sh" HEAD) > "$root/out" 2> "$root/err"; then
    bad "cache: test-tree.sh passed a failing tree"
elif grep -q "$failing_tree" "$cache"; then bad "cache: a failing tree was recorded"
else ok "cache: test-tree.sh fails a failing tree and does not record it"; fi
runs_before=$(wc -l < "$STUB_LOG")
if push; then bad "cache: a failing tree was pushed"
elif [ "$(wc -l < "$STUB_LOG")" -gt "$runs_before" ] && ! grep -q "$failing_tree" "$cache"; then
    ok "cache: the push tests the failing tree again, rejects it, and records nothing"
else bad "cache: the push rejected the failing tree without testing it"; fi

# 8. Overlapping runs take turns in the kept worktree. A is slow and fails, B passes; B starts while A's suite runs.
#    Without the lock, B would check its sources out under A's running suite, A would pass and be recorded.
new_repo concurrent
swift_package
cache="$repo/.git/sprava-hooks/passed-trees"
printf 'let greeting = "SLOW, then FAIL"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Slow and failing"
commit_a=$(git -C "$repo" rev-parse HEAD); tree_a=$(git -C "$repo" rev-parse 'HEAD^{tree}')
printf 'let greeting = "fine"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Fine"
commit_b=$(git -C "$repo" rev-parse HEAD); tree_b=$(git -C "$repo" rev-parse 'HEAD^{tree}')
echo "docs" > "$repo/README.md"; git -C "$repo" add README.md && commit "Docs on top"
(cd "$repo" && "$hooks_dir/test-tree.sh" "$commit_a") > "$root/out-a" 2> "$root/err-a" &
run_a=$!
sleep 0.5
status_b=0; (cd "$repo" && "$hooks_dir/test-tree.sh" "$commit_b") > "$root/out-b" 2> "$root/err-b" || status_b=$?
status_a=0; wait "$run_a" || status_a=$?
if [ "$status_a" -ne 0 ] && [ "$status_b" -eq 0 ] && grep -qx "swift $tree_b" "$cache" && ! grep -q "$tree_a" "$cache" \
    && grep -q "waiting for another run" "$root/err-b"; then
    ok "lock: overlapping runs take turns; the failing tree fails and only the passing tree is recorded"
else
    cat "$root/err-a" "$root/err-b" > "$root/err"
    bad "lock: overlapping runs interfered (A exit $status_a, B exit $status_b)"
fi

# 9. The checkout moves on during a push: A (slow, passes) and B (fails) are pushed with HEAD at B; while A's
#    suite runs, the developer commits C, which fixes B. B must still be tested as B, fail, and not be recorded.
new_repo advance
swift_package
push || true
cache="$repo/.git/sprava-hooks/passed-trees"
printf 'let greeting = "SLOW but fine"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Slow and fine"
tree_a=$(git -C "$repo" rev-parse 'HEAD^{tree}')
printf 'let greeting = "FAIL"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Failing"
tree_b=$(git -C "$repo" rev-parse 'HEAD^{tree}')
(git -C "$repo" push -q origin HEAD:main > "$root/out-push" 2> "$root/err-push") &
run_push=$!
sleep 0.7
printf 'let greeting = "fixed"\n' > "$repo/Sources/Demo/Demo.swift"
git -C "$repo" add Sources && commit "Fix the failing commit"
status_push=0; wait "$run_push" || status_push=$?
if [ "$status_push" -ne 0 ] && grep -qx "swift $tree_a" "$cache" && ! grep -q "$tree_b" "$cache" \
    && grep -q "Swift tests failed for" "$root/err-push"; then
    ok "advance: a commit made during the push does not stand in for the failing pushed commit"
else
    cp "$root/err-push" "$root/err"
    bad "advance: the failing commit passed or was recorded (push exit $status_push)"
fi

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
