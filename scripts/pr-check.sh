#!/bin/sh
# The shape of a branch, measured against where it really leaves main (docs/code-structure.md, rule 8):
# lines changed, domain targets touched, how far its base is behind main, changed Swift files over 400 lines, and
# new test files named after a review round. Run by pre-push for every pushed branch, and on demand:
#   ./scripts/pr-check.sh [<commit>]            (default HEAD)
# The first line is the summary a PR description quotes. Exits 1, after the report, when the branch changes more
# than 1,000 lines or touches more than one domain target (unless SPRAVA_ALLOW_LARGE=1), or adds a test file named
# after a review round. Main is the local origin/main (SPRAVA_MAIN_REF overrides it); this script never fetches.
set -eu
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
head=$(git rev-parse --verify -q "${1:-HEAD}^{commit}") || { echo "pr-check: ${1:-HEAD} is not a commit" >&2; exit 2; }
main_ref=${SPRAVA_MAIN_REF:-origin/main}
main=$(git rev-parse --verify -q "$main_ref^{commit}") || { echo "pr-check: no $main_ref to compare with; skipped" >&2; exit 0; }
base=$(git merge-base "$main" "$head") || { echo "pr-check: $head shares no history with $main_ref" >&2; exit 2; }

# The domain targets of layers 1 to 6. SpravaKit, Services and the executables are shared layers: a feature
# touches its domain target plus those (rule 1), so they are not counted.
domain='BinderFormat|BinderStore|Shelf|Extract|Clerk|Capture|Hub|Backup|Brains'
warn_lines=500; max_lines=1000; max_targets=1; stale_after=20; max_file=400
review_names='^Tests/(.*/)?[^/]*(AstraReview|Bugbot|CalibratedReview|LayerReview|ReviewRegression|CodexReview|StackReview)[^/]*\.swift$'

# Renames are detected, so a moved file counts only its edited lines. Binary files count as no lines.
numstat=$(git diff --numstat -M --no-ext-diff "$base" "$head")
added=$(printf '%s\n' "$numstat" | awk '$1 ~ /^[0-9]+$/ { n += $1 } END { print n + 0 }')
removed=$(printf '%s\n' "$numstat" | awk '$2 ~ /^[0-9]+$/ { n += $2 } END { print n + 0 }')
lines=$((added + removed))
# Paths are read NUL-delimited, so git never quotes a name (a non-ASCII one included); a name with a newline in it
# would split in two, which no Sprava file has.
names() { git diff -z --name-only --no-ext-diff "$base" "$head" "$@" | tr '\0' '\n'; }
# Every path a change touches, the old and the new name of a rename both.
paths=$(names --no-renames)
targets=$(printf '%s\n' "$paths" | sed -n -E "s#^Sources/($domain)/.*#\\1#p" | sort -u | tr '\n' ' ' | sed 's/ $//')
target_count=$(printf '%s' "$targets" | wc -w | tr -d ' ')
behind=$(git rev-list --count --first-parent "$base..$main")
new_files=$(names -M --diff-filter=AR)
review_named=$(printf '%s\n' "$new_files" | grep -E "$review_names" || true)
long_files=""
changed_swift=$(names -M --diff-filter=AMR -- '*.swift')
while IFS= read -r f; do
    [ -n "$f" ] || continue
    blob=$(git cat-file blob "$head:$f") || { echo "pr-check: cannot read $f at $head" >&2; exit 2; }
    n=$(printf '%s\n' "$blob" | wc -l | tr -d ' ')
    [ "$n" -le "$max_file" ] || long_files="$long_files$f ($n lines)
"
done <<EOF
$changed_swift
EOF
long_files=${long_files%
}

echo "+$added/-$removed in ${targets:-no domain target}, $target_count domain target(s), base $behind behind $main_ref"
status=0
if [ "$lines" -gt "$max_lines" ]; then
    echo "pr-check: $lines changed lines, over $max_lines: split the branch (SPRAVA_ALLOW_LARGE=1 lets it through)"
    [ "${SPRAVA_ALLOW_LARGE:-0}" = 1 ] || status=1
elif [ "$lines" -gt "$warn_lines" ]; then
    echo "pr-check: note: $lines changed lines, over $warn_lines"
fi
if [ "$target_count" -gt "$max_targets" ]; then
    echo "pr-check: touches $target_count domain targets ($targets): add an interface in the lower one and land it first (SPRAVA_ALLOW_LARGE=1 lets it through)"
    [ "${SPRAVA_ALLOW_LARGE:-0}" = 1 ] || status=1
fi
if [ "$behind" -gt "$stale_after" ]; then
    echo "pr-check: note: the base is $behind commits behind $main_ref; a PR diffed from an older main shows inherited changes, so rebase before opening it"
fi
if [ -n "$long_files" ]; then
    printf '%s\n' "$long_files" | sed 's/^/pr-check: note: over 400 lines: /'
fi
if [ -n "$review_named" ]; then
    printf '%s\n' "$review_named" | sed 's/^/pr-check: test file named after a review round: /'
    echo "pr-check: add the test to the file for the behavior it covers"
    status=1
fi
exit "$status"
