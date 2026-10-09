import BinderStore
import Foundation
import SpravaKit

// The inbox's cursor and its state file (capture-event-v0 §5.3).
extension CaptureInbox {
    /// The cursor (capture-event-v0 §5.3): what happened to each event id, the dedupe keys, and the names examined.
    package struct State: Codable {
        package var ingested: [String: String] = [:]          // id -> stage
        package var dedupe: [String: String] = [:]            // app|ref|revision -> id, as older cursors kept it; read only
        package var captures: [String: String]? = [:]         // ["app","ref","revision"] (CaptureEvent.dedupeKey) -> id
        var apps: [String: String] = [:]              // id -> source.app, for supersede chains
        package var cards: [String: String] = [:]             // id -> the proposal id of its card
        package var paths: [String: String]? = [:]            // id -> device/name, for the clerk
        var cardBinder: [String: String]? = [:]       // id -> folder path of a filed Tier 0 card
        var hints: [String: String]? = [:]            // id -> the binder name a verified hint named
        package var clerk: [String: String]? = [:]            // id -> pending, retry, done, kept, acted, poison, failed, retracted, superseded
        package var attempts: [String: Int]? = [:]
        var chains: [String: [String]]? = [:]         // app|ref -> event ids, as older cursors kept them; read only
        var chainsByKey: [String: [String]]? = [:]    // ["app","ref"] (CaptureEvent.chainKey) -> event ids, oldest first (§3.2)
        var texts: [String: String]? = [:]            // id -> SHA-256 of its text, to see a change that is not one
        var clocks: [String: String]? = [:]           // id -> its HLC as sortable text, to find a chain's current event
        var approx: [String]? = []                    // ids whose revision is an `approx:` one (capture-event-v0 §3.2, 7.8)
        var missingMedia: [String: [String: Int]]? = [:]   // id -> copied media not there when it was taken in (path -> bytes)
        var eventDigests: [String: String]? = [:]     // id -> sha256 of the event file as taken in
        package var raises: [String: [String]]? = [:]         // as older cursors kept raises (by event); read once into `debts`
        package var debts: [String]? = []                     // chain keys that owe a complete privacy pass (CaptureInbox+Privacy)
        var privates: [String]? = []                  // ids raised to private, or private by their chain (capture-event-v0 §3.3)
        package var examined: [String: Examined] = [:]        // device/name -> last seen
        var handoffs: [String: [Replacement]]? = [:]  // id -> the clerk's cards, named before any is saved, until its Tier 0 card gives way
        var committed: [String]? = []                 // ids whose clerk cards were all saved: the hand-off only goes forward now
        package var deferred: [String: [String]]? = [:] // binder folder -> an event of each chain whose work it missed while away
        var privateKeys: [String]? = []                 // chain keys a private event named, from any folder: their chains are private
        var keyEvents: [String: [String]]? = [:]        // chain key -> every event with that app and ref, from any folder
        var dupOf: [String: String]? = [:]              // a duplicate -> the event it repeats
        package struct Examined: Codable, Equatable {
            var size: Int
            var mtime: Double
            var outcome: String
        }
        /// One card the clerk keeps in place of the Tier 0 card: in `binder`, or unfiled when that save fell back.
        struct Replacement: Codable, Equatable {
            var binder: String?
            var card: String
        }

        package init() {}

        /// Brings clock keys an older cursor kept as `wall:counter:id` to `wall:counter:node:id` (`clockKey`), so every
        /// key compares the same way: the node is the device folder the event was read from (its `hlc.node` is that
        /// folder's name without hyphens, check 3 of capture-event-v0 §5.3). One whose folder is not known gets the
        /// node `-`, which sorts below every real one (hex digits and letters): it never outranks an event with the
        /// same wall time and counter from a known node, so such an event is taken in, never dropped as stale.
        mutating func migrateClocks() {
            guard let old = clocks, old.values.contains(where: { $0.split(separator: ":", omittingEmptySubsequences: false).count == 3 }) else { return }
            clocks = old.mapValues { _ in "" }
            for (id, key) in old {
                let parts = key.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 3 else { clocks?[id] = key; continue }
                let node = paths?[id]?.split(separator: "/").first.map { $0.replacingOccurrences(of: "-", with: "") } ?? "-"
                clocks?[id] = "\(parts[0]):\(parts[1]):\(node):\(parts[2])"
            }
        }
    }

    /// The cursor, for readers: empty when it cannot be read.
    package func loadState() -> State { (try? readState()) ?? State() }

    /// The cursor, for writers: a fresh one only when `state.json` does not exist. One that cannot be read throws,
    /// so it is never rebuilt over and no capture gets a second card (capture-event-v0 §5.3). Clock keys an older
    /// cursor kept are brought to the current form as it is read, before anything ranks them.
    package func readState() throws -> State {
        var state = try StateFile.read(State.self, from: stateURL) ?? State()
        state.migrateClocks()
        return state
    }

    package func save(_ s: State) throws {
        guard CursorCrash.allows(stateURL) else { throw Commands.Failure(message: "the cursor's save was stopped (a test's crash point)") }
        try AtomicFile.makePrivateFolder(dir)
        try AtomicFile.write(try JSONEncoder().encode(s), to: stateURL)
        CursorCrash.saved(stateURL)
    }
}

/// Crash points for tests, so the inbox's recovery can be exercised at every checkpoint. Either the cursor's saves
/// fail after a given number of them (the work after a failed save goes on, as with a full disk), or a test is told
/// right after a given save is on disk, takes the files as they are then, and puts them back after the sweep: what a
/// process killed right after that save leaves. Keyed by the cursor's path, so tests running side by side never meet;
/// nothing in the app sets either.
enum CursorCrash {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var left: [String: Int] = [:]
    nonisolated(unsafe) private static var stops: [String: (left: Int, take: @Sendable () -> Void)] = [:]

    /// Calls `take` right after the `saves`-th next save of the cursor at `url` is on disk; nil lifts it.
    static func stop(after saves: Int?, cursor url: URL, take: @escaping @Sendable () -> Void = {}) {
        lock.withLock { stops[url.path] = saves.map { ($0, take) } }
    }

    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    /// How many times the cursor at `url` has been saved in this process, so a test can pick any of a sweep's saves.
    static func saves(_ url: URL) -> Int { lock.withLock { counts[url.path] ?? 0 } }

    static func saved(_ url: URL) {
        let take: (@Sendable () -> Void)? = lock.withLock {
            counts[url.path, default: 0] += 1
            guard let stop = stops[url.path] else { return nil }
            if stop.left > 1 {
                stops[url.path] = (stop.left - 1, stop.take)
                return nil
            }
            stops[url.path] = nil
            return stop.take
        }
        take?()
    }

    /// Lets `saves` more saves of the cursor at `url` through, then fails every one; nil lifts the crash point.
    static func after(_ saves: Int?, cursor url: URL) { lock.withLock { left[url.path] = saves } }

    static func allows(_ url: URL) -> Bool {
        lock.withLock {
            guard let n = left[url.path] else { return true }
            guard n > 0 else { return false }
            left[url.path] = n - 1
            return true
        }
    }
}
