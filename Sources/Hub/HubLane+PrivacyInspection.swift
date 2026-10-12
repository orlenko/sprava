import BinderFormat
import BinderStore
import CryptoKit
import Foundation
import SpravaKit

extension HubLane {
    public enum SlicePrivacyIssue: Equatable, Sendable {
        case privateSlice(String)
        case unknownPrivacy
        case showsMore
        case otherPublisher
        case unavailable
    }

    public struct PrivacyInspection {
        /// Nil unless the complete, bounded history successfully replayed.
        public let privacy: PrivacyRatchet.View?
        public let issues: [SlicePrivacyIssue]
    }

    /// Read-only privacy inspection (architecture 4.5; binder-v0 §8.3): the current, recorded and unexpired
    /// former slice names, using the same projection and comparison as withdrawal. No state is created or saved.
    /// Health's budget is 100 names, 8 MiB total slice bytes, and 1 MiB each for history, catalog and cursors.
    public static func inspectPrivacy(_ teka: Teka, root: URL?, now: Date = Date()) -> PrivacyInspection {
        let privacy = checkedPrivacy(teka)
        guard let root else { return PrivacyInspection(privacy: privacy, issues: []) }
        do {
            guard let spool = try StateDirectory.open(root), let inbox = try spool.directory("inbox") else {
                return PrivacyInspection(privacy: privacy, issues: [])
            }
            guard let state = try StateDirectory.open(teka.folder.appendingPathComponent(".sprava")) else {
                return PrivacyInspection(privacy: privacy, issues: [.unavailable])
            }
            let cursors = try inspectionCursors(state)
            let recorded = recordedSlices(cursors, folder: teka.folder)
            var names = Set([teka.name])
            names.formUnion(recorded.map(\.name))
            let formers = teka.catalog?["meta"]?["former_names"]?.arrayValue ?? []
            guard formers.count <= 100 else { return PrivacyInspection(privacy: privacy, issues: [.unavailable]) }
            for former in formers where isUnexpired(former, today: CalendarDate.today(now: now)) {
                if let name = former["name"]?.stringValue { names.insert(name) }
            }
            guard names.count <= 100, names.allSatisfy(isSafeSegment) else {
                return PrivacyInspection(privacy: privacy, issues: [.unavailable])
            }
            var budget = 8 << 20
            var shown: [JSONValue] = []
            var issues: [SlicePrivacyIssue] = []
            for name in names.sorted() {
                switch try inbox.read(name + ".agenda.json", limit: budget) {
                case .missing: continue
                case .refused, .unreadable:
                    issues.append(.unavailable)
                case .ok(let data):
                    budget -= data.count
                    guard let privacy else { issues.append(.unknownPrivacy); continue }
                    guard privacy.disclosure == "full" else {
                        issues.append(.privateSlice(privacy.disclosure)); continue
                    }
                    guard let value = try? JSONParser.parse(data).value, value["items"]?.arrayValue != nil,
                          let hash = try? Canonical.hash(stripGenerated(value)) else {
                        issues.append(.unavailable); continue
                    }
                    shown.append(value)
                    if !recorded.contains(where: { $0.name == name && $0.hash == hash }) { issues.append(.otherPublisher) }
                }
            }
            if !shown.isEmpty, let privacy, let catalog = teka.catalog {
                guard case .ok(let bytes) = try state.read("slice-key", limit: 32), bytes.count == 32 else {
                    return PrivacyInspection(privacy: privacy, issues: unique(issues + [.unavailable]))
                }
                let plan = plan(catalog, folder: teka.folder, cursors: cursors, privacy: privacy)
                let allowed = try projection(catalog: catalog, folderName: teka.folder.lastPathComponent,
                    closedOnce: plan.closedOnce, key: SymmetricKey(data: bytes), now: now,
                    alsoRedact: plan.keepRedacted, keepTitles: privacy.titles, confirmedTitles: plan.confirmedTitles,
                    lastSeen: cursors.published, allowTags: plan.allowTags, strict: false)
                if showsMore(shown, than: allowed.slice, cursors: cursors) { issues.append(.showsMore) }
            }
            return PrivacyInspection(privacy: privacy, issues: unique(issues))
        } catch {
            return PrivacyInspection(privacy: privacy, issues: [.unavailable])
        }
    }

    private static func unique(_ issues: [SlicePrivacyIssue]) -> [SlicePrivacyIssue] {
        issues.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    private static func inspectionCursors(_ state: StateDirectory) throws -> Cursors {
        switch try state.read("cursors.json", limit: 1 << 20) {
        case .missing: return Cursors()
        case .ok(let data):
            let c = try JSONDecoder().decode(Cursors.self, from: data)
            guard c.lastLogCount >= 0, (c.opCount ?? 0) >= 0, (c.pending?.lastLogCount ?? 0) >= 0 else {
                throw TekaStore.Refused(reason: "the hub cursors cannot be checked")
            }
            return c
        case .refused, .unreadable: throw TekaStore.Refused(reason: "the hub cursors cannot be checked")
        }
    }

    /// Validate before consulting the ratchet: even a syntactically valid op must not change privacy if replay
    /// rejects its hashes or semantics. Include the current catalog in the repeated-work budget.
    private static func checkedPrivacy(_ teka: Teka) -> PrivacyRatchet.View? {
        guard !teka.writesBlocked, let catalog = teka.catalog,
              case .ok(let catalogBytes) = SafeFile.read(teka.folder.appendingPathComponent("catalog.json"), limit: 1 << 20),
              let state = try? StateDirectory.open(teka.folder.appendingPathComponent(".sprava")),
              case .ok(let history) = try? state.read("ops.ndjson", limit: 1 << 20),
              let log = try? TekaStore(folder: teka.folder).readOpLog().ops, !log.isEmpty, log.count <= 100 else { return nil }
        var units = max(1, log.count)
        for op in log {
            units += op["args"]?["patch"]?.arrayValue?.count ?? 0
            units += op["args"]?["set"]?.objectValue?.entries.count ?? 0
            units += op["args"]?["unset"]?.arrayValue?.count ?? 0
            guard units <= 500 else { return nil }
        }
        guard catalogBytes.count + history.count <= (4 << 20) / units,
              (try? Replay.run(log)) != nil else { return nil }
        return PrivacyRatchet.view(folder: teka.folder, catalog: catalog)
    }
}
