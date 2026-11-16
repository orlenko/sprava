import Foundation
import Services
import SpravaKit
import SwiftUI

/// A reply waiting on the person: may Claude, or a command it ran, reach a site this binder has not allowed
/// (conversation.md 18.3.1). The host is shown whole, never cut short.
struct SiteQuestionView: View {
    let question: ChatSiteQuestion
    let entry: BinderChat.Entry
    @ObservedObject var chat: BinderChat

    static func words(_ question: ChatSiteQuestion) -> (title: String, detail: String) {
        question.byCommand
            ? ("A command Claude ran wants to reach \(question.host).", "It could send this binder's files there.")
            : ("Claude wants to read \(question.host).", "Allowing it here lets Claude read it; a command it runs will ask again.")
    }

    var body: some View {
        let words = Self.words(question)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: words.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: words.detail).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Allow once") { answer(.once) }
                Button("Always for this binder") { answer(.always) }
                Button("Deny") { answer(.deny) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func answer(_ answer: ChatSiteAnswer) { Task { await chat.answer(question, answer, in: entry) } }
}

/// The sites a connected binder's Claude may reach without asking, in its settings, each with Remove. Read through the
/// runtime, which keeps them.
@MainActor
final class BinderSites: ObservableObject {
    struct Site: Equatable, Identifiable {
        let host: String
        let commands: Bool
        var id: String { host }
    }
    @Published private(set) var sites: [Site] = []
    @Published private(set) var message: String?
    @Published private(set) var busy = false
    private let client: RuntimeClient

    init(client: RuntimeClient) { self.client = client }

    nonisolated static func sites(_ value: JSONObject) -> [Site] {
        (value["sites"]?.arrayValue ?? []).prefix(200).compactMap { row in
            guard let host = row["host"]?.stringValue, (1...253).contains(host.utf8.count) else { return nil }
            return Site(host: host, commands: row["commands"] == .bool(true))
        }
    }

    func load(_ folder: URL) async { await run(folder, "chat_sites", []) }
    func remove(_ site: Site, in folder: URL) async { await run(folder, "chat_site_remove", [("host", .str(site.host))]) }

    private func run(_ folder: URL, _ command: String, _ fields: [(String, JSONValue)]) async {
        busy = true; defer { busy = false }
        do {
            sites = Self.sites(try await client.command(command, binder: folder, fields, timeout: 30))
            message = nil
        } catch {
            message = "Sprava could not read this binder's sites. Try again, or open Health."
        }
    }
}

struct BinderSitesList: View {
    @StateObject private var model: BinderSites
    let folder: URL

    init(client: RuntimeClient, folder: URL) {
        _model = StateObject(wrappedValue: BinderSites(client: client))
        self.folder = folder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sites Claude may reach").font(.callout.weight(.medium))
            if model.sites.isEmpty {
                Text("None yet. Claude asks the first time it needs a site.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.sites) { site in
                HStack(spacing: 8) {
                    Text(verbatim: site.host).textSelection(.enabled)
                    Text(site.commands ? "Claude and its commands" : "Claude reads").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { Task { await model.remove(site, in: folder) } }.controlSize(.small).disabled(model.busy)
                }
            }
            if let message = model.message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: folder) { await model.load(folder) }
    }
}
