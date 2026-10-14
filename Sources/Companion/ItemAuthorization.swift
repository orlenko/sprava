import Foundation
import SpravaKit

/// A higher adapter supplies the complete current open and closure records under the binder write lock.
/// `closedItems` is all closure entries, not the recently closed subset used for a phone view.
public struct CompanionItemReading: Sendable {
    public let openItems: [JSONValue]
    public let closedItems: [JSONValue]
    public let today: String
    public init(openItems: [JSONValue], closedItems: [JSONValue], today: String) {
        self.openItems = openItems; self.closedItems = closedItems; self.today = today
    }
}
/// Authorization selects only this mutation. BinderStore constructs its complete op, including recurrence.
public enum CompanionItemMutation: Sendable, Equatable {
    case complete, drop, followUp(date: String), arrived, postpone(date: String)
}
public enum CompanionItemAuthorization: Sendable, Equatable {
    case rejected(CompanionDecisionRejection), conflict, alreadyApplied, mutation(CompanionItemMutation)
}

extension CompanionProfile {
    /// companion-v0 §9.5: no writes or effects. Caller holds the device decision and binder write locks,
    /// resolves the binder by its current stable identity, and retains those locks through intent reservation.
    public func authorizeItemAction(_ action: CompanionRequestedAction, reading: CompanionItemReading) throws -> CompanionItemAuthorization {
        guard action.kind != .note, let binder = action.binderID, CompanionWire.isID(binder),
              let itemID = action.itemID, let wanted = ProjectionID.parse(itemID), let seen = action.seenVersion,
              seen >= 1, seen <= JSONNumber.maxSafeInteger, CalendarDate.strict(reading.today) != nil else { throw CompanionDecisionError.invalid }
        return try store.read { t in
            let rows = try t.rows("SELECT state, highest_indexed FROM phone_binders WHERE binder = ?", .text(binder))
            guard let row = rows.first else { return .rejected(.notShown) }
            guard row.count == 2, let state = row[0].text, ["preparing", "shown", "removed"].contains(state),
                  let indexed = row[1].integer, indexed >= 0, indexed <= JSONNumber.maxSafeInteger else { throw CompanionDecisionError.invalid }
            guard state == "shown" else { return .rejected(.notShown) }
            guard reading.openItems.count <= 200000, reading.closedItems.count <= 200000,
                  reading.openItems.count + reading.closedItems.count <= 200000 else { throw CompanionViewProjectionError.tooLarge }
            try CompanionViewProjection.budget(reading.openItems + reading.closedItems)
            let open = reading.openItems.filter { ProjectionID.parse($0["id"]) == wanted }
            let closed = reading.closedItems.filter { ProjectionID.parse($0["id"]) == wanted }
            guard !open.isEmpty || !closed.isEmpty else { return .rejected(.notInBinder) }
            guard open.count + closed.count == 1 else { return .conflict }
            guard seen <= indexed else { return .rejected(.futureVersion) }
            let item = (open.first ?? closed.first)!
            if !closed.isEmpty || item["status"] == .string("done") {
                let how = closed.isEmpty ? "done" : item["action"]?.stringValue
                return (action.kind == .done && how == "done") || (action.kind == .drop && how == "dropped") ? .alreadyApplied : .conflict
            }
            let raw = item["status"]?.stringValue ?? "open"
            let status = ["open", "waiting", "blocked"].contains(raw) ? raw : "open"
            let mutation: CompanionItemMutation
            switch action.kind {
            case .done: mutation = .complete
            case .drop: mutation = .drop
            case .followUp:
                guard status == "waiting" || status == "blocked" else { return .conflict }
                guard let date = action.date, CalendarDate.strict(date) != nil else { throw CompanionDecisionError.invalid }
                guard date >= reading.today else { return .conflict }; mutation = .followUp(date: date)
            case .arrived:
                guard status == "waiting" || status == "blocked" else { return .conflict }; mutation = .arrived
            case .postpone:
                guard status == "open", let due = item["due"]?.stringValue, due.utf8.count <= 32,
                      CalendarDate.lenient(due) != nil else { return .conflict }
                guard let date = action.date, CalendarDate.strict(date) != nil else { throw CompanionDecisionError.invalid }
                guard date >= reading.today else { return .conflict }; mutation = .postpone(date: date)
            case .note: throw CompanionDecisionError.invalid
            }
            let snapshots = try t.rows("SELECT hash, changed_in FROM phone_item_snapshots WHERE binder = ? AND id = ?",
                                      .text(binder), .blob(Data(JSONWriter.compact(itemID).utf8)))
            guard let snapshot = snapshots.first else { return .conflict }
            guard snapshot.count == 2, let hash = snapshot[0].text, hash.utf8.count == 71, hash.hasPrefix("sha256:"),
                  hash.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let changed = snapshot[1].integer, changed >= 1, changed <= JSONNumber.maxSafeInteger else { throw CompanionDecisionError.invalid }
            guard changed <= seen, CompanionViewProjection.safeRecord(item), try Canonical.hash(item) == hash else { return .conflict }
            return .mutation(mutation)
        }
    }
}
