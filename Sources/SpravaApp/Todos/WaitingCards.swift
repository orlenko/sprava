import BinderStore
import Foundation
import Services
import Shelf

/// The Today page's line for cards waiting on a person (decisions.md D37). Read from the binders' card files, off the main
/// actor: the runtime's `proposals` command also writes new cards, which a look at Today must not do in every binder.
/// Only binders where a decision can be made count: adopted, writable and this Mac's own.
struct WaitingCards: Equatable, Sendable {
    struct Binder: Equatable, Sendable {
        let folder: URL
        let name: String
        let count: Int
    }

    /// The binders with cards, most first, Shelf order within that.
    var binders: [Binder] = []
    /// Binders whose cards could not be read. Their cards may be waiting; the binder's page says why.
    var unreadable: [Binder] = []

    static let namesShown = 3

    /// A device id that cannot be read counts nothing: no binder is this Mac's then, and the Health line already says so.
    static func read(rows: [ShelfRow], support: URL) -> WaitingCards {
        guard let device = try? DeviceID.existing(support: support) else { return WaitingCards() }
        return read(rows: rows, device: device)
    }

    static func read(rows: [ShelfRow], device: String) -> WaitingCards {
        var out = WaitingCards()
        for row in rows where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == device {
            do {
                let count = try ProposalStore.boundedList(in: row.folder).filter { $0.0.state == "proposed" }.count
                if count > 0 { out.binders.append(Binder(folder: row.folder, name: row.name, count: count)) }
            } catch {
                out.unreadable.append(Binder(folder: row.folder, name: row.name, count: 0))
            }
        }
        // A stable sort: `sorted` promises none, so the Shelf's order is kept by its index.
        out.binders = out.binders.enumerated().sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }.map(\.element)
        return out
    }

    /// Without the binders that have left the Shelf since this was read: Open must not lead to a binder that is gone.
    func keeping(_ rows: [ShelfRow]) -> WaitingCards {
        let folders = Set(rows.map(\.folder))
        return WaitingCards(binders: binders.filter { folders.contains($0.folder) },
                            unreadable: unreadable.filter { folders.contains($0.folder) })
    }

    func count(in folder: URL) -> Int { binders.first { $0.folder == folder }?.count ?? 0 }

    /// Where Open goes: the binder with the most, or one that could not be read.
    var target: URL? { binders.first?.folder ?? unreadable.first?.folder }

    var title: String? {
        let total = binders.reduce(0) { $0 + $1.count }
        if total == 1 { return "1 card is waiting for your decision" }
        if total > 1 { return "\(total) cards are waiting for your decision" }
        return unreadable.isEmpty ? nil : "Some cards could not be read"
    }

    var detail: String? {
        var parts = [String]()
        if !binders.isEmpty {
            var names = binders.prefix(Self.namesShown).map { "\($0.count) in \($0.name)" }
            if binders.count > Self.namesShown { names.append("and \(binders.count - Self.namesShown) more") }
            parts.append(names.joined(separator: ", "))
        }
        if !unreadable.isEmpty {
            let names = unreadable.prefix(Self.namesShown).map(\.name).joined(separator: ", ")
            let more = unreadable.count > Self.namesShown ? " and \(unreadable.count - Self.namesShown) more" : ""
            parts.append("Cards in \(names)\(more) could not be read.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }
}
