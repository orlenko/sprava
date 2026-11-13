// What the app shows at its foot: the release it was built from, and the commit (docs/companion.md §9).
// The publishing workflow passes the release's tag in SPRAVA_RELEASE; a local build shows the package version.
export function releaseInfo(env: Record<string, string | undefined>, packageVersion: string,
    commit: string): { version: string; commit: string } {
    const version = env.SPRAVA_RELEASE || packageVersion;
    if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/.test(version))
        throw new Error('SPRAVA_RELEASE must be a release tag: letters, digits, dots, dashes, plus signs, underscores.');
    if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error('The commit must be a full lowercase hex SHA-1.');
    return { version, commit };
}
