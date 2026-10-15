import AppKit
import Combine
import Capture
import Services
import Shelf
import SpravaKit
import SwiftUI

/// The capture inbox (mvp.md feature 4): typed notes become capture events in Sprava's own device folder, the
/// runtime turns each into a Tier 0 card within its next sweep, and cards with no binder wait here until the
/// person picks one.
@MainActor
final class InboxModel: ObservableObject {
    struct Card: Identifiable {
        let id: String
        let title: String
        let lines: Shown
        let createdAt: Date?
        let unverified: Bool
        let isPrivate: Bool
        let corrected: Bool
        let retracted: Bool
        let producer: String
        let notes: Shown
        let notFiled: Shown
    }

    /// An intake document the clerk recommends a careful reading of (adaptation-layer §4.4).
    struct Reading: Identifiable {
        let id: String
        let binder: String
        let title: String
        let summary: String?
        let reasons: Shown
    }

    /// What the page draws, bounded as it is read: cards and readings come from untrusted captures and intake
    /// files, so at most `Shown.items` of each are kept, and every line is a preview (`Shown`). The rest stay where
    /// they are and show as the ones drawn are filed, discarded or dismissed.
    @Published var cards: [Card] = []
    @Published var readings: [Reading] = []
    /// How many cards and readings the runtime listed, drawn or not.
    @Published var cardCount = 0
    @Published var readingCount = 0
    @Published var draft = ""
    @Published var draftBinder: URL?
    @Published var target: [String: URL] = [:]
    @Published var message: String?
    @Published var saving = false
    var startedTyping: Date?
    let client: RuntimeClient
    /// Sprava's support folder, where the device id and the typed notes' capture folder live.
    let support: URL

    /// The largest capture event the runtime reads (`SafeFile.read`'s limit, which `CaptureEvent.check` uses).
    static let largestNote = 16 * 1024 * 1024

    init(client: RuntimeClient = RuntimeClient(), support: URL = SpravaPaths.supportDirectory()) {
        self.client = client
        self.support = support
        // The Inbox reads every 30 seconds: a launch before the runtime's must not leave its line up all day.
        client.clearsNotRunning(self, \.message)
    }

    func load() async {
        do {
            let r = try await client.global("unfiled", timeout: 5)
            let listed = r["cards"]?.arrayValue ?? []
            cardCount = listed.count
            cards = listed.prefix(Shown.items).compactMap { c in
                guard let id = c["id"]?.stringValue else { return nil }
                return Card(id: id, title: Shown.preview(c["title"]?.stringValue ?? ""), lines: Shown(strings(c["lines"])),
                            createdAt: ISOTime.date(c["created_at"]?.stringValue), unverified: c["unverified_source"] == .bool(true),
                            isPrivate: c["private"] == .bool(true), corrected: c["source_corrected"] == .bool(true),
                            retracted: c["source_retracted"] == .bool(true), producer: Shown.preview(c["producer"]?.stringValue ?? "?"),
                            notes: Shown(strings(c["notes"])), notFiled: Shown(strings(c["not_filed"])))
            }
            let rs = try await client.global("readings", timeout: 5)
            let found = rs["readings"]?.arrayValue ?? []
            readingCount = found.count
            readings = found.prefix(Shown.items).compactMap { r in
                guard let id = r["id"]?.stringValue else { return nil }
                return Reading(id: id, binder: r["binder"]?.stringValue ?? "", title: Shown.preview(r["title"]?.stringValue ?? ""),
                               summary: r["summary"]?.stringValue.map(Shown.preview), reasons: Shown(strings(r["reasons"])))
            }
        } catch { message = "\(error)" }
    }

    private func strings(_ value: JSONValue?) -> [String] { value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// The note's capture time is when its words were started: a draft emptied and begun again is a new note, so
    /// "tomorrow" in it is read from the new start, not from the abandoned one.
    func draftChanged(_ text: String, now: Date = Date()) {
        // Blank space is no note, as saving reads it.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startedTyping = nil
        } else if startedTyping == nil {
            startedTyping = now
        }
    }

    func dismiss(_ reading: Reading) {
        Task {
            do { _ = try await client.global("dismiss_reading", [("reading", .string(reading.id))]) } catch { message = "\(error)" }
            await load()
        }
    }

    /// Writes the note as a capture event (capture-event-v0 §8.1), then tells the runtime its id and digest, so
    /// the binder the person chose is trusted (architecture 8).
    func save(binderName: String?, explanation: String? = nil) {
        guard !saving, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        Task {
            let saved = await saveDraft(binderName: binderName, explanation: explanation)
            if saved {
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        }
    }

    /// Saves the draft as it is now and returns whether it was saved. The editor is locked while the runtime is
    /// asked (up to five seconds); the draft is cleared only if it is still the text saved, so nothing typed
    /// meanwhile is lost.
    func saveDraft(binderName: String?, explanation: String? = nil) async -> Bool {
        saving = true
        defer { saving = false }
        let submitted = draft
        let text = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        do {
            // The runtime makes this Mac's id at its first start; the app only reads it, never makes one.
            guard let deviceID = try DeviceID.existing(support: support) else {
                message = "The note was not saved: Sprava's background part has not started on this Mac yet. Health, at the top of the sidebar, shows when it runs."
                return false
            }
            let producer = CaptureProducer(root: CaptureInbox.defaultRoot(support: support), deviceID: deviceID, support: support)
            // The notice goes first, so the runtime trusts the binder the person chose (architecture 8).
            let note = try producer.prepareNote(text, binderHint: binderName, startedAt: startedTyping ?? Date())
            // The runtime reads no capture larger than this; one it would set aside must stay in the editor.
            guard note.bytes.count <= Self.largestNote else {
                message = "The note was not saved: it is too long for one note. Split it into smaller notes."
                return false
            }
            var noticed = true
            do {
                _ = try await client.global("capture_notice", [("event", .string(note.id)), ("sha256", .string(note.digest))], timeout: 5)
            } catch {
                noticed = false
            }
            try producer.publish(note)
            if draft == submitted {
                draft = ""
                startedTyping = nil
            }
            message = !noticed ? "Saved, but the runtime did not answer, so the card will ask for a binder."
                : explanation.map { "Saved. " + $0 }
                ?? (binderName == nil ? "Saved. Its card will appear here in a moment." : "Saved. Its card will appear in the binder in a moment.")
            return true
        } catch {
            // Sprava's errors are sentences: an unreadable device id or note clock names its file and says it was
            // left as it is.
            message = "The note was not saved: \(error)"
            return false
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

/// Lines as the page draws them: captures and intake files are untrusted and may hold any number of lines of any
/// length, so the page keeps a bounded number of bounded previews and counts the rest, which stay where they are.
struct Shown {
    static let limit = 20
    /// Cards or readings drawn at once.
    static let items = 50
    /// Characters of one line drawn.
    static let characters = 500
    let lines: [String]
    let more: Int

    init(_ all: [String], limit: Int = Shown.limit) {
        lines = all.prefix(limit).map(Self.preview)
        more = all.count - lines.count
    }

    var isEmpty: Bool { lines.isEmpty }

    /// Cut by Unicode scalars, not characters: one character can carry any number of combining marks.
    static func preview(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let end = scalars.index(scalars.startIndex, offsetBy: characters, limitedBy: scalars.endIndex),
              end != scalars.endIndex else { return text }
        return String(scalars[..<end]) + "\u{2026}"
    }
}

struct InboxView: View {
    @ObservedObject var model: InboxModel
    let rows: [ShelfRow]

    var adopted: [ShelfRow] { rows.filter { $0.teka.isAdopted && !$0.teka.writesBlocked } }

    static func fold(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }

    /// Whether another adopted binder shares this one's name (after NFC and case folding). A note's binder hint is a
    /// name (capture-event-v0), so such a hint could land in the other binder.
    func sharesName(_ row: ShelfRow) -> Bool {
        rows.filter { $0.teka.isAdopted && Self.fold($0.name) == Self.fold(row.name) }.count > 1
    }

    /// A binder's name in a picker, with its whole folder path when another binder has the same name: two such
    /// binders can sit in folders whose own names match too, and the person must see which one a card goes to.
    func label(_ row: ShelfRow) -> String { Self.label(name: row.name, folder: row.folder, sharesName: sharesName(row)) }

    static func label(name: String, folder: URL, sharesName: Bool) -> String {
        sharesName ? "\(name) (\((folder.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath))" : name
    }

    /// Saves the note with the chosen binder's name as its hint. A name two binders share is not sent: the card
    /// waits in the Inbox, where filing names the folder itself.
    func saveNote() {
        guard let row = adopted.first(where: { $0.folder == model.draftBinder }) else { model.save(binderName: nil); return }
        if sharesName(row) {
            model.save(binderName: nil, explanation: "Another binder has the same name, so the card waits below; file it into \(label(row)) there.")
        } else {
            model.save(binderName: row.name)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Inbox").font(.largeTitle).bold()
                GroupBox("New note") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.draft)
                            .font(.body)
                            .frame(minHeight: 80)
                            // Locked while the note is saved: the draft is cleared once it is in.
                            .disabled(model.saving)
                            .onChange(of: model.draft) { _, new in model.draftChanged(new) }
                        Text("One line per thing to do. Sprava files it without a model; you approve every card.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Picker("Binder", selection: $model.draftBinder) {
                                Text("Not sure").tag(URL?.none)
                                ForEach(adopted, id: \.folder) { row in Text(label(row)).tag(URL?.some(row.folder)) }
                            }
                            .frame(maxWidth: 320)
                            Spacer()
                            Button("Save Note") { saveNote() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.saving || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(4)
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Text("Waiting for a binder (\(model.cardCount))").font(.headline)
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
                            ForEach(DisplayLine.rows(card.lines.lines)) { line in
                                Text("• " + line.text).textSelection(.enabled)
                            }
                            let notes = card.notes
                            ForEach(DisplayLine.rows(notes.lines)) { Text($0.text).font(.caption).foregroundStyle(.orange) }
                            if notes.more > 0 { Text("and \(notes.more) more note(s)").font(.caption).foregroundStyle(.secondary) }
                            if !card.notFiled.isEmpty {
                                let notFiled = card.notFiled
                                Text("Not filed yet, in your words:").font(.caption).bold()
                                ForEach(DisplayLine.rows(notFiled.lines)) { Text("\u{201C}\($0.text)\u{201D}").font(.callout).italic().textSelection(.enabled) }
                                if notFiled.more > 0 {
                                    Text("and \(notFiled.more) more line(s), kept in the capture").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Picker("File into", selection: Binding(get: { model.target[card.id] }, set: { model.target[card.id] = $0 })) {
                                    Text("Choose a binder").tag(URL?.none)
                                    ForEach(adopted, id: \.folder) { row in Text(label(row)).tag(URL?.some(row.folder)) }
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
                if model.cardCount > model.cards.count {
                    Text("and \(model.cardCount - model.cards.count) more card(s); they show as these are filed or discarded")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.readings.isEmpty {
                    Text("Worth a careful reading (\(model.readingCount))").font(.headline)
                    Text("Documents from intake that the on-device clerk could not read well enough alone. Connected brains do not see intake documents yet: these stay with you until a document can be marked as not private.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.readings) { r in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(r.title).font(.headline)
                                    Spacer()
                                    Text(rows.first { $0.folder.standardizedFileURL.path == r.binder }?.name ?? "").foregroundStyle(.secondary)
                                }
                                if let s = r.summary { Text(s).font(.callout) }
                                Text((r.reasons.lines + (r.reasons.more > 0 ? ["and \(r.reasons.more) more"] : [])).joined(separator: "; "))
                                    .font(.caption).foregroundStyle(.orange)
                                HStack {
                                    Spacer()
                                    Button("Not Needed") { model.dismiss(r) }
                                }
                            }
                            .padding(4)
                        }
                    }
                    if model.readingCount > model.readings.count {
                        Text("and \(model.readingCount - model.readings.count) more; they show as these are dismissed or answered")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task { await model.load() }
    }
}
