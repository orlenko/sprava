import Foundation
import SpravaKit

// The inbox's cursor and its state file (capture-event-v0 §5.3).
extension CaptureInbox {
    /// The cursor (capture-event-v0 §5.3): what happened to each event id, the dedupe keys, and the names examined.
    package struct State: Codable {
        package var ingested: [String: String] = [:]          // id -> stage
        package var dedupe: [String: String] = [:]            // app|ref|revision -> id
        var apps: [String: String] = [:]              // id -> source.app, for supersede chains
        package var cards: [String: String] = [:]             // id -> the proposal id of its card
        package var paths: [String: String]? = [:]            // id -> device/name, for the clerk
        var cardBinder: [String: String]? = [:]       // id -> folder path of a filed Tier 0 card
        var hints: [String: String]? = [:]            // id -> the binder name a verified hint named
        package var clerk: [String: String]? = [:]            // id -> pending, retry, done, kept, acted, poison, failed, retracted, superseded
        package var attempts: [String: Int]? = [:]
        var chains: [String: [String]]? = [:]         // app|ref -> event ids, oldest first (capture-event-v0 §3.2)
        var texts: [String: String]? = [:]            // id -> SHA-256 of its text, to see a change that is not one
        var clocks: [String: String]? = [:]           // id -> its HLC as sortable text, to find a chain's current event
        package var raises: [String: [String]]? = [:]         // id -> a chain whose raise to private failed, retried each sweep
        var privates: [String]? = []                  // ids raised to private, or private by their chain (capture-event-v0 §3.3)
        package var examined: [String: Examined] = [:]        // device/name -> last seen
        var handoffs: [String: [Replacement]]? = [:]  // id -> the clerk's cards, named before any is saved, until its Tier 0 card gives way
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
        try AtomicFile.makePrivateFolder(dir)
        try AtomicFile.write(try JSONEncoder().encode(s), to: stateURL)
    }
}
