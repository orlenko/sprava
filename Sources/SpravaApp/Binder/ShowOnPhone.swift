import SpravaKit
import SwiftUI

/// "Show on my phone" (companion.md §2, principle 6): one switch per binder, off by default. It reads and changes the
/// runtime's record only; the runtime's companion job does the publishing.
@MainActor
final class ShowOnPhoneModel: ObservableObject {
    @Published private(set) var shown = false
    @Published private(set) var available = false
    @Published private(set) var working = false
    @Published private(set) var message: String?
    private let client: RuntimeClient
    private var folder: URL?

    init(client: RuntimeClient = RuntimeClient()) { self.client = client }

    func show(_ folder: URL) async {
        if self.folder != folder { self.folder = folder; shown = false; available = false; message = nil }
        do {
            let reply = try await client.command("companion_binder_status", binder: folder)
            guard self.folder == folder else { return }
            shown = reply["shown"] == .bool(true)
            available = reply["available"] == .bool(true)
        } catch {
            if self.folder == folder { message = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not check this switch." }
        }
    }

    func set(_ on: Bool) async {
        guard let folder, !working else { return }
        working = true; message = nil
        defer { working = false }
        do {
            let reply = try await client.command(on ? "companion_binder_show" : "companion_binder_hide", binder: folder, timeout: 30)
            if self.folder == folder { shown = reply["shown"] == .bool(true) }
        } catch {
            if self.folder == folder { message = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not change this switch." }
        }
    }
}

struct ShowOnPhoneSection: View {
    let folder: URL
    @StateObject private var model = ShowOnPhoneModel()

    var body: some View {
        Section("Phone") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show on my phone", isOn: Binding(get: { model.shown }, set: { on in Task { await model.set(on) } }))
                    .disabled(model.working || (!model.available && !model.shown))
                Text(Self.help(available: model.available))
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            .padding(.vertical, 4)
        }
        .task(id: folder) { await model.show(folder) }
    }

    /// What the switch does today, and nothing it does not (decisions recorded in the PR).
    static func help(available: Bool) -> String {
        let what = "Off by default. On sends this binder's to-dos, encrypted, to the phones paired with this Mac. "
            + "Off takes it off those phones at their next update, then deletes its encrypted copies from the relay and "
            + "forgets its key. Turned on again, it gets a new key."
        return available ? what : "Connect this Mac to a relay in Settings › Phone to use this. " + what
    }
}
