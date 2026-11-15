import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Whether the person may set a repeat in a binder (decisions.md F3, 2026-11-15; binder-v0 §8.1). lifeproj's drain
/// closes a repeating item for good, so a binder lifeproj can still reach gets no repeats; the app shows why before the
/// person tries, and every write the runtime makes for the person checks again.
extension Commands {
    /// Why no repeat may be set in `folder`, in words the person can act on; nil when lifeproj cannot reach it.
    /// A registry that exists but cannot be read counts as one that may list the binder.
    static func repeatsRefusal(_ folder: URL, registryURL: URL = LifeprojRegistry.defaultPath()) -> String? {
        let here = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var inRegistry = false
        if FileManager.default.fileExists(atPath: registryURL.path) {
            guard let registry = try? LifeprojRegistry.load(from: registryURL) else {
                return "Repeats are off here: Sprava could not read lifeproj's registry, so it cannot tell whether lifeproj still manages this binder."
            }
            inRegistry = registry.entries.contains { entry in
                entry.workingDir.map {
                    URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
                        .standardizedFileURL.resolvingSymlinksInPath().path == here
                } ?? false
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
}
