import BinderFormat
import Foundation
import SpravaKit

/// What a turn is doing, in a few words the person can read while it runs. It lives in memory for the turn only: never
/// logged, never saved and never sent to the model. A tool's input comes from the model and may repeat what a document
/// says, so what is taken from it is made one short line, and it is only ever displayed as text.
package struct ClaudeTurnActivity: Sendable, Equatable {
    package private(set) var doing: String?
    package private(set) var steps = 0
    /// WebSearch calls this turn, for its summary line.
    package private(set) var searches = 0
    /// The files this turn's commands started, as the commands wrote them, each once: the caller checks each against
    /// the binder and counts the scripts among them (decisions.md D47). Kept for the turn, never logged.
    package private(set) var ran: [String] = []
    static let maximumRan = 20

    package init() {}

    mutating func saw(_ blocks: [JSONValue]) {
        for block in blocks {
            if block["type"] == .str("tool_use"), let name = block["name"]?.stringValue {
                steps += 1
                if name == "WebSearch" { searches += 1 }
                if name == "Bash", let command = block["input"]?["command"]?.stringValue {
                    for path in Self.started(by: command) where ran.count < Self.maximumRan && !ran.contains(path) { ran.append(path) }
                }
                doing = Self.words(tool: name, input: block["input"])
            } else if block["type"] == .str("text") {
                doing = "Writing"
            } else if block["type"] == .str("thinking") || block["type"] == .str("redacted_thinking") {
                doing = "Thinking"
            }
        }
    }

    mutating func toolFinished() { doing = "Thinking" }

    static func words(tool: String, input: JSONValue?) -> String {
        // The model picks this path, and its length: the name is cut by scalars, not characters (one character can
        // carry any number of combining marks), before anything normalizes it.
        let file = (input?["file_path"]?.stringValue).map { name in
            String(String.UnicodeScalarView((name as NSString).lastPathComponent.unicodeScalars.prefix(limitBeforeCleaning)))
        }.flatMap { $0.isEmpty ? nil : short(DocumentPaths.safeName($0), 60) }
        switch tool {
        case "Read": return file.map { "Reading \u{201C}\($0)\u{201D}" } ?? "Reading a file"
        case "Write", "Edit": return file.map { "Changing \u{201C}\($0)\u{201D}" } ?? "Changing a file"
        case "Glob": return "Looking through the folders"
        case "Grep": return "Searching the binder"
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading a web page"
        case "Bash": return input?["description"]?.stringValue.flatMap { let said = short($0, 90); return said.isEmpty ? nil : said } ?? "Running a command"
        case _ where tool.hasSuffix("search_binder"): return "Searching the documents"
        case _ where tool.hasSuffix("update_notes"): return "Updating the notes"
        case _ where tool.contains(ClaudeAppTools.server): return "Updating the to-dos"
        default: return "Working"
        }
    }

    private static let interpreters: Set<String> = ["python", "python3", "bash", "sh", "zsh", "node", "ruby", "perl", "swift", "osascript", "php"]
    private static let wrappers: Set<String> = ["time", "nohup", "exec", "command", "env"]

    private static let shells: Set<String> = ["bash", "sh", "zsh"]

    /// Whether an option makes this interpreter run nothing from the file it is given: a check of its syntax
    /// (`bash -n`, `node --check`, `ruby -c`, `perl -c`, `php -l`, `swift -typecheck`), or code or a module given in
    /// the file's place (`python -c`, `python -m`, `node -e`, `perl -e`). An option not known here is taken as
    /// harmless, and a file then counts; one wrongly listed only loses a count.
    private static func startsNothing(_ interpreter: String, _ option: String) -> Bool {
        switch interpreter {
        case "bash", "sh", "zsh":
            // A cluster of short options with n in it (-n, -nv, -xn) is noexec.
            return option.hasPrefix("--") ? ["--dump-strings", "--dump-po-strings"].contains(option) : option.contains("n") || option.contains("D")
        case "python": return ["-c", "-m"].contains(option)
        case "node": return ["-c", "--check", "-e", "--eval", "-p", "--print"].contains(option)
        case "ruby", "perl": return ["-c", "-wc", "-cw", "-e", "-E"].contains(option)
        case "php": return ["-l", "--syntax-check", "-r"].contains(option)
        case "swift": return ["-typecheck", "-parse", "-frontend", "-e"].contains(option)
        case "osascript": return option == "-e"
        default: return false
        }
    }

    /// The files a shell command starts: in each part between `;`, `|`, `&`, a line break or a parenthesis, the first
    /// word when it is a path, or the first word after an interpreter that is no option. The shell's quotes are
    /// respected, so a separator or a space inside quotes belongs to its word: `echo 'a; scripts/a.sh'` starts
    /// nothing. A shell given `-c` and a quoted command is read once more, so `bash -c "scripts/a.sh"` is found.
    /// A path with a space in it is left out, so an interpreter's quoted code is never taken for one. An interpreter
    /// told only to check the file (`bash -n scripts/a.sh`), or given code or a module in its place, starts nothing.
    /// Reading the model's own command by rule, never running or expanding anything; the result is at most a count.
    package static func started(by command: String, nested: Bool = false) -> [String] {
        var found: [String] = []
        var parts: [[String]] = [[]], word = "", open = false, quote: Character?
        func end() { if open { parts[parts.count - 1].append(word); word = ""; open = false } }
        for c in String(String.UnicodeScalarView(command.unicodeScalars.prefix(8_000))) {
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c; open = true
            } else if ";|&()\n\r".contains(c) {
                end(); parts.append([])
            } else if c == " " || c == "\t" {
                end()
            } else {
                word.append(c); open = true
            }
        }
        end()
        func assignment(_ word: String) -> Bool {
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
            return word[..<equals].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
        for part in parts {
            var words = part[...]
            while let first = words.first, assignment(first) || wrappers.contains(first) { words = words.dropFirst() }
            guard let first = words.first else { continue }
            let program = (first as NSString).lastPathComponent, rest = words.dropFirst()
            var candidate: String? = first
            // The interpreter's name without a version: python3.12 is python, bash5 is bash.
            let base = interpreters.contains(program) ? program
                : interpreters.filter { program.hasPrefix($0) && program.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." } }.max { $0.count < $1.count }
            if let base = base.map({ $0 == "python3" ? "python" : $0 }) {
                // The options before the file decide whether it runs: one that only checks it, or that takes code or a
                // module in the file's place, starts nothing from a path.
                candidate = nil
                var index = rest.startIndex, inner: String?
                while index < rest.endIndex {
                    let word = rest[index]
                    index = rest.index(after: index)
                    guard word.hasPrefix("-") else { candidate = word; break }
                    if startsNothing(base, word) { break }
                    guard shells.contains(base), !word.hasPrefix("--") else { continue }
                    if word.hasSuffix("o") {
                        // `-o name` sets an option: noexec reads the script and runs none of it.
                        if index < rest.endIndex, rest[index] == "noexec" { break }
                        if index < rest.endIndex { index = rest.index(after: index) }
                    } else if word.hasSuffix("c") {
                        if index < rest.endIndex { inner = rest[index] }
                        break
                    }
                }
                if let inner, !nested {
                    for path in started(by: inner, nested: true) where !found.contains(path) && found.count < maximumRan { found.append(path) }
                    continue
                }
            } else if !first.contains("/") {
                candidate = nil
            }
            guard var path = candidate else { continue }
            while path.hasPrefix("./") { path.removeFirst(2) }
            guard !path.isEmpty, path.utf8.count <= 300, !path.hasPrefix("-"), !path.hasPrefix("~"), !path.contains("$"),
                  !path.contains(where: \.isWhitespace), !found.contains(path) else { continue }
            found.append(path)
            if found.count >= maximumRan { break }
        }
        return found
    }

    private static let limitBeforeCleaning = 400

    /// One line: no control or direction character, runs of space closed up, cut at a character's edge.
    private static func short(_ text: String, _ limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars.prefix(limitBeforeCleaning * 4) {
            let c = s.properties.generalCategory
            scalars.append(c == .control || c == .format || c == .lineSeparator || c == .paragraphSeparator ? " " : s)
        }
        let line = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "\u{2026}" : line
    }
}
