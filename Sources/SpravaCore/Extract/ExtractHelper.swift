import Foundation

/// Runs the sandboxed `sprava-extract` helper on one file (architecture 2.1): the bytes go in on standard input,
/// JSON comes back; a crash or a hang ends only the helper.
public enum ExtractHelper {
    /// The helper beside the running executable (the app bundle, or a development build's products).
    public static func locate() -> URL? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sprava-extract"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("sprava-extract")].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func run(_ file: URL, helper: URL? = locate(), timeout: TimeInterval = 180) throws -> Extractor.Result {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw Failure(message: "the file cannot be read") }
        return try run(data, name: file.lastPathComponent, helper: helper, timeout: timeout)
    }

    /// The same for bytes already in memory, such as an attachment inside an email file.
    public static func run(_ data: Data, name: String, helper: URL? = locate(), timeout: TimeInterval = 180) throws -> Extractor.Result {
        guard let helper else {
            // No helper (a test run): extract in process.
            return Extractor.extract(data, name: name)
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
