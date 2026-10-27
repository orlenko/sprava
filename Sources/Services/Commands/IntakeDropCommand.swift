import Backup
import BinderFormat
import BinderStore
import Capture
import Foundation
import Shelf
import SpravaKit

/// Whether something from outside may arrive in a binder: it is on this Mac's shelf (picked, or lifeproj's registry
/// and not archived) and no offload of it is queued or running. Email intake and dropped files both ask.
public enum ListedBinder {
    public static func accepts(_ folder: URL, support: URL) throws -> Bool {
        let shelf = ShelfStore(supportDirectory: support)
        let folders = try shelf.readFolders() + (shelf.registryForShelf()?.entries.filter { !$0.archived }.compactMap(\.workingDir).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? [])
        let listed = folders.contains { $0.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath() }
        let offloading = try BackupRequests(support: support).all().contains {
            $0.binder == folder.path && $0.kind == "offload" && ["queued", "running", "waiting_for_icloud"].contains($0.state)
        }
        return listed && !offloading
    }
}

extension Commands {
    /// A file the app opened from a drop, copied into the binder's `intake/` (conversation.md 5.1). The request is
    /// `{"command": "intake_drop", "binder": ..., "name": ...}`; the file arrives as an open descriptor, never a path.
    /// Runs on the command queue, so it never meets a removal or expunge of the same binder half-way.
    public func dropIntake(_ request: String, file: FileHandle, listed: (URL) throws -> Bool) -> String {
        do {
            guard request.utf8.count <= 16 * 1024, case .object(let r) = try JSONParser.parse(request).value,
                  r["command"] == .str("intake_drop"), let name = r["name"]?.stringValue, !name.isEmpty, name.utf8.count <= 1_024 else {
                throw Failure(message: "malformed drop")
            }
            let f = try folder(r)
            guard !Teka.expungePending(in: f) else {
                throw Failure(message: "An expunge in this binder was interrupted; finish it before adding files.")
            }
            guard FileManager.default.fileExists(atPath: f.appendingPathComponent(".sprava/ops.ndjson").path), ownerDevice(f) == deviceID else {
                throw Failure(message: "This binder is not managed by Sprava on this Mac, so files cannot be added to it here.")
            }
            guard try listed(f) else { throw Failure(message: "This binder is not on the shelf or is being offloaded.") }
            let path = try IntakeDrop.publish(file.fileDescriptor, name: name, into: f)
            return JSONWriter.compact(.obj([("ok", .bool(true)), ("path", .str(path))]))
        } catch let refused as IntakeDrop.Refused {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str(Self.sentence(refused)))]))
        } catch let failure as Failure {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str(failure.message))]))
        } catch {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .str("The file could not be copied into intake."))]))
        }
    }

    static func sentence(_ refused: IntakeDrop.Refused) -> String {
        switch refused {
        case .notAFile: "not a plain file of yours"
        case .tooLarge: "larger than 512 MB"
        case .keyFile: "a key or credential file, which Sprava never takes in"
        case .changed: "it changed while it was being copied"
        case .noSpace: "the binder's disk would have less than 5 GB free"
        case .unavailable: "intake could not be written"
        }
    }
}
