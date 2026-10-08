import Foundation

/// A read-only reading of lifeproj's binder registry, which is cmirror's `config.toml`
/// (lifeproj `registry.py`): live binders under `[projects.<name>]`, archived ones under `[archived.<name>]`,
/// each with a `working_dir`. Sprava never writes this file.
public struct LifeprojRegistry: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let workingDir: String?
        public let archived: Bool
    }

    public let entries: [Entry]

    /// `$CMIRROR_CONFIG`, else `~/.config/cmirror/config.toml`, as lifeproj resolves it.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let env = environment["CMIRROR_CONFIG"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cmirror/config.toml")
    }

    public static func load(from url: URL) throws -> LifeprojRegistry {
        try parse(String(contentsOf: url, encoding: .utf8))
    }

    /// A minimal TOML reader for the subset lifeproj writes: table headers, `key = "string"` pairs and comments.
    /// Anything else is skipped.
    public static func parse(_ text: String) -> LifeprojRegistry {
        var entries: [Entry] = []
        var current: (section: String, name: String)?
        var workingDir: String?

        func flush() {
            if let current {
                entries.append(Entry(name: current.name, workingDir: workingDir, archived: current.section == "archived"))
            }
            current = nil
            workingDir = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                flush()
                guard !line.hasPrefix("[["), let close = line.lastIndex(of: "]") else { continue }
                let header = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                let parts = splitDotted(header)
                if parts.count == 2, parts[0] == "projects" || parts[0] == "archived" {
                    current = (parts[0], parts[1])
                }
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if unquote(key) == "working_dir" { workingDir = parseString(value) }
        }
        flush()
        return LifeprojRegistry(entries: entries)
    }

    static func splitDotted(_ header: String) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var quote: Character?
        for ch in header {
            if let q = quote {
                if ch == q { quote = nil } else { buffer.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "." {
                parts.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = ""
            } else {
                buffer.append(ch)
            }
        }
        parts.append(buffer.trimmingCharacters(in: .whitespaces))
        return parts
    }

    static func unquote(_ key: String) -> String {
        if key.count >= 2, let f = key.first, f == key.last, f == "\"" || f == "'" {
            return String(key.dropFirst().dropLast())
        }
        return key
    }

    /// A TOML basic ("...") or literal ('...') string; nil for anything else.
    static func parseString(_ value: String) -> String? {
        guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }
        var out = ""
        var escaping = false
        for ch in value.dropFirst() {
            if quote == "'" {
                if ch == "'" { return out }
                out.append(ch)
                continue
            }
            if escaping {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\\": out.append("\\")
                case "\"": out.append("\"")
                default: out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == "\"" {
                return out
            } else {
                out.append(ch)
            }
        }
        return nil
    }
}
