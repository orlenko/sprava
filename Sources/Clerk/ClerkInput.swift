import Foundation
import SpravaKit

/// What the clerk reads from one capture (capture-event-v0 §4): the Capture target builds it from a capture event,
/// so the clerk never depends on the event format.
public struct ClerkInput: Sendable {
    /// The capture event's id.
    public var id: String
    public var text: String
    /// The event's `locale`, as written; the clerk checks it before use.
    public var locale: String?
    /// The capture's own calendar day (`Clerk.captureDay` of `captured_at`); nil when it cannot be read.
    public var captureDay: CalendarDate?
    /// `captured_at_estimated`: only full dates resolve (capture-event-v0 §6.6).
    public var estimated: Bool
    /// A private capture's items are redacted (capture-event-v0 §3.3).
    public var isPrivate: Bool
    /// The source's `kind`, such as `dictation`.
    public var sourceKind: String?
    /// The source's `app`, the producer named on the card.
    public var app: String

    public init(id: String, text: String, locale: String?, captureDay: CalendarDate?, estimated: Bool, isPrivate: Bool,
                sourceKind: String?, app: String) {
        self.id = id
        self.text = text
        self.locale = locale
        self.captureDay = captureDay
        self.estimated = estimated
        self.isPrivate = isPrivate
        self.sourceKind = sourceKind
        self.app = app
    }
}
