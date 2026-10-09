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

    /// Reads `file` and runs the helper on its bytes. `root` is the folder the file is anchored to (the binder for a
    /// file in its intake); by default the binder of the nearest `intake` folder above the file, else its own folder.
    public static func run(_ file: URL, under root: URL? = nil, reader: Reader, timeout: TimeInterval = 180) throws -> Extractor.Result {
        if reader == .missing { throw Self.missing }
        // Never through a link, which could lead a harmless name to a credential file, and never anything but a
        // regular file of this user within the size limit, so a FIFO or a device cannot stall the read.
        switch read(file, under: root ?? anchor(of: file), limit: Extractor.Limits().bytes) {
        case .ok(let data): return try run(data, name: file.lastPathComponent, reader: reader, timeout: timeout)
        case .refused(let why): throw Failure(message: "the file was not opened: it is \(why)")
        case .missing: throw Failure(message: "the file is not there")
        case .unreadable(let why): throw Failure(message: "the file cannot be read now (\(why))")
        }
    }

    /// The binder holding the nearest `intake` folder above a file, else the file's own folder.
    static func anchor(of file: URL) -> URL {
        let folder = file.standardizedFileURL.deletingLastPathComponent()
        var probe = folder
        while probe.pathComponents.count > 1 {
            if probe.lastPathComponent == "intake" { return probe.deletingLastPathComponent() }
            probe = probe.deletingLastPathComponent()
        }
        return folder
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
        let task = Process()
        task.executableURL = helper
        task.arguments = [name]
        task.environment = [:]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        DispatchQueue.global().async {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()
        guard task.terminationStatus == 0, let v = try? JSONParser.parse(out).value else {
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
