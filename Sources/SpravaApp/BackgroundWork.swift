import AppKit
import ServiceManagement

/// Turning background work on from an action that found the runtime not running. The registration is Health's own
/// Turn On (`HealthModel.turnOn()`), so both places register the same way and refuse the same things.
@MainActor
enum BackgroundWork {
    enum TurnOn: Equatable {
        case registered
        /// macOS wants the person's approval first; Health has opened Login Items in System Settings for it.
        case needsApproval
        case failed(String)
    }

    /// Runs Health's Turn On and says how it went.
    static func turnOn(with health: HealthModel) -> TurnOn {
        health.turnOn()
        if health.runtime.status == .requiresApproval { return .needsApproval }
        return health.message.map(TurnOn.failed) ?? .registered
    }

    /// Asks, before an action that needs the runtime, whether to turn background work on. True for Turn On.
    static func offer() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Background work is off"
        alert.informativeText = "Sprava's background part makes every change to your binders, and it is not running. "
            + "Turn it on to continue; it then runs whenever you are logged in. Health, at the top of the sidebar, can turn it off again."
        alert.addButton(withTitle: "Turn On Background Work")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
