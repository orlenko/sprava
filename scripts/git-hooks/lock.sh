# Shared by the hooks (sourced, not run): an exclusive lock held on descriptor 9 of the calling shell.
# The lock is flock(2) on the open file, taken with flock(1) where it exists and with perl otherwise (macOS has
# no flock command). It belongs to the shell's descriptor, so it outlives the helper that took it and is
# released by release_lock or when the shell exits, however it exits. Commands that may leave processes behind
# (a build, a test run) must be started with 9>&- so they do not keep the lock alive.

hold_lock() {    # <lock file> <name for messages>
    exec 9>>"$1"
    if command -v flock >/dev/null 2>&1; then
        flock -n 9 || { echo "$2: waiting for another run that holds $1" >&2; flock 9; }
    else
        perl -MFcntl=:flock -e '
            open(my $f, ">&=", 9) or die "$!\n";
            flock($f, LOCK_EX | LOCK_NB) and exit 0;
            print STDERR "$ARGV[0]: waiting for another run that holds $ARGV[1]\n";
            flock($f, LOCK_EX) or die "$!\n";
        ' "$2" "$1"
    fi
}

release_lock() { exec 9>&-; }
