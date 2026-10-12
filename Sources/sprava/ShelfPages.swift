import BinderFormat
import Foundation
import Shelf
import SpravaKit

func shelf(_ args: [String]) {
    var args = args
    if let sub = args.first, sub == "add" || sub == "remove" {
        guard args.count == 2 else { fail(usage) }
        let store = ShelfStore()
        let folder = folderURL(args[1])
        do {
            if sub == "add" {
                let teka = Teka.read(folder)
                if teka.state == .notATeka { fail("\(folder.path): no catalog.json, so not a binder") }
                try store.add(folder)
                print("added \(teka.name) (\(teka.state.label))")
            } else {
                try store.remove(folder)
                print("removed \(folder.path)")
            }
        } catch {
            fail("could not update the shelf: \(error.localizedDescription)", code: 1)
        }
        return
    }
    let includeArchived = args.contains("--archived")
    args.removeAll { $0 == "--archived" }
    guard args.isEmpty else { fail(usage) }

    var registry: LifeprojRegistry?
    var note: String?
    do { registry = try ShelfStore().registryForShelf() } catch { note = "registry unreadable: \(error.localizedDescription)" }
    let rows = Shelf.rows(registry: registry, picked: ShelfStore().pickedFolders(), includeArchived: includeArchived)
    let today = CalendarDate.today()
    if rows.isEmpty {
        print("The shelf is empty. Add a binder with `sprava shelf add <folder>`.")
    }
    let width = min(32, rows.map(\.name.count).max() ?? 4)
    for row in rows {
        let page = row.teka.nowPage(today: today)
        let counts = row.teka.items.isEmpty && row.teka.catalog == nil
            ? ""
            : "overdue \(page.count(.overdue)) · nudge \(page.count(.nudge)) · today \(page.count(.today))"
        let tag = row.archived ? " [archived]" : ""
        print("\(pad(row.name, width))  \(pad(row.stateLabel, 16))  \(pad(ago(row.teka.modified), 8))  \(counts)\(tag)")
    }
    if let note { print("\nNote: \(note)") }
}

func now(_ args: [String]) {
    var args = args
    let today = todayFrom(&args)
    guard args.count == 1 else { fail(usage) }
    let teka = Teka.read(folderURL(args[0]))
    switch teka.state {
    case .notATeka, .corrupt: fail("\(teka.name): \(teka.state.label) (\(teka.reasons.joined(separator: "; ")))", code: 1)
    default: break
    }
    print("\(teka.name) · \(teka.level?.label ?? "?") · \(teka.isAdopted ? teka.state.label : "not yet adopted") · \(today)")
    let page = teka.nowPage(today: today)
    for bucket in Bucket.allCases {
        if bucket == .recentlyClosed {
            guard !page.closed.isEmpty else { continue }
            print("\n\(bucket.title.uppercased())")
            for entry in page.closed {
                print("  \(pad(entry.closedOn?.description ?? "date unknown", 12))  \(entry.title)  (\(entry.action))")
            }
            continue
        }
        let items = page.items[bucket, default: []]
        guard !items.isEmpty else { continue }
        print("\n\(bucket.title.uppercased())")
        for item in items {
            let mark = item.priority == .high ? "!" : " "
            var date = item.due?.description ?? "-"
            if bucket == .nudge || bucket == .waiting { date = item.followUpAt.map { "chase \($0)" } ?? "chase now" }
            var line = "  \(mark) \(pad(date, 16))  \(item.title)"
            if let party = item.waitingOn, bucket == .nudge || bucket == .waiting { line += "  ← \(party)" }
            if item.hasRecurrence { line += "  (repeats)" }
            print(line)
        }
    }
    if page.hiddenCount > 0 { print("\n\(page.hiddenCount) dismissed item(s) hidden") }
    if teka.state < .ready, teka.state != .needsMigration || teka.isAdopted {
        print("\nState: \(teka.state.label): \(teka.reasons.joined(separator: "; "))")
    }
}

func check(_ args: [String]) {
    guard args.count == 1 else { fail(usage) }
    let teka = Teka.read(folderURL(args[0]))
    print("\(teka.name): \(teka.state.label)\(teka.level.map { " (\($0.label))" } ?? "")")
    for reason in teka.reasons { print("  - \(reason)") }
    let s = teka.safety
    if !s.isSafe {
        print("  unsafe JSON: \(s.duplicateKeys.count) duplicate key(s), \(s.loneSurrogates.count) lone surrogate(s), \(s.unsafeNumbers.count) unsafe number(s)")
    }
    for finding in teka.findings { print("  \(finding)") }
    exit(teka.state <= .corrupt ? 1 : 0)
}
