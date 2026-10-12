#!/bin/sh
# Which test targets a change needs (AGENTS.md, step 3), from the package's own target graph:
#   ./scripts/affected-tests.sh <base> <head>        run at the top of a checkout of <head>
# Prints one line: ALL (the whole suite: the package itself, the test runner, resources or a Swift file outside
# any target changed), NONE (no target changed), or a `swift test --filter` pattern such as
# `ShelfTests|HubTests`: the test targets of every changed target and of every target that depends on one,
# directly or not. Shared test support counts as a target, so its dependents are tested too.
set -eu
base=$1; head=$2
changed=$(git diff -z --name-only --no-renames --no-ext-diff "$base" "$head" | tr '\0' '\n')
[ -n "$changed" ] || { echo NONE; exit 0; }
if printf '%s\n' "$changed" | grep -qE '^(Package\.(swift|resolved)|scripts/test\.sh|Resources/)'; then echo ALL; exit 0; fi
package=$(swift package dump-package 2>/dev/null) || { echo ALL; exit 0; }
printf '%s\n' "$changed" | python3 -c '
import json, sys
package = json.loads(sys.argv[1])
targets = {}
for t in package["targets"]:
    deps = [list(d.values())[0][0] for d in t.get("dependencies", [])]
    folder = "Tests" if t["type"] == "test" else "Sources"
    targets[t["name"]] = {"type": t["type"], "deps": deps, "path": (t.get("path") or f"{folder}/{t['"'"'name'"'"']}").rstrip("/") + "/"}
changed = set()
for path in sys.stdin.read().splitlines():
    owner = next((n for n, t in targets.items() if path.startswith(t["path"])), None)
    if owner:
        changed.add(owner)
    elif path.endswith(".swift"):
        print("ALL"); sys.exit(0)
affected = set(changed)
grew = True
while grew:
    grew = False
    for name, t in targets.items():
        if name not in affected and affected.intersection(t["deps"]):
            affected.add(name); grew = True
tests = sorted(n for n in affected if targets[n]["type"] == "test")
print("|".join(tests) if tests else "NONE")
' "$package"
