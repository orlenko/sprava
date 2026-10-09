#!/bin/sh
# Points git at the versioned hooks in scripts/git-hooks (a local setting; run once per clone).
cd "$(dirname "$0")/.." && git config core.hooksPath scripts/git-hooks && echo "hooks installed: pre-commit (privacy scan, build of the staged snapshot), pre-push (tests of each pushed commit)"
