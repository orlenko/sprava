import Foundation
import Security
import SpravaKit

/// Runs the sandboxed `sprava-extract` helper on one file (architecture 2.1): the bytes go in on standard input,
/// JSON comes back; a crash or a hang ends only the helper.
public enum ExtractHelper {
    /// The helper beside the running executable (the app bundle, or a development build's products). `run` refuses one
    /// that is not signed with its sandbox, such as one built by `swift build`.
    public static func locate() -> URL? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sprava-extract"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("sprava-extract")].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// What reads a document. Untrusted bytes are parsed only in the helper; a helper that cannot be found holds
    /// every file instead of reading it here. Reading in this process is for tests, and is asked for by name.
    public enum Reader: Sendable, Equatable {
        case helper(URL)
        case missing
        case inProcess

        /// The helper beside the running executable, or `missing`.
        public static func located() -> Reader { locate().map(Reader.helper) ?? .missing }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Reads `file` and runs the helper on its bytes. `root` is the folder the caller trusts (the binder, for a file
    /// in its intake): the file is opened from it down, and one outside it is refused. It is never guessed from the
    /// file's path, which a link below the binder could shape.
    public static func run(_ file: URL, under root: URL, reader: Reader, timeout: TimeInterval = 180) throws -> Extractor.Result {
        if reader == .missing { throw Self.missing }
        // Never through a link, which could lead a harmless name to a credential file, and never anything but a
        // regular file of this user within the size limit, so a FIFO or a device cannot stall the read.
        switch read(file, under: root, limit: Extractor.Limits().bytes) {
        case .ok(let data): return try run(data, name: file.lastPathComponent, reader: reader, timeout: timeout)
        case .refused(let why): throw Failure(message: "the file was not opened: it is \(why)")
        case .missing: throw Failure(message: "the file is not there")
        case .unreadable(let why): throw Failure(message: "the file cannot be read now (\(why))")
        }
    }

    /// A file below `root`, opened from `root` down with no symbolic link anywhere on the way (`O_NOFOLLOW_ANY`):
    /// `intake/mail` linked to a folder elsewhere never leads a read out of the binder. Only regular files of this
    /// user within the limit are read, as `SafeFile.read` does.
    static func read(_ file: URL, under root: URL, limit: Int) -> SafeFile.Outcome {
        let base = root.standardizedFileURL.pathComponents, path = file.standardizedFileURL.pathComponents
        guard path.count > base.count, Array(path.prefix(base.count)) == base else { return .refused("outside the folder it is read from") }
        let dir = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable(String(cString: strerror(errno))) }
        defer { close(dir) }
        var fd: Int32
        repeat { fd = openat(dir, path.dropFirst(base.count).joined(separator: "/"), O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK) }
        while fd < 0 && errno == EINTR
        if fd < 0 {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case ELOOP: return .refused("a symbolic link, or inside a folder that is one")
            case EACCES, EPERM: return .refused("not readable by this user")
            default: return .unreadable(String(cString: strerror(errno)))
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable(String(cString: strerror(errno))) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .refused("not a plain file") }
        guard st.st_uid == getuid() else { return .refused("owned by another user") }
        guard st.st_size <= limit else { return .refused("larger than \(limit) bytes") }
        do { return .ok(try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit) ?? Data()) } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    static let missing = Failure(message: "Sprava's document reader (sprava-extract) is missing, so the file was not opened; reinstall Sprava")
    static let unsandboxed = Failure(message: "Sprava's document reader (sprava-extract) is not signed with its sandbox, so the file was not opened; "
                                              + "reinstall Sprava, or build the app with scripts/build-app.sh")

    /// Whether a helper carries a valid code signature whose entitlements are the App Sandbox and nothing else
    /// (Resources/sprava-extract.entitlements). A development build from `swift build` is signed without them,
    /// so it never receives a document's bytes.
    public static func isSandboxed(_ helper: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else { return false }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements.count == 1 && entitlements["com.apple.security.app-sandbox"] as? Bool == true
    }

    /// The same for bytes already in memory, such as an attachment inside an email file.
    public static func run(_ data: Data, name: String, reader: Reader, timeout: TimeInterval = 180) throws -> Extractor.Result {
        let helper: URL
        switch reader {
        case .helper(let url):
            // The sandbox is checked before any byte leaves this process (architecture 2.1).
            guard isSandboxed(url) else { throw Self.unsandboxed }
            helper = url
        case .missing: throw Self.missing
        case .inProcess: return Extractor.extract(data, name: name)
        }
        return try launch(helper, data: data, name: name, timeout: timeout)
    }

    enum AnswerEnding { case closed, timedOut, overflow }

    /// Reads a pipe until its other end closes, `deadline` passes or more than `max` bytes came, waiting in `poll`
    /// so the deadline holds even when nothing arrives.
    static func readAnswer(_ fd: Int32, until deadline: Date, max: Int) -> (Data, AnswerEnding) {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return (out, .timedOut) }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
            if ready < 0, errno != EINTR { return (out, .closed) }
            guard ready > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return (out, .closed) }
            if n == 0 { return (out, .closed) }
            out.append(contentsOf: buffer[0..<n])
            if out.count > max { return (out, .overflow) }
        }
    }

    /// Stops a helper: SIGTERM, then SIGKILL, which cannot be caught or ignored, if it is still there after `grace`,
    /// then a last bounded wait for it to go.
    static func stop(_ task: Process, grace: TimeInterval) {
        guard task.isRunning else { return }
        task.terminate()
        var until = Date() + grace
        while task.isRunning, Date() < until { usleep(10_000) }
        guard task.isRunning else { return }
        kill(task.processIdentifier, SIGKILL)
        until = Date() + grace
        while task.isRunning, Date() < until { usleep(10_000) }
    }

    /// Whether the bytes reached the helper whole; set by the writer before it signals, read after.
    private final class Delivery: @unchecked Sendable { var failed = false }

    /// Runs a helper already checked: the bytes on standard input, JSON back on standard output.
    /// Nothing here waits without a bound: the answer is read until `timeout`, and a helper that is still there then,
    /// or that answers past `maxAnswer`, is sent SIGTERM, then SIGKILL after `grace`. A helper that ignores SIGTERM,
    /// or a process it left holding the pipe open, never wedges the caller.
    static func launch(_ helper: URL, data: Data, name: String, timeout: TimeInterval,
                       maxAnswer: Int = 2 * Extractor.Limits().bytes, grace: TimeInterval = 2) throws -> Extractor.Result {
        let task = Process()
        task.executableURL = helper
        task.arguments = [name]
        task.environment = [:]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        // A helper that exits, or is stopped by the timeout, before it read every byte closes the pipe: the write
        // then fails with EPIPE instead of raising SIGPIPE, which would end the caller (the runtime) with it.
        let writer = input.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw Failure(message: "the reader could not be started") }
        let deadline = Date() + timeout
        try task.run()
        let delivery = Delivery(), delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try writer.write(contentsOf: data) } catch { delivery.failed = true }
            try? writer.close()
            delivered.signal()
        }
        // The answer is read up to a bound, twice the input limit (attachments come back in base64): a helper a file
        // took over cannot fill this unsandboxed process's memory.
        let reader = output.fileHandleForReading
        let (out, ending) = readAnswer(reader.fileDescriptor, until: deadline, max: maxAnswer)
        try? reader.close()   // nothing reads it any more, so a process still holding the other end cannot block us
        switch ending {
        case .overflow:
            stop(task, grace: grace)
            throw Failure(message: "the reader's answer was larger than the limit")
        case .timedOut:
            stop(task, grace: grace)
            throw Failure(message: "the reader took longer than \(Int(timeout)) seconds on this file and was stopped")
        case .closed:
            // The answer is complete; the helper is given its time to exit, and then stopped.
            let exitBy = Date() + grace
            while task.isRunning, Date() < exitBy { usleep(10_000) }
            stop(task, grace: grace)
        }
        guard !task.isRunning else { throw Failure(message: "the reader did not stop") }
        // The helper is gone, so its end of the pipe is closed and the write has ended or fails at once; a writer
        // still stuck after a short wait is abandoned, and the file is not read.
        let whole = delivered.wait(timeout: .now() + 5) == .success && !delivery.failed
        guard whole, task.terminationStatus == 0, let v = try? JSONParser.parse(out).value else {
            throw Failure(message: task.terminationReason == .uncaughtSignal ? "the reader stopped on this file" : "the reader failed on this file")
        }
        var r = Extractor.Result(kind: v["kind"]?.stringValue ?? "unknown", text: v["text"]?.stringValue ?? "",
                                 textFrom: v["text_from"]?.stringValue ?? "parsed", pages: v["pages"]?.numberValue?.safeInteger.map(Int.init),
                                 problem: v["problem"]?.stringValue)
        r.mismatch = v["mismatch"] == .bool(true)
        if let e = v["email"] {
            r.email = Extractor.Email(subject: e["subject"]?.stringValue, from: e["from"]?.stringValue, to: e["to"]?.stringValue,
                                      date: e["date"]?.stringValue, messageID: e["message_id"]?.stringValue,
                                      attachments: (e["attachments"]?.arrayValue ?? []).compactMap { a in
                                          guard let n = a["name"]?.stringValue, let d = a["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else { return nil }
                                          return .init(name: n, data: d)
                                      })
        }
        return r
    }
}
