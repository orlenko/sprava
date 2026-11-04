import AppKit
import BinderFormat
import BinderStore
import SpravaKit
import SwiftUI

struct ReviewSection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let reload: () -> Void

    var body: some View {
        if !actions.cards.isEmpty {
            Section(header: Text("Waiting for your OK (\(actions.cards.count))").font(.headline)) {
                Text("Nothing is filed or changed until you press a button on a card.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(actions.cards) { ReviewCard(section: self, card: $0) }
            }
        }
    }
}

/// One card: the document, what its button will do, and only what could change the decision. The card's full record
/// stays under Details.
struct ReviewCard: View {
    let section: ReviewSection
    let card: BinderActions.Card
    private var actions: BinderActions { section.actions }

    var body: some View {
        // Locked while its approval or rejection is on its way: the request already holds its edits.
        let locked = !actions.isChangeable(card.id)
        let edits = actions.editing[card.id]
        let review = card.shown
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.heading).font(.body.bold())
                if let byline = card.byline { Text(verbatim: byline).font(.caption).foregroundStyle(.secondary) }
            }
            if !card.verified {
                ReviewNote(text: "Not written by Sprava, so it cannot be carried out. You can clear it away.")
            }
            if let summary = review.summary {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The clerk\u{2019}s summary").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: summary).textSelection(.enabled)
                }
            } else if let begins = review.begins {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The document begins").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "\u{201C}\(begins)\u{201D}").textSelection(.enabled)
                }
            }
            if !review.files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(review.files) { file in
                        Button(file.label) { Task { await actions.showInFinder(file, section.folder) } }
                            .buttonStyle(.link)
                    }
                }
            }
            ForEach(DisplayLine.rows(review.warnings)) { ReviewNote(text: $0.text) }
            // Only on a card that can be carried out: neither answer means anything on one that cannot.
            let actionable = card.action(editing: edits) != nil
            if actionable, let suggested = card.folder {
                HStack {
                    Text("File in folder").font(.caption)
                    TextField(suggested, text: Binding(get: { actions.folders[card.id] ?? suggested },
                                                       set: { actions.setFolder(card.id, $0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .disabled(locked)
                }
            }
            if actionable, card.asksChannel { channelRow.disabled(locked) }
            if let edits {
                ForEach(edits) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        editRow(e).disabled(locked)
                        // What the clerk was unsure of is what the person came here to correct.
                        ForEach(DisplayLine.rows(review.todos.first { $0.index == e.index }?.notes ?? [])) {
                            Text(verbatim: $0.text).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !review.todos.isEmpty {
                ReviewList(title: review.kind == .manual ? "To repair by hand"
                               : review.todos.count == 1 ? "To-do it would add" : "To-dos it would add",
                           rows: review.todos.map { todo in
                               let due = todo.due.isEmpty ? "" : ", due \(todo.due)"
                               let high = todo.priority == "high" ? ", high priority" : ""
                               return (todo.id, todo.title + due + high, todo.notes)
                           })
            }
            // Never folded, and kept while editing: an op can write more than its edit row offers, such as a repair
            // card's derived follow-up, and a change to what the hub may receive is what the person decides on.
            if !review.changes.isEmpty {
                ReviewList(title: review.kind == .manual ? "To repair by hand"
                               : review.changes.count == 1 ? "Change it would make" : "Changes it would make",
                           rows: review.changes.map { ($0.id, $0.line, $0.notes) })
            }
            // A card Sprava did not write, or one the runtime has no facts for: its own lines.
            if review.kind == .plain, !card.lines.isEmpty {
                ReviewList(title: nil, rows: card.lines.enumerated().map { ($0.offset, $0.element, []) })
            }
            HStack {
                if let action = card.action(editing: edits) {
                    Button(action.title) { actions.approve(card, section.folder, reload: section.reload) }
                        .disabled(!action.enabled || actions.busy || locked)
                }
                if let edit = card.editTitle, edits == nil {
                    Button(edit) { actions.startEditing(card) }.disabled(locked)
                }
                Button(card.declineTitle) { actions.reject(card, section.folder, reload: section.reload) }
                    .help(card.declineHelp)
                    .disabled(actions.busy || locked)
            }
            ClaudeExpandingRow(title: "Details", open: Binding(get: { actions.openDetails.contains(card.id) },
                                                               set: { actions.setDetails(card.id, open: $0) }))
                .font(.caption).foregroundStyle(.secondary)
            if actions.openDetails.contains(card.id) { details }
        }
        .padding(.vertical, 6)
    }

    /// Everything the card holds, for whoever wants to check it: its raw lines and every note, once.
    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "Suggested by \(card.actor)")
            ForEach(DisplayLine.rows(card.lines)) { Text(verbatim: "\u{2022} \($0.text)") }
            ForEach(DisplayLine.rows(card.notes)) { Text(verbatim: $0.text) }
            if let intake = card.intake { Text(verbatim: intake) }
        }
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private var channelRow: some View {
        HStack {
            Picker("How did it reach you?", selection: Binding(get: { actions.channels[card.id] ?? "other" },
                                                              set: { actions.setChannel(card.id, $0) })) {
                Text("not saying").tag("other")
                Text("by email").tag("email")
                Text("on paper, scanned").tag("paper")
                Text("downloaded").tag("download")
                Text("in a message").tag("message")
                Text("I wrote it").tag("note")
            }
            .frame(maxWidth: 320)
            TextField("in your words (optional)", text: Binding(get: { actions.said[card.id] ?? "" },
                                                                set: { actions.setSaid(card.id, $0) }))
                .textFieldStyle(.roundedBorder)
        }
        .font(.caption)
    }

    private func editRow(_ e: BinderActions.Editable) -> some View {
        HStack {
            Toggle("", isOn: section.binding(card.id, e, \.include)).labelsHidden()
            TextField("Title", text: section.binding(card.id, e, \.title)).textFieldStyle(.roundedBorder)
            TextField("YYYY-MM-DD or empty", text: section.binding(card.id, e, \.due)).textFieldStyle(.roundedBorder).frame(width: 130)
            Picker("", selection: section.binding(card.id, e, \.priority)) {
                Text("high").tag("high"); Text("normal").tag("normal"); Text("low").tag("low")
            }
            .labelsHidden().frame(width: 90)
            if e.waitingOn != nil {
                TextField("Waiting on", text: section.partyBinding(card.id, e)).textFieldStyle(.roundedBorder).frame(width: 160)
            }
        }
    }
}

/// One thing the person should know before deciding: said once, in ordinary text, with a quiet mark.
private struct ReviewNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// A short list of what a card's button would do, each row with its own notes beneath it.
private struct ReviewList: View {
    let title: String?
    let rows: [(id: Int, line: String, notes: [String])]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title { Text(verbatim: title).font(.caption).foregroundStyle(.secondary) }
            ForEach(rows, id: \.id) { row in
                Text(verbatim: "\u{2022} \(row.line)").fixedSize(horizontal: false, vertical: true)
                ForEach(DisplayLine.rows(row.notes)) {
                    Text(verbatim: $0.text).font(.caption).foregroundStyle(.secondary).padding(.leading, 10)
                }
            }
        }
    }
}

extension ReviewSection {
    /// A binding into one editable item of one card. An approval or a change of binder can drop the card's
    /// edits while its controls still hold this binding; reading it then gives the item as it was drawn, and a
    /// change through it, like one while the card is locked, is refused by the model.
    func binding<T>(_ card: String, _ item: BinderActions.Editable, _ path: WritableKeyPath<BinderActions.Editable, T>) -> Binding<T> {
        Binding(get: { actions.editing[card]?.first { $0.index == item.index }?[keyPath: path] ?? item[keyPath: path] },
                set: { actions.setItem(card, item.index, path, $0) })
    }

    /// A binding into the party of one editable item, shown only when the card offers one.
    func partyBinding(_ card: String, _ item: BinderActions.Editable) -> Binding<String> {
        Binding(get: { actions.editing[card]?.first { $0.index == item.index }?.waitingOn ?? item.waitingOn ?? "" },
                set: { actions.setItem(card, item.index, \.waitingOn, $0) })
    }
}

struct HistorySection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let reload: () -> Void

    var body: some View {
        if !actions.history.isEmpty {
            Section(header: Text("Recent changes").font(.headline)) {
                ForEach(actions.history.prefix(10)) { change in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.line).strikethrough(change.undone)
                            Text([change.who, change.at.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if change.undone {
                            Text("undone").font(.caption).foregroundStyle(.secondary)
                        } else if change.undoable, let at = change.at, Date().timeIntervalSince(at) < 7 * 86_400 {
                            Button("Undo") { actions.undo(change, folder, reload: reload) }.disabled(actions.busy)
                        }
                    }
                }
            }
        }
    }
}

/// The bottom of the page, closed until opened: what the binder is about, which helps Sprava route notes from
/// the Inbox and the phone (the filing list, mvp.md feature 1), and the files Sprava keeps in its folder.
/// The binder's line and whether notes from elsewhere may be filed here; both stay in Sprava's own settings.
struct RoutingRows: View {
    @ObservedObject var actions: BinderActions
    let folder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this binder is about").font(.subheadline.bold())
            TextField("One line, such as: rental unit, tenants, repairs, rent", text: $actions.description)
                .textFieldStyle(.roundedBorder)
                .onSubmit { actions.saveSettings(folder) }
                .disabled(!actions.settingsLoaded)
            Toggle("Suggest this binder for notes from the Inbox and the phone", isOn: Binding(get: { actions.filing }, set: {
                actions.filing = $0
                actions.saveSettings(folder)
            }))
            .disabled(!actions.settingsLoaded)
            if !actions.settingsLoaded {
                Text("This binder's settings are being read; they can be changed once read.").font(.caption).foregroundStyle(.orange)
            }
            Text("This line only helps Sprava pick the right binder for a note written in the Inbox or on the phone. Notes typed at the top of this page always come here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// DASHBOARD.md and the manual addendum (binder-v0 §7.1, §9.8).
struct KeepingRows: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let today: CalendarDate
    let reload: () -> Void

    var body: some View {
        // Read by `BinderActions` off the main actor; rendering reads no file.
        let keeping = actions.keeping
        VStack(alignment: .leading, spacing: 8) {
            Text("Files Sprava keeps in this folder").font(.subheadline.bold())
            if let note = actions.keepingNote { Text(note).foregroundStyle(.orange) }
            HStack {
                switch keeping?.switched {
                case true?: Text("DASHBOARD.md is a summary of this binder for reading outside Sprava, rewritten as things change. Your own text belongs below its \u{201C}## Notes\u{201D} line, which Sprava never changes.")
                case false?: Text("DASHBOARD.md here is written by hand. Sprava can keep it up to date for you; your text moves below its \u{201C}## Notes\u{201D} line.")
                case nil: Text("Reading DASHBOARD.md\u{2026}").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Preview") { Task { await actions.showDashboardPreview(folder, today: today) } }
                if keeping?.switched == false {
                    Button("Let Sprava Keep It") {
                        let alert = NSAlert()
                        alert.messageText = "Let Sprava keep DASHBOARD.md?"
                        alert.informativeText = "Sprava rewrites the file from the catalog every day and after each change. The current text moves below \u{201C}## Notes\u{201D}, which Sprava never changes, and a copy is kept in the binder's .sprava folder."
                        alert.addButton(withTitle: "Switch")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { actions.run("switch_dashboard", folder, [], then: reload) }
                    }
                    .disabled(actions.busy)
                }
            }
            HStack {
                switch keeping?.addendum {
                case _ where keeping == nil: Text("Reading the folder\u{2026}").foregroundStyle(.secondary)
                case true?: Text("The instructions for coding agents in this folder include Sprava's addendum, so an agent asks for your OK before it changes the binder.").foregroundStyle(.secondary)
                case false?: Text("This folder has instructions for coding agents without Sprava's addendum. If you run Claude Code or Codex here, paste the addendum into its CLAUDE.md or AGENTS.md, so the agent asks for your OK instead of changing the binder itself.")
                case nil: Text("Only if you run Claude Code or Codex yourself in this binder's folder: paste the addendum into a CLAUDE.md or AGENTS.md there, so the agent asks for your OK instead of changing the binder itself.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(actions.copied ? "Copied" : "Copy Addendum") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ManualAddendum.text, forType: .string)
                    actions.copied = true
                }
            }
        }
        .sheet(isPresented: $actions.showPreview) {
            VStack(alignment: .leading) {
                ScrollView { Text(actions.preview ?? "Rendering\u{2026}").font(.body.monospaced()).textSelection(.enabled).padding() }
                HStack { Spacer(); Button("Close") { actions.showPreview = false }.keyboardShortcut(.defaultAction) }.padding()
            }
            .frame(width: 720, height: 560)
        }
    }
}
