import BinderFormat
import Combine
import Foundation
import SpravaKit
import SwiftUI

/// The Instructions tab's state for one binder (decisions.md D43; docs/binder-instructions.md §3): the person's part of
/// `AGENTS.md` as read, the text being edited, and the saves, which go through the runtime. Kept by the window, one per
/// binder, so a draft outlives a visit to another tab or binder.
@MainActor
final class InstructionsModel: ObservableObject, DraftOwner {
    struct OldManual: Equatable, Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }

    /// What the page read: the instructions, or why they are shown but not saved over.
    @Published private(set) var read: Result<BinderInstructions, BinderInstructions.Problem>?
    @Published var text = ""
    @Published private(set) var oldManuals: [OldManual] = []
    @Published var message: String?
    @Published private(set) var busy = false
    let client: RuntimeClient
    /// Reads the binder off the main actor; a test hands in its own.
    let reader: @Sendable (URL) async -> (Result<BinderInstructions, BinderInstructions.Problem>, [OldManual])

    init(client: RuntimeClient = RuntimeClient(),
         reader: @escaping @Sendable (URL) async -> (Result<BinderInstructions, BinderInstructions.Problem>, [OldManual]) = InstructionsModel.readBinder) {
        self.client = client
        self.reader = reader
    }

    nonisolated static func readBinder(_ folder: URL) async -> (Result<BinderInstructions, BinderInstructions.Problem>, [OldManual]) {
        await Task.detached(priority: .userInitiated) {
            (BinderInstructions.read(folder), BinderInstructions.oldManuals(folder).map { OldManual(name: $0.name, text: $0.text) })
        }.value
    }

    var found: BinderInstructions? { if case .success(let found)? = read { found } else { nil } }
    var edited: Bool { found.map { text != $0.text } ?? false }
    var draftState: DraftState { DraftState(hasChanges: edited, saving: busy) }
    var fits: Bool { BinderInstructions.fits(text) }
    /// The text tells agents to run lifeproj, which turns repeats off in the binder (`Adoption.lifeprojCanReach`).
    var namesLifeproj: Bool { text.range(of: #"lifeproj\s+(publish|drain)"#, options: .regularExpression) != nil }

    /// Reads the binder again. The text being edited is replaced only when it has no change, so a reload never loses a draft.
    func load(_ folder: URL, replacing: Bool = false) async {
        let (read, manuals) = await reader(folder)
        let keep = edited && !replacing
        self.read = read
        oldManuals = manuals
        if !keep, case .success(let found) = read { text = found.text }
    }

    func revert() { if let found { text = found.text } }

    /// Appends an old manual's text for the person to read and trim; nothing is saved until they save.
    func copyIn(_ manual: OldManual) {
        text += (text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n") + manual.text
    }

    /// Saves the text, or confirms the text on disk as it is (`useThisText`), then reads the binder again.
    func save(_ folder: URL, useThisText: Bool = false) async {
        guard let found, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.command("save_instructions", binder: folder,
                                         [("text", .string(useThisText ? found.text : text)), ("expected", .string(found.digest))])
            message = nil
        } catch {
            message = "\(error)"
            return
        }
        await load(folder, replacing: true)
    }

    func undo(_ folder: URL) async {
        guard !busy, !edited else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.command("undo_instructions", binder: folder)
            message = nil
        } catch {
            message = "\(error)"
            return
        }
        await load(folder)
    }
}

@MainActor
final class BinderInstructionsModels: ObservableObject, DraftOwner {
    private var models: [URL: InstructionsModel] = [:]
    func model(for folder: URL) -> InstructionsModel {
        let folder = folder.standardizedFileURL
        if let model = models[folder] { return model }
        let model = InstructionsModel()
        models[folder] = model
        return model
    }
    var draftState: DraftState { models.values.reduce(DraftState()) { $0.merging($1.draftState) } }
}

/// The Instructions tab: the person's part of `AGENTS.md`, editable where this Mac writes the binder.
struct InstructionsSection: View {
    @ObservedObject var model: InstructionsModel
    let folder: URL
    let writable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this binder works: what it is for, where things go, what belongs on your to-do list. Sprava's reader of new documents and this binder's conversation follow it.")
                .foregroundStyle(.secondary)
            Text("When this binder is connected to Claude with file changes allowed, these instructions go to Claude with each new document from intake.")
                .font(.caption).foregroundStyle(.secondary)
            switch model.read {
            case nil: ProgressView().frame(maxWidth: .infinity)
            case .failure(let problem)?:
                Text(problem.description).foregroundStyle(.orange)
            case .success(let found)?:
                editor(found)
            }
            if let message = model.message { Text(message).foregroundStyle(.orange) }
        }
        .padding(16)
        .task(id: folder) { await model.load(folder) }
    }

    @ViewBuilder private func editor(_ found: BinderInstructions) -> some View {
        TextEditor(text: $model.text)
            .font(.body.monospaced())
            .frame(minHeight: 220, maxHeight: .infinity)
            .disabled(!writable)
            .accessibilityLabel("Instructions")
        if !model.fits {
            Text("Instructions are at most \(BinderInstructions.maxCharacters) characters. Shorten them to save.").foregroundStyle(.orange)
        }
        if model.namesLifeproj {
            Text("This text tells agents to run lifeproj publish or drain, so repeating to-dos stay off in this binder.").foregroundStyle(.orange)
        }
        if !found.isAccepted, !model.edited, !found.text.isEmpty {
            Text("Not used for filing until you save it here: this text changed outside Sprava, or was here before.").foregroundStyle(.orange)
        }
        if writable {
            HStack {
                Button("Save") { Task { await model.save(folder) } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.edited || !model.fits || model.busy)
                Button("Revert") { model.revert() }.disabled(!model.edited || model.busy)
                if !found.isAccepted, !model.edited, !found.text.isEmpty {
                    Button("Use this text") { Task { await model.save(folder, useThisText: true) } }.disabled(model.busy)
                }
                if found.canUndo, !model.edited {
                    Button("Undo last save") { Task { await model.undo(folder) } }.disabled(model.busy)
                }
                Spacer()
                Button("Reload") { Task { await model.load(folder) } }.disabled(model.busy)
            }
            ForEach(model.oldManuals) { manual in
                Button("Copy in the old \(manual.name)") { model.copyIn(manual) }
                    .help("Adds the instructions this binder had before it was imported, for you to read, trim and save.")
            }
        } else {
            Text("Read-only here: this binder is not one this Mac writes now.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
