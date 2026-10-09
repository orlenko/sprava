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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(card.title).font(.body.bold())
                            Spacer()
                            Text("from \(card.actor)").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(card.lines, id: \.self) { Text("• \($0)").font(.callout) }
                        ForEach(card.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        if let intake = card.intake {
                            Text(intake).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let suggested = card.folder {
                            HStack {
                                Text("Folder").font(.caption)
                                TextField(suggested, text: Binding(get: { actions.folders[card.id] ?? suggested },
                                                                   set: { actions.folders[card.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 280)
                            }
                        }
                        if card.asksChannel {
                            HStack {
                                Picker("How did it reach you?", selection: Binding(get: { actions.channels[card.id] ?? "other" },
                                                                                  set: { actions.channels[card.id] = $0 })) {
                                    Text("not saying").tag("other")
                                    Text("by email").tag("email")
                                    Text("on paper, scanned").tag("paper")
                                    Text("downloaded").tag("download")
                                    Text("in a message").tag("message")
                                    Text("I wrote it").tag("note")
                                }
                                .frame(maxWidth: 320)
                                TextField("in your words (optional)", text: Binding(get: { actions.said[card.id] ?? "" },
                                                                                    set: { actions.said[card.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                            }
                            .font(.caption)
                        }
                        if !card.verified {
                            Text("Not written by Sprava; it cannot be approved. Reject it to clear it away.").font(.caption).foregroundStyle(.orange)
                        }
                        if let edits = actions.editing[card.id] {
                            ForEach(edits) { e in
                                HStack {
                                    Toggle("", isOn: binding(card.id, e.index, \.include)).labelsHidden()
                                    TextField("Title", text: binding(card.id, e.index, \.title)).textFieldStyle(.roundedBorder)
                                    TextField("YYYY-MM-DD or empty", text: binding(card.id, e.index, \.due)).textFieldStyle(.roundedBorder).frame(width: 130)
                                    Picker("", selection: binding(card.id, e.index, \.priority)) {
                                        Text("high").tag("high"); Text("normal").tag("normal"); Text("low").tag("low")
                                    }
                                    .labelsHidden().frame(width: 90)
                                    if e.waitingOn != nil {
                                        TextField("Waiting on", text: partyBinding(card.id, e.index)).textFieldStyle(.roundedBorder).frame(width: 160)
                                    }
                                }
                            }
                        }
                        HStack {
                            Button("Approve") { actions.approve(card, folder, reload: reload) }
                                .disabled(!card.verified || actions.busy)
                            if !card.editable.isEmpty, actions.editing[card.id] == nil {
                                Button("Edit") { actions.editing[card.id] = card.editable }.disabled(!card.verified)
                            }
                            Button("Reject") { actions.reject(card, folder, reload: reload) }
                                .disabled(actions.busy)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

extension ReviewSection {
    /// A binding into one editable item of one card.
    func binding<T>(_ card: String, _ index: Int, _ path: WritableKeyPath<BinderActions.Editable, T>) -> Binding<T> {
        Binding(get: { actions.editing[card]!.first { $0.index == index }![keyPath: path] },
                set: { value in
                    guard let i = actions.editing[card]?.firstIndex(where: { $0.index == index }) else { return }
                    actions.editing[card]![i][keyPath: path] = value
                })
    }

    /// A binding into the party of one editable item, shown only when the card offers one.
    func partyBinding(_ card: String, _ index: Int) -> Binding<String> {
        Binding(get: { actions.editing[card]?.first { $0.index == index }?.waitingOn ?? "" },
                set: { value in
                    guard let i = actions.editing[card]?.firstIndex(where: { $0.index == index }) else { return }
                    actions.editing[card]![i].waitingOn = value
                })
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
        let keeper = DashboardKeeper(folder: folder)
        let addendum = ManualAddendum.isPresent(in: folder)
        Section(header: Text("Dashboard and manual").font(.headline)) {
            HStack {
                Text(keeper.isSwitched ? "Sprava keeps DASHBOARD.md. Edit only below \u{201C}## Notes\u{201D}."
                                       : "DASHBOARD.md is kept by hand. Sprava can keep it for you; your text moves into its Notes section.")
                Spacer()
                Button("Preview") { actions.showPreview = true }
                if !keeper.isSwitched {
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
                switch addendum {
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
                ScrollView { Text(keeper.preview(today: today) ?? "unreadable").font(.body.monospaced()).textSelection(.enabled).padding() }
                HStack { Spacer(); Button("Close") { actions.showPreview = false }.keyboardShortcut(.defaultAction) }.padding()
            }
            .frame(width: 720, height: 560)
        }
    }
}
