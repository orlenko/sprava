import BinderFormat
import Extract
import Foundation

/// The developer's document reader keeps the explicitly chosen root as its trust boundary, just as intake does
/// (docs/adaptation-layer.md §4). A document's parent is never promoted to a trusted root.
public enum DevelopmentDocumentReading {
    public static func read(_ relativePath: String, under root: URL, reader: ExtractHelper.Reader = .located()) -> IntakeReading {
        guard DocumentPaths.isIntake(relativePath) || DocumentPaths.isSafe(relativePath, forFiling: false) else {
            return IntakeReading(kind: "unknown", textFrom: "parsed", text: "",
                                 held: "the document needs a safe relative path under the chosen root", channel: "other")
        }
        return IntakeReading.read(root.appendingPathComponent(relativePath), in: root, channel: "other", reader: reader)
    }
}
