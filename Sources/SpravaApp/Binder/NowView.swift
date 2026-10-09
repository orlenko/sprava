import AppKit
import Combine
import Backup
import BinderFormat
import Shelf
import SpravaKit
import SwiftUI

struct NowView: View {
    let row: ShelfRow
    let today: CalendarDate
    @ObservedObject var backup: BackupModel
    let reload: () -> Void
    @StateObject private var actions = BinderActions()

    func refresh() {
        reload()
        Task { await actions.load(row.folder, adopted: Teka.read(row.folder).isAdopted) }
    }

    var body: some View {
        let teka = row.teka
        let page = teka.nowPage(today: today)
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(teka.name).font(.title2.bold())
                        Spacer()
                        if !teka.isAdopted, teka.state >= .needsMigration {
                            Button("Adopt…") { actions.adopt(row.folder, inRegistry: row.source == .registry, reload: refresh) }
                                .disabled(actions.busy)
                        }
                    }
                    if let message = actions.message { Text(message).foregroundStyle(.orange) }
                    Text("\(teka.level?.label ?? "unreadable") · \(row.stateLabel) · today \(today.description)")
                        .foregroundStyle(.secondary)
                    if teka.state < .needsMigration {
                        ForEach(teka.reasons, id: \.self) { Text("• \($0)").foregroundStyle(.orange) }
                    }
                    if !teka.findings.isEmpty {
                        Text("\(teka.findings.count) rule finding(s); run `sprava check` for the list.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            ReviewSection(actions: actions, folder: row.folder, reload: refresh)
            ForEach(Bucket.allCases, id: \.self) { bucket in
                if bucket == .recentlyClosed {
                    if !page.closed.isEmpty {
                        Section(header: BucketHeader(bucket: bucket, count: page.closed.count)) {
                            ForEach(page.closed.enumerated().map { ("closed-\($0.offset)", $0.element) }, id: \.0) { _, entry in
                                HStack {
                                    Text(entry.closedOn?.description ?? "date unknown")
                                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                                    Text(entry.title).strikethrough(entry.action == "done")
                                    Spacer()
                                    Text(entry.action).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else if let items = page.items[bucket], !items.isEmpty {
                    Section(header: BucketHeader(bucket: bucket, count: items.count)) {
                        // Row ids are unique across sections: List reuses rows by id, and two sections that both
                        // start at 0 would show one section's row in the other.
                        ForEach(items.map { ("item-\($0.index)", $0) }, id: \.0) { _, item in
                            ItemRow(item: item, bucket: bucket)
                                .contextMenu {
                                    if teka.isAdopted, !item.hasRecurrence {
                                        Button("Done") { actions.close(item, as: "complete", row.folder, reload: refresh) }
                                        Button("Drop") { actions.close(item, as: "drop", row.folder, reload: refresh) }
                                    }
                                }
                        }
                    }
                }
            }
            if page.hiddenCount > 0 {
                Text("\(page.hiddenCount) dismissed item(s) hidden").foregroundStyle(.secondary)
            }
            HistorySection(actions: actions, folder: row.folder, reload: refresh)
            if teka.isAdopted {
                FilingSection(actions: actions, folder: row.folder)
                KeepingSection(actions: actions, folder: row.folder, today: today, reload: refresh)
                OffloadSection(backup: backup, folder: row.folder,
                               openItems: teka.items.filter { $0.declaredStatus != .done && !$0.isDismissed }.map(\.title))
            }
        }
        .task(id: row.folder) {
            await actions.load(row.folder, adopted: teka.isAdopted)
            // Cards that capture, intake, the clerk or a brain add show up while the binder stays open (mvp.md:
            // "within a minute the review queue shows a card").
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                if Teka.read(row.folder).isAdopted { await actions.loadReview(row.folder) }
            }
        }
    }
}

struct BucketHeader: View {
    let bucket: Bucket
    let count: Int
    var body: some View { Text("\(bucket.title) (\(count))").font(.headline) }
}

struct ItemRow: View {
    let item: Item
    let bucket: Bucket

    var dateText: String {
        if bucket == .nudge || bucket == .waiting {
            return item.followUpAt.map { "chase \($0)" } ?? "chase now"
        }
        return item.due?.description ?? ""
    }

    var details: [String] {
        var parts: [String] = []
        if let party = item.waitingOn { parts.append("waiting on \(party)") }
        if bucket == .nudge || bucket == .waiting, let due = item.due { parts.append("due \(due.description)") }
        if item.hasRecurrence { parts.append("repeats; the hub manages it for now") }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#\($0)" }.joined(separator: " ")) }
        return parts
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: item.priority == .high ? "exclamationmark.circle.fill" : "circle")
                .foregroundStyle(item.priority == .high ? .red : .secondary)
            Text(dateText).monospacedDigit().foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if !details.isEmpty {
                    Text(details.joined(separator: "   ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
