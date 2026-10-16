import BinderFormat
import Foundation
import Services
import Shelf
import SpravaKit

/// Prepared beside the disk snapshot: each row's Now page, bucketed and sorted once per read off the main actor.
/// SwiftUI only reads it: the row's counts and the Binder screen's sections.
struct ShelfCounts: Sendable {
    /// Nil until the disk worker has prepared this row.
    let page: NowPage?

    init(page: NowPage? = nil) { self.page = page }

    func count(_ bucket: Bucket) -> Int { page?.count(bucket) ?? 0 }

    static func read(_ row: ShelfRow, _ today: CalendarDate) -> ShelfCounts {
        ShelfCounts(page: row.teka.nowPage(today: today))
    }
}

struct ShelfPresentation: Sendable {
    let snapshot: ShelfSnapshot.Snapshot
    let today: CalendarDate
    let counts: [URL: ShelfCounts]
    /// The To-dos page's board, merged from the rows' Now pages on the same worker.
    let todos: TodoBoard

    init(snapshot: ShelfSnapshot.Snapshot, today: CalendarDate, counts: [URL: ShelfCounts]) {
        self.snapshot = snapshot
        self.today = today
        self.counts = counts
        todos = TodoBoard(snapshot.rows.compactMap { row in
            counts[row.folder]?.page.map {
                TodoBoard.Source(name: row.name, folder: row.folder, writable: row.teka.isAdopted && !row.teka.writesBlocked, page: $0)
            }
        }, today: today)
    }
}
