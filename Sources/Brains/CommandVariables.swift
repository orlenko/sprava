import Foundation

/// The environment a binder's commands run with (decisions.md D50): what the person's login shell exports, so a script
/// finds an API key under the name the person already keeps it by. Every command the session runs gets the values as
/// they are. That is the person's choice and its cost: the agent can read a value, and a command can send one to any
/// site the binder allows.
///
/// A name Sprava sets itself is left out, since the session's walls and its way out are built from those: the proxy, the
/// home, the path, the agent's own account. So is a name that makes every shell run a file first, and what describes the
/// person's own terminal and not their setup.
package enum CommandVariables {
    package static let maximumCount = 512
    package static let maximumNameBytes = 128
    package static let maximumValueBytes = 8 * 1024
    package static let maximumBytes = 256 * 1024

    static let reserved: Set<String> = [
        "PATH", "HOME", "LANG", "TMPDIR", "DEVELOPER_DIR", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
        "NODE_USE_ENV_PROXY", "BASH_DEFAULT_TIMEOUT_MS", "DISABLE_TELEMETRY", "BASH_ENV", "ENV", "ZDOTDIR", "SHELL", "IFS",
        // The terminal the values were read in, which a command does not run in.
        "PWD", "OLDPWD", "SHLVL", "_", "COLUMNS", "LINES", "DISPLAY", "SSH_AUTH_SOCK", "SECURITYSESSIONID", "COMMAND_MODE",
        "MALLOCNANOZONE", "LAUNCHINSTANCEID",
    ]
    static let reservedPrefixes = ["CLAUDE_", "CLAUDECODE", "ANTHROPIC_", "DYLD_", "LD_", "LC_", "TERM", "XPC_", "__", "ITERM_"]

    /// Whether a name can be given to commands: one the shell can hold, and none Sprava sets or leaves out.
    package static func takes(name: String) -> Bool {
        let bytes = Array(name.utf8)
        func letter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 }
        guard let first = bytes.first, bytes.count <= maximumNameBytes, letter(first),
              bytes.allSatisfy({ letter($0) || ($0 >= 48 && $0 <= 57) }) else { return false }
        let upper = name.uppercased()
        return !reserved.contains(upper) && !reservedPrefixes.contains(where: upper.hasPrefix)
    }

    /// Whether a value can be given to commands: one line of text within the limit, as a key or a setting is. A shell
    /// function or a certificate held in a variable has several lines and is left out.
    package static func takes(value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumValueBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
    }

    /// What of an environment goes to commands: every variable whose name and value are taken, in the order of their
    /// names up to the limits, so the same environment always gives the same set.
    package static func passable(_ environment: [String: String]) -> [String: String] {
        var kept: [String: String] = [:]
        var bytes = 0
        for name in environment.keys.sorted() where kept.count < maximumCount {
            guard let value = environment[name], takes(name: name), takes(value: value) else { continue }
            let size = name.utf8.count + value.utf8.count
            guard bytes + size <= maximumBytes else { continue }
            bytes += size
            kept[name] = value
        }
        return kept
    }

    /// The file the CLI runs before each command: one `export` a line, each value in single quotes with its own single
    /// quotes closed, escaped and reopened, so the shell takes every byte as it is. Names in order, so the same set
    /// writes the same file.
    package static func script(_ variables: [String: String]) -> String {
        variables.keys.sorted().map { "export \($0)='\(variables[$0]!.replacingOccurrences(of: "'", with: "'\\''"))'\n" }.joined()
    }

    /// Whether a whole set can be given to a session's commands: only what `passable` would keep.
    package static func usable(_ variables: [String: String]) -> Bool {
        passable(variables).count == variables.count
    }
}
