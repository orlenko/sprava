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
                ForEach(actions.cards) { card in
                    // Locked while its approval or rejection is on its way: the request already holds its edits.
                    let locked = !actions.isChangeable(card.id)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(card.title).font(.body.bold())
                            Spacer()
                            Text("from \(card.actor)").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(DisplayLine.rows(card.lines)) { Text("• \($0.text)").font(.callout) }
                        ForEach(DisplayLine.rows(card.notes)) { Text($0.text).font(.caption).foregroundStyle(.orange) }
                        if let intake = card.intake {
                            Text(intake).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let suggested = card.folder {
                            HStack {
                                Text("Folder").font(.caption)
                                TextField(suggested, text: Binding(get: { actions.folders[card.id] ?? suggested },
                                                                   set: { actions.setFolder(card.id, $0) }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 280)
                                    .disabled(locked)
                            }
                        }
                        if card.asksChannel {
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
                            .disabled(locked)
                        }
                        if !card.verified {
                            Text("Not written by Sprava; it cannot be approved. Reject it to clear it away.").font(.caption).foregroundStyle(.orange)
                        }
                        if let edits = actions.editing[card.id] {
                            ForEach(edits) { e in
                                HStack {
                                    Toggle("", isOn: binding(card.id, e, \.include)).labelsHidden()
                                    TextField("Title", text: binding(card.id, e, \.title)).textFieldStyle(.roundedBorder)
                                    TextField("YYYY-MM-DD or empty", text: binding(card.id, e, \.due)).textFieldStyle(.roundedBorder).frame(width: 130)
                                    Picker("", selection: binding(card.id, e, \.priority)) {
                                        Text("high").tag("high"); Text("normal").tag("normal"); Text("low").tag("low")
                                    }
                                    .labelsHidden().frame(width: 90)
                                    if e.waitingOn != nil {
                                        TextField("Waiting on", text: partyBinding(card.id, e)).textFieldStyle(.roundedBorder).frame(width: 160)
                                    }
                                }
                                .disabled(locked)
                            }
                        }
                        HStack {
                            Button("Approve") { actions.approve(card, folder, reload: reload) }
                                .disabled(!card.verified || actions.busy || locked)
                            if !card.editable.isEmpty, actions.editing[card.id] == nil {
                                Button("Edit") { actions.startEditing(card) }.disabled(!card.verified || locked)
                            }
                            Button("Reject") { actions.reject(card, folder, reload: reload) }
                                .disabled(actions.busy || locked)
                        }
                    }
                    .padding(.vertical, 4)
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

/// The binder's description for the clerk and its place on the filing list.
struct FilingSection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL

    var body: some View {
        Section(header: Text("For the clerk").font(.headline)) {
            TextField("One line: what this binder is about", text: $actions.description)
                .textFieldStyle(.roundedBorder)
                .onSubmit { actions.saveSettings(folder) }
                .disabled(!actions.settingsLoaded)
            Toggle("On the clerk's filing list", isOn: Binding(get: { actions.filing }, set: {
                actions.filing = $0
                actions.saveSettings(folder)
            }))
            .disabled(!actions.settingsLoaded || actions.description.trimmingCharacters(in: .whitespaces).isEmpty)
            if !actions.settingsLoaded {
                Text("This binder's settings are being read; they can be changed once read.").font(.caption).foregroundStyle(.orange)
            }
            Text("The clerk files a note here only when it is on the list. The line stays in Sprava, never in the binder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// DASHBOARD.md and the manual addendum (binder-v0 §7.1, §9.8).
struct KeepingSection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let today: CalendarDate
    let reload: () -> Void

    var body: some View {
        // Read by `BinderActions` off the main actor; rendering reads no file.
        let keeping = actions.keeping
        Section(header: Text("Dashboard and manual").font(.headline)) {
            if let note = actions.keepingNote { Text(note).foregroundStyle(.orange) }
            HStack {
                switch keeping?.switched {
                case true?: Text("Sprava keeps DASHBOARD.md. Edit only below \u{201C}## Notes\u{201D}.")
                case false?: Text("DASHBOARD.md is kept by hand. Sprava can keep it for you; your text moves into its Notes section.")
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
                case _ where keeping == nil: Text("Reading the manual\u{2026}").foregroundStyle(.secondary)
                case true?: Text("The manual carries Sprava's addendum.").foregroundStyle(.secondary)
                case false?: Text("Paste Sprava's addendum into CLAUDE.md or AGENTS.md, so agents propose instead of editing.").foregroundStyle(.orange)
                case nil: Text("No CLAUDE.md or AGENTS.md here. Paste the addendum into one if an agent works in this binder.").foregroundStyle(.secondary)
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
