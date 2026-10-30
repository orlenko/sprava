#!/bin/sh
# Checks Claude Code's view of the installed Sprava MCP server the way a person would: starts a real Claude Code session
# in a detached tmux pane, opens /mcp, selects the sprava entry and prints what the panel says (status, protocol,
# tools, issue). It reads no token and calls no tool; Claude Code passes its own configured token to sprava-mcp.
#
#   claude-mcp-probe.sh [<claude config dir>...]
#
# With no argument it checks the config dir Claude Code uses by default (CLAUDE_CONFIG_DIR, else ~/.claude). With
# several, one after another, for people who keep more than one Claude profile. Exit 0 when every one shows sprava
# connected with tools, 1 otherwise. Needs tmux and claude (CLAUDE_BIN, else ~/.local/bin/claude, else PATH).
set -eu

claude_bin=${CLAUDE_BIN:-}
if [ -z "$claude_bin" ]; then
    if [ -x "$HOME/.local/bin/claude" ]; then claude_bin=$HOME/.local/bin/claude; else claude_bin=$(command -v claude); fi
fi
command -v tmux >/dev/null || { echo "claude-mcp-probe: tmux is not installed" >&2; exit 2; }
[ $# -gt 0 ] || set -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
jobs_log="$HOME/Library/Application Support/Sprava/runtime/jobs.log"

work=$(mktemp -d "${TMPDIR:-/tmp}/sprava-mcp-probe.XXXXXX")
session=sprava-mcp-probe-$$
trap 'tmux kill-session -t "$session" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM

screen() { tmux capture-pane -p -t "$session" 2>/dev/null || true; }

# Waits up to $2 seconds for the pane to show the extended regex $1.
await() {
    i=0
    while [ "$i" -lt "$2" ]; do
        screen | grep -Eq "$1" && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

probe() {
    config=$1
    started=$(date +%Y-%m-%dT%H:%M:%S)
    tmux kill-session -t "$session" 2>/dev/null || true
    # Orchestra and pair hooks stay inert in this throwaway session.
    tmux new-session -d -s "$session" -x 160 -y 60 -c "$work" \
        "env CLAUDE_CONFIG_DIR='$config' AGENT_ORCHESTRA_NO_WAIT=1 AGENT_PAIR_NO_WAIT=1 '$claude_bin'"
    await 'trust this folder|^❯' 60 || { echo "$config: Claude Code did not start"; return 1; }
    if screen | grep -q 'trust this folder'; then
        tmux send-keys -t "$session" Down Enter
        await '^❯' 60 || { echo "$config: Claude Code did not start"; return 1; }
    fi
    tmux send-keys -t "$session" '/mcp'
    sleep 1
    tmux send-keys -t "$session" Enter
    await ' sprava( |$)' 30 || { echo "$config: no sprava entry in /mcp"; return 1; }
    # The entry reads "… sprava" while connecting.
    i=0
    while [ "$i" -lt 30 ] && screen | grep -Eq '… sprava'; do sleep 1; i=$((i + 1)); done
    # Moves the cursor down to the sprava entry and opens it.
    n=0
    while [ "$n" -lt 40 ] && ! screen | grep -Eq '❯ .{0,3}sprava( |$)'; do tmux send-keys -t "$session" Down; sleep 0.3; n=$((n + 1)); done
    tmux send-keys -t "$session" Enter
    await 'Status:' 15 || { echo "$config: the sprava entry did not open"; return 1; }
    sleep 1
    detail=$(screen | sed -n '/Status:/,/Reconnect\|Enable\|Disable/p' | grep -v -E 'Reconnect|Enable|Disable|View tools|^ *$')
    echo "== $config"
    echo "$detail" | sed 's/^ */  /'
    # The runtime's side of the same attempt: the handshake used, or why it refused (the panel names no reason).
    if [ -f "$jobs_log" ]; then
        awk -v since="$started" '$1 >= since && / mcp /' "$jobs_log" | sed 's/^/  runtime: /' | tail -n 5
    fi
    echo "$detail" | grep -q 'Status: *✔ connected' && echo "$detail" | grep -Eq 'Tools: *[1-9]'
}

failed=0
for config in "$@"; do
    probe "$config" || failed=1
done
exit "$failed"
