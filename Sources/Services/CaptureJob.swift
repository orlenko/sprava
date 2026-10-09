import Capture
import Foundation

/// The runtime's capture job (architecture 8): what one sweep of the capture root means for Health.
public enum CaptureJob {
    /// A state file that cannot be read first (nothing was swept), then one that could not be written (the sweep
    /// stopped there; the next sweep does again what was not recorded), then capture folders refused. A sweep that
    /// found nothing new still did its work.
    public static func outcome(_ result: CaptureInbox.SweepResult) -> JobOutcome {
        outcome(unreadable: result.unreadable, unsaved: result.unsaved, refusedFolders: result.refusedFolders)
    }

    static func outcome(unreadable: String?, unsaved: String?, refusedFolders: Int) -> JobOutcome {
        if let file = unreadable { return .error(code: "capture_state_unreadable", culprit: file) }
        if let file = unsaved { return .error(code: "capture_state_unwritable", culprit: file) }
        if refusedFolders > 0 { return .error(code: "capture_folder_refused", culprit: "\(refusedFolders) folder(s)") }
        return .ok
    }
}

/// Publishing a typed note (capture-event-v0 §5.2), and what a failure means. The producer's publish can throw
/// after the event file is already in place, when the folder could not be flushed: the note is then saved and will
/// be swept, but its name may not survive a power loss. Reported as such, never as "not saved", so nobody publishes
/// the same note again as a second event.
public enum NoteSave: Equatable, Sendable {
    case saved(id: String)
    /// The event file is in place; the flush that confirms it failed. Never publish it again.
    case savedNotConfirmed(id: String, reason: String)
    case notSaved(reason: String)

    /// Publishes `note` and says which of the three happened.
    public static func publish(_ note: CaptureProducer.PreparedNote, with producer: CaptureProducer) -> NoteSave {
        do {
            try producer.publish(note)
            return .saved(id: note.id)
        } catch {
            return after(error, id: note.id, producer: producer)
        }
    }

    /// After `publish` threw for the note `id`: saved when its event file is in the producer's folder (a plain
    /// file, not followed through a link), else not saved.
    public static func after(_ error: Error, id: String, producer: CaptureProducer) -> NoteSave {
        let file = producer.folder.appendingPathComponent("\(id).json")
        var st = stat()
        if lstat(file.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
            return .savedNotConfirmed(id: id, reason: "\(error)")
        }
        return .notSaved(reason: "\(error)")
    }
}
