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
        package var raises: [String: [String]]? = [:]         // id -> a chain whose raise to private failed, retried each sweep
        var privates: [String]? = []                  // ids raised to private, or private by their chain (capture-event-v0 §3.3)
        package var examined: [String: Examined] = [:]        // device/name -> last seen
        var handoffs: [String: [Replacement]]? = [:]  // id -> the clerk's cards, named before any is saved, until its Tier 0 card gives way
        var committed: [String]? = []                 // ids whose clerk cards were all saved: the hand-off only goes forward now
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
    }

    /// The cursor, for readers: empty when it cannot be read.
    package func loadState() -> State { (try? readState()) ?? State() }

    /// The cursor, for writers: a fresh one only when `state.json` does not exist. One that cannot be read throws,
    /// so it is never rebuilt over and no capture gets a second card (capture-event-v0 §5.3).
    package func readState() throws -> State {
        try StateFile.read(State.self, from: stateURL) ?? State()
    }

    package func save(_ s: State) throws {
        guard CursorCrash.allows(stateURL) else { throw Commands.Failure(message: "the cursor's save was stopped (a test's crash point)") }
        try AtomicFile.makePrivateFolder(dir)
        try AtomicFile.write(try JSONEncoder().encode(s), to: stateURL)
    }
}

/// A crash point for tests: the cursor's saves fail after a given number of them, as if the process stopped right
/// after its last durable write, so the inbox's recovery can be exercised at every checkpoint. Keyed by the cursor's
/// path, so tests running side by side never meet; nothing in the app sets it.
enum CursorCrash {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var left: [String: Int] = [:]

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
