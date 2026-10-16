import Foundation
import SpravaKit

/// conversation §11.1 structured engine transport: bounded JSON objects, delivered one at a time.
/// Claude CLI framing: https://code.claude.com/docs/en/headless (stream-json).
/// This validates framing only, NOT session identity, startup confinement, event schemas or turn success.
/// The driver must separately validate each event and require a genuine result before completing a turn.
public struct AgentJSONLines: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case invalidLimit, closed, frameTooLarge, invalidFrame, truncatedFrame
    }
    private let maximumLineBytes: Int
    private var buffered = Data()
    private var closed = false

    /// Trusted runtime configuration; the hard ceiling bounds parser work even on an unterminated line.
    /// The limit includes JSON whitespace and any trailing CR; only the terminating LF is excluded.
    public init(maximumLineBytes: Int) throws {
        guard (1...(16 * 1024 * 1024)).contains(maximumLineBytes) else { throw Failure.invalidLimit }
        self.maximumLineBytes = maximumLineBytes
    }

    /// Raw read chunks may split a Unicode scalar or contain several lines. No array of events is retained.
    /// Decoder errors are fixed values, never parser diagnostics containing engine-controlled text.
    /// A receiver error also closes the decoder and propagates to its owner; no frame is replayed.
    public mutating func append(_ bytes: Data, receive: (JSONObject) throws -> Void) throws {
        guard !closed else { throw Failure.closed }
        do {
            for byte in bytes {
                if byte == 0x0A {
                    let object = try decodeLine()
                    buffered.removeAll(keepingCapacity: false)
                    try receive(object)
                } else {
                    guard buffered.count < maximumLineBytes else { throw Failure.frameTooLarge }
                    buffered.append(byte)
                }
            }
        } catch {
            closed = true; buffered.removeAll(keepingCapacity: false); throw error
        }
    }

    /// An unterminated final object is refused even if its JSON parses. Clean framing alone is not a result.
    public mutating func finish() throws {
        guard !closed else { throw Failure.closed }
        closed = true
        let truncated = !buffered.isEmpty
        buffered.removeAll(keepingCapacity: false)
        if truncated { throw Failure.truncatedFrame }
    }

    private func decodeLine() throws -> JSONObject {
        do {
            let parsed = try JSONParser.parse(buffered)
            guard parsed.safety.isSafe, let object = parsed.value.objectValue,
                  let type = object["type"]?.stringValue, !type.isEmpty, type.utf8.count <= 128 else {
                throw Failure.invalidFrame
            }
            return object
        } catch { throw Failure.invalidFrame }
    }
}
