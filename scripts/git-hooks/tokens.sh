# Sourced by pre-commit and commit-msg, after each defines reject(): where the private-token list is, and
# whether it can be used. The list holds one extended regex per line, kept outside the repository (it is public).
tokens="${SPRAVA_PRIVATE_TOKENS:-$HOME/.config/sprava/private-tokens}"

# Sets tokens_state to present or absent, or rejects. Only a list that is certainly absent counts as absent:
# nothing at that path, not even a dangling symlink, and the nearest existing folder above it is searchable, so
# the absence is not a lookup that was denied. Anything at the path (a symlink of any kind included) must
# resolve to a readable regular file.
check_token_list() {
    tokens_state=absent
    if [ -e "$tokens" ] || [ -L "$tokens" ]; then
        { [ -f "$tokens" ] && [ -r "$tokens" ]; } \
            || reject "the private-token list at $tokens is not a readable file (or a symlink to one)"
        tokens_state=present
    else
        above=$(dirname "$tokens")
        while ! [ -e "$above" ] && ! [ -L "$above" ]; do above=$(dirname "$above"); done
        [ -d "$above" ] && [ -x "$above" ] \
            || reject "the private-token list at $tokens cannot be looked up: $above is not a searchable folder"
    fi
}
