import SwiftUI

/// Why a binder is not connected to Claude and what can be done about it, always in sight above its saved conversation.
enum ConnectionState: Equatable {
    case noAnswer, setupUnknown, setUp, unavailable, moved, disconnected, new

    init(runtimeAnswered: Bool, accountReady: Bool?, reason: String?) {
        guard runtimeAnswered else { self = .noAnswer; return }
        switch (accountReady, reason) {
        case (false?, _): self = .setUp
        case (nil, _): self = .setupUnknown
        case (true?, "unavailable"): self = .unavailable
        case (true?, "moved"): self = .moved
        case (true?, "disconnected"): self = .disconnected
        case (true?, _): self = .new
        }
    }

    var explanation: String {
        switch self {
        case .noAnswer: "Sprava could not check this binder's Claude connection: its background part did not answer. Try again, or open Health."
        case .setupUnknown: "Sprava could not check whether Claude is set up. Try again, or open Health."
        case .setUp: "Claude is not set up in Sprava, so this binder cannot talk to it. Set it up once to continue."
        case .unavailable: "Claude cannot use this binder now: it is being offloaded, or it is no longer on the shelf."
        case .moved: "This binder's folder moved since it was connected to Claude. Connect it again to continue."
        case .disconnected: "This binder is not connected to Claude. Connect it again to continue."
        case .new: "Connect this binder to Claude, then ask about priorities, find a source, draft an email, or add and close its To-dos."
        }
    }

    var offersConnect: Bool { self == .moved || self == .disconnected || self == .new }
}

/// Not behind a disclosure: the page has no other way forward while the binder is not connected.
struct ConnectionPanel: View {
    @ObservedObject var model: ClaudeBinderConversation
    let adopted: Bool
    let folder: URL
    var openBrains: () -> Void

    var body: some View {
        let state = model.connectionState
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: state.explanation).font(.callout.weight(.medium))
            if state.offersConnect {
                Toggle("Share filed documents, including private ones", isOn: $model.documents)
                Toggle("Share intake mail and attachments", isOn: $model.intake)
                Toggle("Let Claude change and delete files in this binder; you can undo each turn",
                       isOn: Binding(get: { model.allowsFiles }, set: { model.files = $0 }))
                    .disabled(!model.documents || !model.intake)
                Text("Claude always sees this binder's task titles and details and the saved conversation, plus what you tick above. It goes to Anthropic; a copied binder has its own conversation. Claude can add, change and close this binder's to-dos when you ask, and you can undo each turn. It cannot send mail. With intake shared, Claude also reads each new intake document as it arrives, up to 100 a day on your Claude plan, and proposes its to-dos for you to approve. With file changes allowed, it can read the whole folder and run tools inside it, and nothing else on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if state.offersConnect {
                    Button("Connect to Claude") { Task { await model.connect() } }
                        .buttonStyle(.borderedProminent).disabled(model.busy || !adopted)
                    if !adopted { Text("Adopt this binder first.").font(.caption).foregroundStyle(.secondary) }
                } else if state == .setUp {
                    Button("Set Up Assistant") { openBrains() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Try Again") { Task { await model.show(folder) } }
                        .buttonStyle(.borderedProminent).disabled(model.checking)
                }
                if model.checking { ProgressView().controlSize(.small) }
                Spacer()
                if model.hasSavedScope {
                    Button("Clear saved conversation…", role: .destructive) { model.askToClear = true }.disabled(model.busy)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
