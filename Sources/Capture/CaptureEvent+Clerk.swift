import BinderStore
import Clerk
import Foundation
import SpravaKit

extension CaptureEvent {
    /// What the clerk reads from this event (capture-event-v0 §4).
    public var clerkInput: ClerkInput {
        ClerkInput(id: id, text: text, locale: raw["locale"]?.stringValue,
                   captureDay: Clerk.captureDay(raw["captured_at"]?.stringValue ?? ""),
                   estimated: raw["captured_at_estimated"] == .bool(true), isPrivate: isPrivate,
                   sourceKind: raw["source"]?["kind"]?.stringValue, app: app)
    }
}

extension Clerk {
    /// Reads one capture event. `hint` is a binder name section 8 honours; `filing` is the filing list.
    public func read(_ event: CaptureEvent, filing: [FilingBinder], hint: String?, now: Date = Date()) async -> Interpretation {
        await read(event.clerkInput, filing: filing, hint: hint, now: now)
    }

    /// The proposals for one capture event's interpretation (capture-event-v0 §6.5).
    public static func proposals(_ interp: Interpretation, event: CaptureEvent, today: CalendarDate, client: String,
                                 now: Date = Date()) -> [(String?, Proposal)] {
        proposals(interp, event: event.clerkInput, today: today, client: client, now: now)
    }
}
