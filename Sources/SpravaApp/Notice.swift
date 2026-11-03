import AppKit
import SwiftUI

enum NoticeLevel: Equatable {
    case info, needsYou, broken

    var color: Color {
        switch self {
        case .info: .secondary
        case .needsYou: Self.dynamic(light: 0xB75A00, dark: 0xFFA33A)
        case .broken: Self.dynamic(light: 0xC7320F, dark: 0xFF6F5A)
        }
    }
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .needsYou: "exclamationmark.circle.fill"
        case .broken: "exclamationmark.triangle.fill"
        }
    }
    var spoken: String {
        switch self {
        case .info: "Note"
        case .needsYou: "Needs you"
        case .broken: "Problem"
        }
    }

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// One way of saying that something needs a look (decisions.md D37): a bold sentence, a plain one, and the buttons that
/// deal with it. The words stay in the normal text colour, so the level's colour never has to carry them, and the
/// symbol says the level without colour. No `fixedSize` on the words: SwiftUI measures a window's minimum with almost no
/// width, so a fixed height there pushed the whole window above the top of the screen.
struct Notice<Actions: View>: View {
    let level: NoticeLevel
    let title: String
    var detail: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: level.symbol).foregroundStyle(level.color).accessibilityLabel(level.spoken)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title).font(.headline)
                    if let detail { Text(verbatim: detail) }
                }
                .textSelection(.enabled)
                if Actions.self != EmptyView.self {
                    HStack(spacing: 8) { actions() }.controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(level.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

extension Notice where Actions == EmptyView {
    init(level: NoticeLevel, title: String, detail: String? = nil) {
        self.init(level: level, title: title, detail: detail, actions: { EmptyView() })
    }
}
