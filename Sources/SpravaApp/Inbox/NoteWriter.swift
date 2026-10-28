import Capture
import Foundation
import Services
import SpravaKit

/// One typed note written as a capture event (capture-event-v0 §8.1), as the Inbox and a binder's page both save
/// one. The runtime is told the note's id and digest first, so the binder named with it is trusted (architecture 8).
@MainActor
enum NoteWriter {
    enum Outcome: Equatable {
        /// Written; `noticed` is false when the runtime did not confirm the destination.
        case saved(noticed: Bool)
        /// Not written, with the sentence that says why.
        case refused(String)
    }

    /// The largest capture event the runtime reads (`SafeFile.read`'s limit, which `CaptureEvent.check` uses).
    static let largestNote = 16 * 1024 * 1024

    static func save(_ text: String, binderHint: String?, startedAt: Date, client: RuntimeClient, support: URL,
                     isPrivate: Bool = false, binder: URL? = nil) async -> Outcome {
        do {
            // The runtime makes this Mac's id at its first start; the app only reads it, never makes one.
            guard let deviceID = try DeviceID.existing(support: support) else {
                return .refused("The note was not saved: Sprava's background part has not started on this Mac yet. Health, at the top of the sidebar, shows when it runs.")
            }
            let producer = CaptureProducer(root: CaptureInbox.defaultRoot(support: support), deviceID: deviceID, support: support)
            let note = try producer.prepareNote(text, binderHint: binderHint, isPrivate: isPrivate, startedAt: startedAt)
            // The runtime reads no capture larger than this; one it would set aside must stay in the editor.
            guard note.bytes.count <= largestNote else {
                return .refused("The note was not saved: it is too long for one note. Split it into smaller notes.")
            }
            var noticed = true
            do {
                var fields: [(String, JSONValue)] = [("event", .string(note.id)), ("sha256", .string(note.digest))]
                if let binder { fields.append(("binder", .string(binder.path))) }
                _ = try await client.global("capture_notice", fields, timeout: 5)
            } catch {
                noticed = false
            }
            try producer.publish(note)
            return .saved(noticed: noticed)
        } catch {
            // Sprava's errors are sentences: an unreadable device id or note clock names its file and says it was
            // left as it is.
            return .refused("The note was not saved: \(error)")
        }
    }
}
