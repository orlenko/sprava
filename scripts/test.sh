#!/bin/sh
# Run the Swift Testing suites. Sprava's own state goes to a temporary folder, so tests never touch
# ~/Library/Application Support/Sprava, and no test reads a real binder.
set -eu

test_root=$(mktemp -d "${TMPDIR:-/tmp}/sprava-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SPRAVA_SUPPORT_DIR="$test_root/Support"
CMIRROR_CONFIG="$test_root/no-registry.toml"
# The backup key goes to a file, never to the person's Keychain.
SPRAVA_BACKUP_KEY_FILE="$test_root/backup-key"
export SPRAVA_SUPPORT_DIR CMIRROR_CONFIG SPRAVA_BACKUP_KEY_FILE

# Apple's Command Line Tools can import Testing but swiftbuild does not always find the TestingMacros
# plugin; pass it explicitly (the same workaround as holos, docs/toolchain.md there).
swiftc_path=$(xcrun --find swiftc)
plugin="${swiftc_path%/bin/swiftc}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
run() {
    if [ -f "$plugin" ]; then
        swift test --build-system swiftbuild --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
    else
        swift test --build-system swiftbuild --disable-xctest "$@"
    fi
}

# Every test target runs as its own Swift Testing run, each with its own "Test run with" line. The last line adds
# them up, so one line says whether every target passed.
log="$test_root/test.log"
{ run "$@" 2>&1 && echo 0 > "$test_root/status" || echo $? > "$test_root/status"; } | tee "$log"
status=$(cat "$test_root/status")
runs=$(grep -c "Test run with [0-9]* test" "$log" || true)
failed=$(grep -c "Test run with [0-9]* test.* failed" "$log" || true)
tests=$(grep -o "Test run with [0-9]* test" "$log" | awk '{ n += $4 } END { print n + 0 }')
# A run that found no tests at all fails too: it would hide a test-discovery or macro-loading regression.
if [ "$status" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$runs" -gt 0 ] && [ "$tests" -gt 0 ]; then
    echo "All test runs passed: $tests tests in $runs test target(s)."
else
    echo "Tests failed: $failed of $runs test runs failed, $tests tests ran (swift test exit status $status)." >&2
    exit 1
fi
