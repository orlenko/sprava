import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// The one write the document path rules need, kept with the binder writer (it throws `TekaStore.Refused`).
extension DocumentPaths {
    /// Creates the missing parent folders of `relative`, one at a time, refusing links.
    static func makeParents(_ relative: String, in folder: URL) throws {
        var url = folder
        for segment in relative.split(separator: "/").dropLast() {
            url = url.appendingPathComponent(String(segment))
            var st = stat()
            if lstat(url.path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFDIR else { throw TekaStore.Refused(reason: "\(segment) is not a folder") }
                continue
            }
            guard mkdir(url.path, 0o755) == 0 || errno == EEXIST else { throw AtomicFile.Failure(step: "create folder", code: errno) }
            // Whatever is there now must be a real folder: a link created in a race is refused.
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw TekaStore.Refused(reason: "\(segment) is not a folder") }
        }
    }
}
