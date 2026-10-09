#!/bin/sh
# The companion suite, which the git hooks run for every commit that touches companion/ (scripts/git-hooks/suites.sh).
# Installs the pinned dev dependencies from each package's lockfile (the hooks test in a clean checkout), then runs
# that package's own `npm test`.
set -eu
cd "$(dirname "$0")"
for package in relay; do
    echo "companion/test.sh: $package"
    (cd "$package" && npm ci --no-audit --no-fund --prefer-offline --loglevel=error && npm test)
done
