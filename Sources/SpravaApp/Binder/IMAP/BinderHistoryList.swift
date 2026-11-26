import SpravaKit
import SwiftUI

/// The binder's History shows each draft's placement separately from approval of the original card.
struct BinderHistoryList<Content: View>: View {
    let folder: URL
    let client: RuntimeClient
    let adopted: Bool
    @ViewBuilder let content: Content
    struct Row: Identifiable {
        let id: String
        let subject: String
        let line: String
    }
    @State private var rows: [Row] = []
    @State private var failed = false

    static func row(_ value: JSONValue) -> Row? {
        guard let id = value["id"]?.stringValue, let subject = value["subject"]?.stringValue else { return nil }
        let line: String
        switch value["status"]?.stringValue {
        case "matched":
            if let differences = value["differences"]?.arrayValue,
               differences.allSatisfy({ ["recipients", "subject", "body", "attachments"].contains($0.stringValue ?? "") }) {
                line = differences.isEmpty ? "Recipient addresses, subject, body text and attachment contents match the approved draft." : "Changed in Drafts: " + differences.compactMap(\.stringValue).joined(separator: ", ")
            } else { line = "Sprava could not compare this draft." }
        case "missing": line = "Placed. The draft could not be found on the last check."
        case "ambiguous": line = "Placed. Several messages matched this draft."
        case "pending": line = "Placed. Waiting to check the copy in Drafts."
        default: line = "Placed. Sprava could not compare the copy in Drafts."
        }
        return Row(id: id, subject: subject.isEmpty ? "Email draft" : subject, line: line)
    }

    var body: some View {
        List {
            if !rows.isEmpty || failed {
                Section("Placed email drafts") {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.subject)
                            Text(verbatim: row.line).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if failed { Text("Draft placement history could not be read.").foregroundStyle(.secondary) }
                }
            }
            content
        }
        .task(id: adopted) {
            guard adopted else { rows = []; failed = false; return }
            repeat {
                do {
                    let answer = try await client.command("imap_draft_history", binder: folder)
                    guard !Task.isCancelled else { return }
                    if let placed = answer["placements"]?.arrayValue { rows = placed.compactMap(Self.row) }
                    failed = false
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true
                }
                try? await Task.sleep(for: .seconds(15))
            } while !Task.isCancelled
        }
    }
}
