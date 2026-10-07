import AppKit
import Combine
import SpravaCore
import SwiftUI

/// The capture inbox (mvp.md feature 4): typed notes become capture events in Sprava's own device folder, the
/// runtime turns each into a Tier 0 card within its next sweep, and cards with no binder wait here until the
/// person picks one.
@MainActor
final class InboxModel: ObservableObject {
    struct Card: Identifiable {
        let id: String
        let title: String
        let lines: [String]
        let createdAt: Date?
        let unverified: Bool
        let isPrivate: Bool
        let corrected: Bool
        let retracted: Bool
        let producer: String
        let notes: [String]
        let notFiled: [String]
    }

    @Published var cards: [Card] = []
    @Published var draft = ""
    @Published var draftBinder: URL?
    @Published var target: [String: URL] = [:]
    @Published var message: String?
    @Published var saving = false
    var startedTyping: Date?
    let client = RuntimeClient()

    func load() async {
        do {
            let r = try await client.global("unfiled", timeout: 5)
            cards = (r["cards"]?.arrayValue ?? []).compactMap { c in
                guard let id = c["id"]?.stringValue else { return nil }
                return Card(id: id, title: c["title"]?.stringValue ?? "", lines: c["lines"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            createdAt: ISOTime.date(c["created_at"]?.stringValue), unverified: c["unverified_source"] == .bool(true),
                            isPrivate: c["private"] == .bool(true), corrected: c["source_corrected"] == .bool(true),
                            retracted: c["source_retracted"] == .bool(true), producer: c["producer"]?.stringValue ?? "?",
                            notes: c["notes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            notFiled: c["not_filed"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            }
        } catch { message = "\(error)" }
    }

    /// Writes the note as a capture event (capture-event-v0 §8.1), then tells the runtime its id and digest, so
    /// the binder the person chose is trusted (architecture 8).
    func save(binderName: String?) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        saving = true
        let support = SpravaPaths.supportDirectory()
        let producer = CaptureProducer(root: CaptureInbox.defaultRoot(support: support), deviceID: DeviceID.load(support: support),
                                       support: support)
        Task {
            defer { saving = false }
            do {
                // The notice goes first, so the runtime trusts the binder the person chose (architecture 8).
                let note = try producer.prepareNote(text, binderHint: binderName, startedAt: startedTyping ?? Date())
                var noticed = true
                do {
                    _ = try await client.global("capture_notice", [("event", .string(note.id)), ("sha256", .string(note.digest))], timeout: 5)
                } catch {
                    noticed = false
                }
                try producer.publish(note)
                draft = ""
                startedTyping = nil
                message = !noticed ? "Saved, but the runtime did not answer, so the card will ask for a binder."
                    : binderName == nil ? "Saved. Its card will appear here in a moment." : "Saved. Its card will appear in the binder in a moment."
                try? await Task.sleep(for: .seconds(2))
                await load()
            } catch {
                message = "The note was not saved: \(error)"
            }
        }
    }

    func file(_ card: Card) {
        guard let folder = target[card.id] else { return }
        Task {
            do {
                _ = try await client.command("file_card", binder: folder, [("card", .string(card.id))])
                message = "Filed. Review it on the binder's page."
            } catch { message = "\(error)" }
            await load()
        }
    }

    func discard(_ card: Card) {
        Task {
            do { _ = try await client.global("discard_card", [("card", .string(card.id))]) } catch { message = "\(error)" }
            await load()
        }
    }
}

struct InboxView: View {
    @ObservedObject var model: InboxModel
    let rows: [ShelfRow]

    var adopted: [ShelfRow] { rows.filter { $0.teka.isAdopted && !$0.teka.writesBlocked } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Inbox").font(.largeTitle).bold()
                GroupBox("New note") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.draft)
                            .font(.body)
                            .frame(minHeight: 80)
                            .onChange(of: model.draft) { _, new in
                                if model.startedTyping == nil, !new.isEmpty { model.startedTyping = Date() }
                            }
                        Text("One line per thing to do. Sprava files it without a model; you approve every card.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("Binder", selection: $model.draftBinder) {
                                Text("Not sure").tag(URL?.none)
                                ForEach(adopted, id: \.folder) { row in Text(row.name).tag(URL?.some(row.folder)) }
                            }
                            .frame(maxWidth: 320)
                            Spacer()
                            Button("Save Note") {
                                model.save(binderName: adopted.first { $0.folder == model.draftBinder }?.name)
                            }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.saving || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(4)
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Text("Waiting for a binder (\(model.cards.count))").font(.headline)
                if model.cards.isEmpty {
                    Text("Nothing waiting. Notes and dictations with no binder land here.").foregroundStyle(.secondary)
                }
                ForEach(model.cards) { card in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(card.title).font(.headline)
                                Spacer()
                                if let at = card.createdAt { Text(at, format: .relative(presentation: .named)).foregroundStyle(.secondary) }
                            }
                            HStack(spacing: 8) {
                                Text("from \(card.producer)").foregroundStyle(.secondary)
                                if card.unverified { Text("unverified source").foregroundStyle(.orange) }
                                if card.isPrivate { Text("private").foregroundStyle(.purple) }
                                if card.corrected { Text("the note was corrected; see the newer card").foregroundStyle(.orange) }
                                if card.retracted { Text("the note was deleted where it was taken").foregroundStyle(.orange) }
                            }
                            .font(.caption)
                            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                                Text("• " + line).textSelection(.enabled)
                            }
                            ForEach(card.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            if !card.notFiled.isEmpty {
                                Text("Not filed yet, in your words:").font(.caption).bold()
                                ForEach(card.notFiled, id: \.self) { Text("\u{201C}\($0)\u{201D}").font(.callout).italic().textSelection(.enabled) }
                            }
                            HStack {
                                Picker("File into", selection: Binding(get: { model.target[card.id] }, set: { model.target[card.id] = $0 })) {
                                    Text("Choose a binder").tag(URL?.none)
                                    ForEach(adopted, id: \.folder) { row in Text(row.name).tag(URL?.some(row.folder)) }
                                }
                                .frame(maxWidth: 320)
                                Button("File") { model.file(card) }.disabled(model.target[card.id] == nil)
                                Spacer()
                                Button("Discard", role: .destructive) { model.discard(card) }
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task { await model.load() }
    }
}
