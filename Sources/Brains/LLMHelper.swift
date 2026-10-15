import Darwin
import Extract
import Foundation
import SpravaKit

/// The front desk's local model (docs/conversation.md 11.2): the bundled `sprava-llm` (llama.cpp's llama-server), App
/// Sandbox only, started on the first call with the model on an inherited descriptor and answering only on a Unix
/// socket in its own container. Every call renders the prompt with `/apply-template` and asks `/completion` for JSON
/// constrained by a schema, never the chat endpoint, where a model can write its thinking before the schema applies.
/// A reply that is late, too large, cut off or not the JSON asked for is refused. Calls run one at a time.
/// Logs carry outcomes and durations, never a prompt or a reply (code-structure 4).
public final class LLMHelper: @unchecked Sendable {
    /// The helper's code-signing identifier, which names its sandbox container.
    public static let bundleIdentifier = "ca.orlenko.sprava.llm"

    /// Bounds on every call (11.2; the values are proposed). Every call sets `n_predict`, which is otherwise unlimited.
    public struct Limits: Sendable {
        public var call: TimeInterval = 30          // each call's deadline, from a ready helper
        public var start: TimeInterval = 120        // from the launch to a healthy server with the model loaded
        public var maxTokens = 1_000                // the most tokens a reply may take
        public var maxPromptBytes = 64 * 1024       // one call's messages (answer calls stay within 2,000 to 4,000 tokens)
        public var maxReplyBytes = 1024 * 1024      // the largest HTTP answer read from the helper
        public var idleStop: TimeInterval = 15 * 60 // the helper is stopped after this long without a call
        public var sleepIdle = 60                   // `--sleep-idle-seconds`: llama-server frees the weights when idle
        public var contextTokens = 8_192
        public var grace: TimeInterval = 2          // from SIGTERM to SIGKILL
        public init() {}
    }

    public struct Message: Sendable, Equatable {
        public enum Role: String, Sendable { case system, user, assistant }
        public let role: Role
        public let content: String
        public init(_ role: Role, _ content: String) { (self.role, self.content) = (role, content) }
    }

    /// Why a call failed, as a code for logs and a plain sentence for the person; neither holds any text of the call.
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public enum Code: String, Sendable {
            case missing, unsandboxed, modelUnreadable = "model_unreadable", socketPath = "socket_path", startFailed = "start_failed"
            case unavailable, timedOut = "timed_out", tooLarge = "too_large", cutOff = "cut_off", refused
            case invalidReply = "invalid_reply", badRequest = "bad_request"
        }
        public let code: Code
        init(_ code: Code) { self.code = code }

        public var description: String {
            switch code {
            case .missing: "Sprava's local model helper (sprava-llm) is missing; reinstall Sprava"
            case .unsandboxed: "Sprava's local model helper (sprava-llm) is not signed with its sandbox, so it was not started; "
                + "reinstall Sprava, or build the app with scripts/build-app.sh"
            case .modelUnreadable: "The local model's file could not be opened"
            case .socketPath: "The local model cannot be reached: the path of its socket is longer than macOS allows"
            case .startFailed: "The local model did not start"
            case .unavailable: "The local model stopped answering; it is started again on the next request"
            case .timedOut: "The local model did not answer in time and was stopped"
            case .tooLarge: "The request or the local model's answer was larger than the limit"
            case .cutOff: "The local model's answer was cut off, so it was not used"
            case .refused: "The local model refused the request"
            case .invalidReply: "The local model's answer was not the JSON asked for, so it was not used"
            case .badRequest: "The request to the local model was not valid"
            }
        }
    }

    let socket: String
    let limits: Limits
    let log: @Sendable (String) -> Void
    /// Seconds on a clock that only moves forward (the uptime clock; a test's own).
    let now: @Sendable () -> TimeInterval
    let launch: (String, Limits) throws -> LLMProcess
    private let lock = NSLock()
    private var process: LLMProcess?
    private var lastUse: TimeInterval = 0

    /// The bundled helper on `model`, answering at `socket` (its container's, by default).
    public convenience init(helper: URL, model: URL, socket: String = LLMHelper.socketPath(), limits: Limits = Limits(),
                            log: @escaping @Sendable (String) -> Void) {
        self.init(socket: socket, limits: limits, log: log) { socket, limits in
            try LLMHelper.launchSandboxed(helper, model: model, socket: socket, limits: limits)
        }
    }

    init(socket: String, limits: Limits, log: @escaping @Sendable (String) -> Void,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         launch: @escaping (String, Limits) throws -> LLMProcess) {
        self.socket = socket
        self.limits = limits
        self.log = log
        self.now = now
        self.launch = launch
    }

    deinit { process?.stop(grace: limits.grace) }

    /// The socket in the helper's container: the sandbox lets it create files nowhere else.
    public static func socketPath(home: String = NSHomeDirectory()) -> String {
        "\(home)/Library/Containers/\(bundleIdentifier)/Data/tmp/llm.sock"
    }

    /// llama-server's arguments: the model on descriptor 3, the Unix socket and no TCP port, one slot, no web UI and
    /// no `/slots` endpoint, and sleep when idle.
    static func arguments(socket: String, limits: Limits) -> [String] {
        ["-m", "/dev/fd/3", "--host", socket, "-c", String(limits.contextTokens), "-ngl", "99", "-np", "1",
         "--no-ui", "--no-slots", "--sleep-idle-seconds", String(limits.sleepIdle)]
    }

    /// Asks the model for one JSON object that `schema` constrains, in at most `maxTokens` tokens (never more than the
    /// limit), and returns it parsed. The helper is started first when it is not running.
    public func complete(_ messages: [Message], schema: JSONValue, maxTokens: Int? = nil) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        let started = now()
        defer { lastUse = now() }
        do {
            let value = try call(messages, schema: schema, maxTokens: min(maxTokens ?? limits.maxTokens, limits.maxTokens))
            log("llm call outcome=ok ms=\(Self.ms(now() - started))")
            return value
        } catch let failure as Failure {
            log("llm call outcome=\(failure.code.rawValue) ms=\(Self.ms(now() - started))")
            throw failure
        }
    }

    /// Stops the helper when no call came for `limits.idleStop`; the runtime's timer calls this. A call under way is
    /// never interrupted.
    @discardableResult
    public func stopIfIdle() -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard process != nil, now() - lastUse >= limits.idleStop else { return false }
        retire("idle")
        return true
    }

    public func stop() { lock.withLock { if process != nil { retire("stopped") } } }

    public var isRunning: Bool { lock.withLock { process?.isRunning ?? false } }

    private func call(_ messages: [Message], schema: JSONValue, maxTokens: Int) throws -> JSONValue {
        guard maxTokens > 0, schema.objectValue != nil else { throw Failure(.badRequest) }
        guard messages.reduce(0, { $0 + $1.content.utf8.count }) <= limits.maxPromptBytes else { throw Failure(.tooLarge) }
        try ensureRunning()
        let deadline = LLMHTTP.Deadline(in: limits.call)
        let rendered = try post("/apply-template", .obj([
            ("messages", .array(messages.map { .obj([("role", .str($0.role.rawValue)), ("content", .str($0.content))]) })),
            ("chat_template_kwargs", .obj([("enable_thinking", .bool(false))])),
        ]), until: deadline)
        guard let prompt = rendered["prompt"]?.stringValue else { throw Failure(.invalidReply) }
        let reply = try post("/completion", .obj([
            ("prompt", .str(prompt)), ("n_predict", .int(maxTokens)), ("temperature", .int(0)), ("json_schema", schema),
            ("cache_prompt", .bool(true)), ("stream", .bool(false)),
            ("response_fields", .array(["content", "stop_type", "truncated"].map { .str($0) })),
        ]), until: deadline)
        return try Self.answer(reply, schema: schema)
    }

    /// The model's answer from a `/completion` reply: whole (stopped at its end, its prompt not truncated), one JSON
    /// object with no repeated key, holding every key the schema requires and, when it allows no others, no other.
    static func answer(_ reply: JSONValue, schema: JSONValue) throws -> JSONValue {
        guard let stop = reply["stop_type"]?.stringValue, let truncated = reply["truncated"]?.boolValue,
              let content = reply["content"]?.stringValue else { throw Failure(.invalidReply) }
        guard stop == "eos", !truncated else { throw Failure(.cutOff) }
        guard let parsed = try? JSONParser.parse(content), parsed.safety.isSafe, let object = parsed.value.objectValue else {
            throw Failure(.invalidReply)
        }
        for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !object.contains(key) {
            throw Failure(.invalidReply)
        }
        if schema["additionalProperties"] == .bool(false), let allowed = schema["properties"]?.objectValue,
           object.keys.contains(where: { !allowed.contains($0) }) {
            throw Failure(.invalidReply)
        }
        return parsed.value
    }

    private func post(_ target: String, _ body: JSONValue, until deadline: LLMHTTP.Deadline) throws -> JSONValue {
        let data = Data(JSONWriter.compact(body).utf8)
        switch LLMHTTP.exchange(socket: socket, method: "POST", target: target, body: data, until: deadline, maxReply: limits.maxReplyBytes) {
        case .success(let reply):
            guard reply.status == 200 else { throw Failure(.refused) }
            guard let parsed = try? JSONParser.parse(reply.body), parsed.safety.isSafe, parsed.value.objectValue != nil else {
                throw Failure(.invalidReply)
            }
            return parsed.value
        case .failure(let failure):
            // Closing the connection asks llama-server to cancel; a helper that went on would hold the only slot, so after
            // a late, oversized or broken answer it is stopped, and started again on the next call (11.2).
            let code: Failure.Code = failure == .timedOut ? .timedOut : failure == .tooLarge ? .tooLarge : .unavailable
            retire(code.rawValue)
            throw Failure(code)
        }
    }

    /// Starts the helper when it is not running, and waits until `/health` says it holds the model.
    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        process = nil
        guard unixAddress(socket) != nil else { throw Failure(.socketPath) }
        // llama-server does not replace a socket left by a helper that ended; nothing but a socket is removed.
        var st = stat()
        if lstat(socket, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK, unlink(socket) == 0 else { throw Failure(.startFailed) }
        }
        let started = now()
        let launched: LLMProcess
        do { launched = try launch(socket, limits) } catch {
            let code = (error as? Failure)?.code ?? .startFailed
            log("llm start outcome=\(code.rawValue)")
            throw Failure(code)
        }
        process = launched
        lastUse = now()
        let deadline = LLMHTTP.Deadline(in: limits.start)
        while true {
            let probe = LLMHTTP.Deadline(in: max(0.05, min(2, deadline.remaining)))
            if case .success(let reply) = LLMHTTP.exchange(socket: socket, method: "GET", target: "/health", until: probe, maxReply: 4096),
               reply.status == 200, (try? JSONParser.parse(reply.body))?.value["status"]?.stringValue == "ok" {
                log("llm start outcome=ready ms=\(Self.ms(now() - started))")
                return
            }
            guard launched.isRunning, deadline.remaining > 0 else {
                retire(launched.isRunning ? "start_timed_out" : "exited")
                throw Failure(.startFailed)
            }
            usleep(50_000)
        }
    }

    /// Stops the helper and removes its socket; the next call starts a new one.
    private func retire(_ reason: String) {
        process?.stop(grace: limits.grace)
        process = nil
        var st = stat()
        if lstat(socket, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK { unlink(socket) }
        log("llm stop reason=\(reason)")
    }

    static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }

    /// Checks and starts the bundled helper: present, signed with the App Sandbox and nothing else, the model a
    /// regular file opened here and handed over as descriptor 3, so the sandbox needs no access to its folder.
    static func launchSandboxed(_ helper: URL, model: URL, socket: String, limits: Limits) throws -> LLMProcess {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Failure(.missing) }
        guard ExtractHelper.isSandboxed(helper) else { throw Failure(.unsandboxed) }
        let fd = open(model.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure(.modelUnreadable) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw Failure(.modelUnreadable) }
        SpawnedLLM.endOrphans(of: helper)
        return try SpawnedLLM.spawn(helper, arguments: arguments(socket: socket, limits: limits), fd: fd)
    }
}
