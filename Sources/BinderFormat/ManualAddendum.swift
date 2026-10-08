import Foundation
import SpravaKit

/// The manual addendum (binder-v0 §9.8, stricter as mvp.md question 13 asks): the person pastes it into a managed
/// binder's `CLAUDE.md` or `AGENTS.md`. Sprava never edits the manual. The first line is the marker the doctor
/// looks for.
public enum ManualAddendum {
    public static let marker = "<!-- sprava-managed v0 -->"

    public static let text = """
    \(marker)
    ## This binder is managed by Sprava

    This section overrides every older instruction in this file about `catalog.json`, `lifeproj drain`,
    `lifeproj publish` and `DASHBOARD.md`.

    - Never edit `catalog.json` by hand, not even to close an item or to add a log entry. Propose every change
      through Sprava's tools (`propose_ops`); the person approves it in the Sprava app.
    - To file a document, leave it in `intake/` and propose `file_document`; never move files into document
      folders yourself.
    - Do not run `lifeproj publish` or `lifeproj drain` in this binder. Sprava does both.
    - Edit `DASHBOARD.md` only below the line `## Notes`, and never regenerate it.

    """

    /// Whether the binder's manual carries the marker line (CLAUDE.md or AGENTS.md).
    public static func isPresent(in folder: URL) -> Bool? {
        var sawManual = false
        for name in ["CLAUDE.md", "AGENTS.md"] {
            guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(name), limit: 1024 * 1024) else { continue }
            sawManual = true
            if String(decoding: data, as: UTF8.self).contains(marker) { return true }
        }
        return sawManual ? false : nil
    }
}
