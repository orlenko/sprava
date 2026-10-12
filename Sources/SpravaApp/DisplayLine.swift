/// Displayed text never supplies a SwiftUI identity: duplicate-ID diagnostics must carry only positions,
/// never a private title or note (architecture 3.7). Repeated lines are kept as separate rows.
struct DisplayLine: Identifiable {
    let id: Int
    let text: String

    static func rows(_ text: [String]) -> [DisplayLine] {
        text.enumerated().map { DisplayLine(id: $0.offset, text: $0.element) }
    }
}
