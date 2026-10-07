import Darwin
import Foundation
import SpravaCore

// sprava-mcp: the stdio shim a brain launches (architecture 7.2). It connects to the runtime's socket,
// authenticates with the client's token, then copies newline-delimited JSON-RPC between stdio and the socket
// without parsing MCP content. Only MCP goes to stdout; its own messages go to stderr.

var args = Array(CommandLine.arguments.dropFirst())
var clientID: String?
if let i = args.firstIndex(of: "--client"), i + 1 < args.count { clientID = args[i + 1] }
let token = ProcessInfo.processInfo.environment["SPRAVA_CLIENT_TOKEN"] ?? ""
let socketPath = SpravaPaths.supportDirectory().appendingPathComponent("mcp/mcp.sock").path

/// Answers the client's first request with an error naming the part that failed, then exits non-zero, so the
/// client shows the reason (architecture 7.2).
func failWith(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sprava-mcp: \(message)\n".utf8))
    if let line = readLine(), let value = try? JSONParser.parse(line).value, let id = value["id"] {
        let reply = JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", id),
                                             ("error", .obj([("code", .int(-32000)), ("message", .string(message))]))]))
        print(reply)
        fflush(stdout)
    }
    exit(1)
}

guard let clientID else { failWith("usage: sprava-mcp --client <id> (with SPRAVA_CLIENT_TOKEN set)") }
guard !token.isEmpty else { failWith("no Sprava token in this client's settings; see Sprava > Brains") }

let fd: Int32
switch MCPShimConnection.connect(socket: socketPath, clientID: clientID, token: token) {
case .success(let f): fd = f
case .failure(let failure): failWith(failure.message)
}

signal(SIGPIPE, SIG_IGN)
// Socket -> stdout.
let pump = Thread {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { exit(n == 0 ? 0 : 1) }
        var off = 0
        while off < n {
            let w = buffer.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress! + off, n - off) }
            if w <= 0 { exit(1) }
            off += w
        }
    }
}
pump.start()
// Stdin -> socket, with the 4 MiB line limit.
let reader = LineReader(fd: STDIN_FILENO)
while true {
    switch reader.next(limit: MCPListener.lineLimit) {
    case .line(let line): if !writeLine(fd, line) { exit(1) }
    case .tooLong: FileHandle.standardError.write(Data("sprava-mcp: a message longer than 4 MiB\n".utf8)); exit(1)
    case .end, .timeout:
        // Input ended: half-close, then let the pump deliver the remaining replies and exit on the socket's end.
        shutdown(fd, SHUT_WR)
        while true { sleep(60) }
    }
}
