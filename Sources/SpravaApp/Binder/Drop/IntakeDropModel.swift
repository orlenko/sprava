import AppKit
import BinderFormat
import Combine
import Darwin
import Foundation
import SpravaKit

/// Files dropped on a binder (conversation.md 5.1): from Finder as files, from Outlook, Mail or Photos as file promises.
/// Every file passes one opener (no link followed, nothing but a plain file) and goes to the runtime as an open
/// descriptor; the runtime copies it into the binder's `intake/`. The app writes no binder, and the original stays put.
@MainActor
final class IntakeDropModel: ObservableObject {
    typealias Send = @MainActor (_ binder: URL, _ name: String, _ file: FileHandle) async throws -> JSONObject
    /// A drop's bounds, counted before anything is sent (conversation.md 5, proposed).
    static let maxFiles = 200
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    @Published private(set) var busy = false
    @Published private(set) var report: String?
    @Published private(set) var problem = false
    let send: Send

    init(send: Send? = nil) {
        let client = RuntimeClient()
        self.send = send ?? { binder, name, file in try await client.importFile(binder: binder, name: name, file: file) }
    }

    /// One drop. Promised files must be asked for while the drop is still being performed, so receiving starts here,
    /// into a private folder of the app's that is removed afterwards; the rest runs after. False when busy or empty.
    @discardableResult
    func drop(_ urls: [URL], promises: [NSFilePromiseReceiver], into binder: URL) -> Bool {
        guard !busy, !urls.isEmpty || !promises.isEmpty else { return false }
        busy = true
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-drop-" + UUID().uuidString)
        var held: [(String, String)] = []
        var receiving: Received?
        if !promises.isEmpty {
            do {
                try AtomicFile.makePrivateFolder(staging)
                receiving = Self.receive(promises, into: staging)
            } catch {
                held.append(("promised files", "Sprava could not make a private folder to receive them"))
            }
        }
        Task {
            var files = urls
            if let receiving {
                let received = await receiving.result()
                files += received.files
                if received.failed > 0 { held.append(("\(received.failed) promised file(s)", "the other app did not deliver them")) }
            }
            await add(files, into: binder, held: held)
            try? FileManager.default.removeItem(at: staging)
            busy = false
        }
        return true
    }

    func dismiss() { report = nil; problem = false }

    static let webDragHint = "That message came from a web app, which hands over no email when it is dragged. Select the message's text and drag the selection, or save the message as .eml or PDF and drop that file."
    func explainWebDrag() { report = Self.webDragHint; problem = true }

    /// Text dragged as a selection, kept as one file: the HTML when there is some, so links and layout survive, else
    /// the plain text. Named for when it arrived; the intake reads it like any document.
    @discardableResult
    func dropText(html: String?, plain: String?, into binder: URL, now: Date = Date()) -> Bool {
        let body: (data: Data, ext: String)? = html.flatMap { $0.isEmpty ? nil : (Data(("<!doctype html><meta charset=\"utf-8\">\n" + $0).utf8), "html") }
            ?? plain.flatMap { $0.isEmpty ? nil : (Data($0.utf8), "txt") }
        guard !busy, let body else { return false }
        guard body.data.count <= 16 * 1024 * 1024 else { report = "Nothing was added: the dragged text is over 16 MB."; problem = true; return false }
        busy = true
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-drop-" + UUID().uuidString)
        let stamp = now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
                                            timeZone: .current, calendar: Calendar(identifier: .gregorian)))
        let file = staging.appendingPathComponent("Dropped text \(stamp).\(body.ext)")
        Task {
            do {
                try AtomicFile.makePrivateFolder(staging)
                try AtomicFile.write(body.data, to: file)
                await add([file], into: binder)
            } catch {
                report = "Nothing was added: Sprava could not keep the dragged text to send it."; problem = true
            }
            try? FileManager.default.removeItem(at: staging)
            busy = false
        }
        return true
    }

    /// Sends each plain file; a folder gives its plain files, one level deep. Nothing is sent when the drop is over
    /// its bounds.
    func add(_ items: [URL], into binder: URL, held initial: [(String, String)] = []) async {
        var held = initial
        var files: [(url: URL, name: String, size: Int64)] = []
        for item in items {
            // A link dropped by itself is resolved once; its target then meets the same opener as everything else.
            let url = item.resolvingSymlinksInPath()
            var info = stat()
            guard lstat(url.path, &info) == 0 else { held.append((item.lastPathComponent, "it is no longer there")); continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
                for name in names where !name.hasPrefix(".") {
                    let child = url.appendingPathComponent(name)
                    var c = stat()
                    guard lstat(child.path, &c) == 0, c.st_mode & S_IFMT == S_IFREG else {
                        held.append((item.lastPathComponent + "/" + name, "only plain files one level inside a folder are taken")); continue
                    }
                    files.append((child, name, Int64(c.st_size)))
                }
            } else if info.st_mode & S_IFMT == S_IFREG {
                // A link is judged by what it points at too: `receipt.txt` pointing at `server.pem` is a key file.
                if DocumentPaths.isKeyFile(url.lastPathComponent) {
                    held.append((item.lastPathComponent, "a key or credential file, which Sprava never takes in")); continue
                }
                files.append((url, item.lastPathComponent, Int64(info.st_size)))
            } else {
                held.append((item.lastPathComponent, "not a plain file"))
            }
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard files.count <= Self.maxFiles, total <= Self.maxBytes else {
            report = "Nothing was added: this drop has \(files.count) files, \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)). One drop takes at most \(Self.maxFiles) files and 2 GB."
            problem = true
            return
        }
        var added: [String] = []
        for file in files {
            if DocumentPaths.isKeyFile(file.name) { held.append((file.name, "a key or credential file, which Sprava never takes in")); continue }
            let fd = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var info = stat()
            guard fd >= 0 else { held.append((file.name, "it could not be opened")); continue }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); held.append((file.name, "not a plain file")); continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                let answer = try await send(binder, file.name, handle)
                added.append(answer["path"]?.stringValue.map { ($0 as NSString).lastPathComponent } ?? file.name)
            } catch {
                held.append((file.name, (error as? RuntimeClient.Failure)?.message ?? "it could not be copied"))
            }
            try? handle.close()
        }
        report = Self.describe(added: added, held: held)
        problem = !held.isEmpty
    }

    static func describe(added: [String], held: [(String, String)]) -> String {
        var lines: [String] = []
        if !added.isEmpty {
            let shown = added.prefix(5).joined(separator: ", ") + (added.count > 5 ? " and \(added.count - 5) more" : "")
            lines.append("Added to intake: \(shown). Each becomes a card to file within a minute.")
        }
        for (name, reason) in held.prefix(5) { lines.append("Not added: \(name), \(reason).") }
        if held.count > 5 { lines.append("\(held.count - 5) more not added.") }
        return lines.isEmpty ? "Nothing was dropped." : lines.joined(separator: "\n")
    }

    /// Asks for every promised file; `result()` waits for them, or a minute, after which an undelivered file counts as
    /// failed. Nonisolated: AppKit calls the readers on the queue it is given, never the main actor.
    nonisolated static func receive(_ promises: [NSFilePromiseReceiver], into folder: URL) -> Received {
        let state = Received()
        let queue = OperationQueue()
        for promise in promises {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue, reader: reader(state))
        }
        // A legacy promise may announce one type and deliver several files; its names are known once asked for, so the
        // count comes from them, and the wait ends only when every named file has arrived or failed.
        state.expect(promises.reduce(0) { $0 + max($1.fileNames.count, $1.fileTypes.count, 1) })
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { state.finish() }
        return state
    }

    nonisolated static func reader(_ state: Received) -> @Sendable (URL, (any Error)?) -> Void {
        { url, error in state.arrived(error == nil ? url : nil) }
    }

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var expected: Int?
        private var files: [URL] = []
        private var count = 0
        private var finished: (files: [URL], failed: Int)?
        private var waiting: [CheckedContinuation<(files: [URL], failed: Int), Never>] = []
        func expect(_ total: Int) {
            lock.lock(); expected = total; let done = count >= total; lock.unlock()
            if done { finish() }
        }
        func arrived(_ url: URL?) {
            lock.lock(); count += 1; if let url, finished == nil { files.append(url) }; let done = expected.map { count >= $0 } ?? false; lock.unlock()
            if done { finish() }
        }
        func finish() {
            lock.lock()
            if finished == nil { finished = (files, max(expected ?? count, count) - files.count) }
            let result = finished!, resume = waiting; waiting = []
            lock.unlock()
            for c in resume { c.resume(returning: result) }
        }
        func result() async -> (files: [URL], failed: Int) {
            await withCheckedContinuation { c in
                lock.lock()
                if let finished { lock.unlock(); c.resume(returning: finished) } else { waiting.append(c); lock.unlock() }
            }
        }
    }
}
