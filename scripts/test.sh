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
export SPRAVA_SUPPORT_DIR CMIRROR_CONFIG

# Apple's Command Line Tools can import Testing but swiftbuild does not always find the TestingMacros
# plugin; pass it explicitly (the same workaround as holos, docs/toolchain.md there).
swiftc_path=$(xcrun --find swiftc)
plugin="${swiftc_path%/bin/swiftc}/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$plugin" ]; then
    exec swift test --build-system swiftbuild --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
fi
exec swift test --build-system swiftbuild --disable-xctest "$@"
