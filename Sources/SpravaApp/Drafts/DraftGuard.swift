import AppKit
import Combine

struct DraftState: Equatable {
    var hasChanges = false
    var saving = false
    func merging(_ other: Self) -> Self {
        Self(hasChanges: hasChanges || other.hasChanges, saving: saving || other.saving)
    }
}

@MainActor protocol DraftOwner: AnyObject {
    var draftState: DraftState { get }
}

/// Windows own their models; this registry observes them without keeping a closed window alive.
@MainActor final class DraftRegistry: ObservableObject, DraftOwner {
    static let application = DraftRegistry()
    private struct Owner { weak var value: (any DraftOwner)? }
    private var owners: [ObjectIdentifier: Owner] = [:]

    func track(_ owner: any DraftOwner) {
        guard ObjectIdentifier(owner) != ObjectIdentifier(self) else { return }
        owners[ObjectIdentifier(owner)] = Owner(value: owner)
    }

    var draftState: DraftState {
        owners = owners.filter { $0.value.value != nil }
        return owners.values.reduce(DraftState()) { $0.merging($1.value?.draftState ?? DraftState()) }
    }
}

/// Closing never approves review cards or sends a draft. Pending saves must finish first; unsaved
/// work requires the person's explicit choice to leave without saving (issue #435).
@MainActor struct DraftGuard {
    enum Action { case close, quit }
    let registry: DraftRegistry
    var confirm: @MainActor (Action, Bool) -> Bool = DraftGuard.ask

    func permits(_ action: Action) -> Bool {
        let state = registry.draftState
        if state.saving { _ = confirm(action, true); return false }
        return !state.hasChanges || confirm(action, false)
    }

    private static func ask(_ action: Action, saving: Bool) -> Bool {
        let alert = NSAlert()
        if saving {
            alert.messageText = "A save is still in progress"
            alert.informativeText = "Wait for it to finish before closing Sprava. Your unfinished work is still here."
            alert.addButton(withTitle: "Keep Working")
            _ = alert.runModal()
            return false
        }
        alert.messageText = action == .quit ? "Quit with unfinished work?" : "Close with unfinished work?"
        alert.informativeText = "Unsaved notes and edits may be lost. Keep working to save them, or continue without saving."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: action == .quit ? "Quit Without Saving" : "Close Without Saving")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

@MainActor final class ApplicationLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DraftGuard(registry: .application).permits(.quit) ? .terminateNow : .terminateCancel
    }
}
