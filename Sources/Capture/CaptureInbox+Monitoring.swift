import BinderStore
import Darwin
import Foundation
import SpravaKit

/// Monitoring refuses excessive work without changing captures, cards, quarantine or the journal.
extension CaptureInbox {
    public enum MonitoringError: Error, Sendable { case budget, unreadable }

    public struct Health: Sendable {
        public var unfiled = 0
        public var quarantined = 0
        public var oldestUnfiledSeconds: Int?
        /// Counts are unavailable when the records cannot be read safely within the monitoring budget.
        public var error: String?
    }

    public struct MeasurementInput: Sendable {
        public let journal: [JSONObject]
        public let events: [String: CaptureEvent]
        public let unfiled: [Proposal]
    }

    /// Monitoring's unfiled cards: at most 100 directory entries and 8 MiB of card bytes.
    /// Digest verification and filename/id agreement remain the same as the Inbox's ordinary reader.
    public func boundedUnfiled() throws -> [Proposal] {
        guard let supportDirectory = try monitorSupport() else { return [] }
        guard let cards = try supportDirectory.directory("unfiled") else { return [] }
        var entries = 100
        let names = try Self.monitorNames(unfiledDir, remaining: &entries)
        let digests: [String: String]
        if let capture = try supportDirectory.directory("capture"),
           let data = try Self.monitorData(capture, "unfiled-digests.json", limit: 1 << 20) {
            do { digests = try JSONDecoder().decode([String: String].self, from: data) }
            catch { throw MonitoringError.unreadable }
        } else { digests = [:] }
        var bytes = 8 << 20
        var out: [Proposal] = []
        for name in names.sorted() where name.hasSuffix(".json") && ProposalStore.isValidID(String(name.dropLast(5))) {
            let id = String(name.dropLast(5))
            guard let data = try Self.monitorData(cards, name, limit: bytes) else { continue }
            bytes -= data.count
            guard Self.accepted(digests[id]).contains(Self.digest(data)) else { continue }
            guard case .object(let raw)? = try? JSONParser.parse(data).value, raw["id"]?.stringValue == id else { continue }
            out.append(Proposal(raw: raw))
        }
        return out
    }

    func boundedHealth(now: Date) throws -> Health {
        let cards = try boundedUnfiled()
        let oldest = cards.compactMap { Timestamp.parse($0.raw["created_at"]?.stringValue ?? "") }.min()
        var result = Health(unfiled: cards.count, oldestUnfiledSeconds: oldest.map { Int(now.timeIntervalSince($0)) })
        guard let supportDirectory = try monitorSupport(), let capture = try supportDirectory.directory("capture"),
              try capture.directory("quarantine") != nil else { return result }
        var remaining = 1_000
        var folders = [quarantineDir]
        while let folder = folders.popLast() {
            for name in try Self.monitorNames(folder, remaining: &remaining) {
                let file = folder.appendingPathComponent(name)
                var info = stat()
                guard lstat(file.path, &info) == 0 else { throw MonitoringError.unreadable }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: folders.append(file)
                case S_IFREG: if name.hasSuffix(".why") { result.quarantined += 1 }
                default: throw MonitoringError.unreadable
                }
            }
        }
        return result
    }

    /// Bounded shadow-report inputs: 4 MiB/10,000 journal records, at most 1,000 capture sources with 8 MiB
    /// aggregate bytes, and the ordinary bounded unfiled cards. Refusal fails the report, never truncates it.
    public func measurementInput() throws -> MeasurementInput {
        guard let supportDirectory = try monitorSupport(), let capture = try supportDirectory.directory("capture") else {
            return MeasurementInput(journal: [], events: [:], unfiled: try boundedUnfiled())
        }
        var journal: [JSONObject] = []
        if let data = try Self.monitorData(capture, "journal.ndjson", limit: 4 << 20) {
            guard let text = String(data: data, encoding: .utf8) else { throw MonitoringError.unreadable }
            for line in text.split(separator: "\n") {
                guard journal.count < 10_000 else { throw MonitoringError.budget }
                guard case .object(let row)? = try? JSONParser.parse(String(line)).value else { throw MonitoringError.unreadable }
                journal.append(row)
            }
        }
        let ids = Set(journal.filter { $0["stage"] == .str("ingested") }.compactMap { $0["event"]?.stringValue })
        guard ids.count <= 1_000 else { throw MonitoringError.budget }
        let state: State
        do { state = try readState() } catch { throw MonitoringError.unreadable }
        var events: [String: CaptureEvent] = [:]
        var bytes = 8 << 20
        let sources = try StateDirectory.open(root)
        for id in ids {
            guard let path = state.paths?[id] else { continue }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw MonitoringError.unreadable
            }
            // A producer may already have removed an old source; absence stays the report's ordinary omission.
            guard let device = try sources?.directory(parts[0]),
                  let data = try Self.monitorData(device, parts[1], limit: bytes) else { continue }
            bytes -= data.count
            guard case .object(let raw)? = try? JSONParser.parse(data).value else { throw MonitoringError.unreadable }
            events[id] = CaptureEvent(raw: raw, url: root.appendingPathComponent(path), digest: "")
        }
        return MeasurementInput(journal: journal, events: events, unfiled: try boundedUnfiled())
    }

    private func monitorSupport() throws -> StateDirectory? {
        do { return try StateDirectory.open(support) } catch { throw MonitoringError.unreadable }
    }

    private static func monitorData(_ directory: StateDirectory, _ name: String, limit: Int) throws -> Data? {
        let outcome: SafeFile.Outcome
        do { outcome = try directory.read(name, limit: limit) } catch { throw MonitoringError.unreadable }
        switch outcome {
        case .ok(let data): return data
        case .missing: return nil
        case .refused(let why) where why.hasPrefix("larger than"): throw MonitoringError.budget
        case .refused, .unreadable: throw MonitoringError.unreadable
        }
    }

    /// Directory streaming counts every entry before retaining it. No unbounded contentsOfDirectory/allObjects.
    private static func monitorNames(_ folder: URL, remaining: inout Int) throws -> [String] {
        let fd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw MonitoringError.unreadable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            close(fd); throw MonitoringError.unreadable
        }
        guard let directory = fdopendir(fd) else { close(fd); throw MonitoringError.unreadable }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw MonitoringError.unreadable }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard remaining > 0 else { throw MonitoringError.budget }
            remaining -= 1
            names.append(name)
        }
        return names
    }
}
