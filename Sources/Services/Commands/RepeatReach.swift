import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Whether the person may set a repeat in a binder (decisions.md F3, 2026-11-15; binder-v0 §8.1). lifeproj's drain
/// closes a repeating item for good, so a binder lifeproj can still reach gets no repeats; the app shows why before the
/// person tries, and every write the runtime makes for the person checks again.
extension Commands {
    /// Why no repeat may be set in `folder`, in words the person can act on; nil when lifeproj cannot reach it.
    /// A registry that exists but cannot be read, or names a folder in a form Sprava's small reader does not take
    /// whole, counts as one that may list the binder.
    static func repeatsRefusal(_ folder: URL, registryURL: URL = LifeprojRegistry.defaultPath()) -> String? {
        let here = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var inRegistry = false
        if FileManager.default.fileExists(atPath: registryURL.path) {
            guard case .ok(let data) = SafeFile.read(registryURL, limit: 1 << 20), let text = String(data: data, encoding: .utf8),
                  let folders = registeredFolders(text) else {
                return "Repeats are off here: Sprava could not read lifeproj's registry, so it cannot tell whether lifeproj still manages this binder."
            }
            inRegistry = folders.contains {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path == here
            }
        }
        let tail = " lifeproj would end a repeating to-do the first time it was checked off."
        if inRegistry {
            return "Repeats are off here: this binder is still in lifeproj's registry." + tail
                + " Take it out of lifeproj's registry to use repeats."
        }
        guard Adoption.lifeprojCanReach(folder, inRegistry: false) else { return nil }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("catalog_check.py").path) {
            return "Repeats are off here: the binder's folder holds lifeproj's catalog_check.py." + tail
                + " Move that file out of the binder's folder to use repeats."
        }
        return "Repeats are off here: the binder's CLAUDE.md or AGENTS.md tells coding agents to run lifeproj publish or drain." + tail
            + " Remove those lines to use repeats."
    }

    /// Every folder the registry names, read line by line whatever table a line sits in, so no header, comment or table
    /// form can hide one: a `working_dir` anywhere counts. Nil when a line that mentions `working_dir` is not exactly
    /// `working_dir = "<path>"` or `'<path>'` on one line with no escape (an escape, a multi-line string, an inline table
    /// or a dotted key could name a folder this reader would misread), so such a registry counts as listing the binder.
    static func registeredFolders(_ text: String) -> [String]? {
        var folders: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.contains("working_dir") else { continue }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard ["working_dir", "\"working_dir\"", "'working_dir'"].contains(key), let quote = value.first, quote == "\"" || quote == "'",
                  !value.hasPrefix("\"\"\""), !value.hasPrefix("'''"), !value.contains("\\") else { return nil }
            let body = value.dropFirst()
            guard let end = body.firstIndex(of: quote) else { return nil }
            folders.append(String(body[..<end]))
        }
        return folders
    }
}
