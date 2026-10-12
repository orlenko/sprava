import BinderFormat
import Foundation
import Services
import Shelf
import SpravaKit

/// Prepared beside the disk snapshot; SwiftUI only reads these small values during rendering.
struct ShelfCounts: Sendable {
    private var values: [Bucket: Int] = [:]

    func count(_ bucket: Bucket) -> Int { values[bucket] ?? 0 }

    static func read(_ row: ShelfRow, _ today: CalendarDate) -> ShelfCounts {
        let page = row.teka.nowPage(today: today)
        var result = ShelfCounts()
        for bucket in Bucket.allCases { result.values[bucket] = page.count(bucket) }
        return result
    }
}

struct ShelfPresentation: Sendable {
    let snapshot: ShelfSnapshot.Snapshot
    let today: CalendarDate
    let counts: [URL: ShelfCounts]
}
