import Foundation
import SpravaKit
import Testing
@testable import Brains

/// Sprava's own tools on the agent's pipe: the frames, the launch, and a whole turn with an invented process.
@Suite struct ClaudeAppToolsTests {
    let session = UUID()
    var sid: String { session.uuidString.lowercased() }
    func frame(_ json: String) throws -> JSONObject { try #require(JSONParser.parse(json).value.objectValue) }
    static let tool = ClaudeAppTools.Tool(name: "add_todo", description: "Invented", schema: .obj([("type", .str("object"))]))
    static let name = "mcp__sprava__add_todo"
    func request(_ id: String = "r1", server: String = "sprava", subtype: String = "mcp_message", method: String = "tools/list") -> String {
        #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"\#(subtype)","server_name":"\#(server)","message":{"jsonrpc":"2.0","id":1,"method":"\#(method)"}}}"#
    }
    func initFrame(_ servers: String = #"[{"name":"sprava","status":"connected","source":"sdk"}]"#) -> String {
        #"{"type":"system","subtype":"init","session_id":"\#(sid)","tools":["\#(Self.name)"],"mcp_servers":\#(servers),"permissionMode":"default"}"#
    }
    func frames(tools: Bool = true) -> ClaudeReadOnlyFrames {
        ClaudeReadOnlyFrames(sessionID: session, original: "Tidy", tools: [Self.name], appTools: tools)
    }

    @Test func theAgentAsksForToolsBeforeItsInitFrameAndRepeatsTheAnswers() throws {
        var f = frames()
        try f.receive(frame(request()))
        let asked = f.takeToolRequests()
        #expect(asked.map(\.id) == ["r1"] && f.toolRequests.isEmpty)
        // Its repeat of the answer is expected once.
        try f.receive(frame(#"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{}}}"#))
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) {
            try f.receive(frame(#"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{}}}"#))
        }
    }

    @Test func aToolRunsOnlyWithinThePersonsTurn() throws {
        var f = frames()
        #expect(!f.turnOpen)
        try f.receive(frame(initFrame()))
        #expect(!f.turnOpen)
        try f.receive(frame(#"{"type":"user","session_id":"\#(sid)","parent_tool_use_id":null,"message":{"role":"user","content":"Tidy"}}"#))
        #expect(f.turnOpen)
        f.interruptID = UUID()
        #expect(!f.turnOpen)
    }

    @Test func noOtherRequestOrServerIsAccepted() throws {
        var f = frames()
        for bad in [request(server: "other"), request(subtype: "can_use_tool"), request(subtype: "hook_callback"),
                    #"{"type":"control_request","request_id":"r1","request":{"subtype":"mcp_message","server_name":"sprava"}}"#] {
            #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) { try f.receive(frame(bad)) }
        }
        var without = frames(tools: false)
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) { try without.receive(frame(request())) }
    }

    @Test func aLaunchWhoseServerDidNotConnectFails() throws {
        for servers in [#"[]"#, #"[{"name":"sprava","status":"failed"}]"#, #"[{"name":"outside","status":"connected"}]"#,
                        #"[{"name":"sprava","status":"connected"},{"name":"outside","status":"connected"}]"#] {
            var f = frames()
            #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) { try f.receive(frame(initFrame(servers))) }
        }
        var plain = frames(tools: false)
        #expect(throws: ClaudeReadOnlyTurn.Failure.protocolMismatch) { try plain.receive(frame(initFrame())) }
    }

    @Test func answersFollowTheProtocolAndAStoppedTurnRunsNothing() throws {
        let called = Counter()
        let tools = ClaudeAppTools(tools: [Self.tool]) { _, args in
            called.add()
            return .init(content: .obj([("title", args["title"] ?? .null)]))
        }
        func message(_ json: String) throws -> JSONObject { try frame(json) }
        let hello = tools.answer(try message(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#), open: false)
        #expect(hello["result"]?["protocolVersion"] == .str("2025-11-25") && hello["id"] == .int(0))
        #expect(tools.answer(try message(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#), open: false)["result"]?["tools"]?.arrayValue?.first?["name"] == .str("add_todo"))
        #expect(tools.answer(try message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), open: false)["error"] == nil)
        #expect(tools.answer(try message(#"{"jsonrpc":"2.0","id":2,"method":"elsewhere"}"#), open: true)["error"] != nil)
        let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_todo","arguments":{"title":"Invented"}}}"#
        #expect(tools.answer(try message(call), open: false)["result"]?["isError"] == .bool(true) && called.value == 0)
        let wrong = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"other","arguments":{}}}"#
        #expect(tools.answer(try message(wrong), open: true)["result"]?["isError"] == .bool(true) && called.value == 0)
        let done = tools.answer(try message(call), open: true)
        #expect(done["result"]?["isError"] == .bool(false) && done["result"]?["structuredContent"]?["title"] == .str("Invented") && called.value == 1)
    }

    @Test func theLaunchOffersExactlyTheToolsInBothModes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-app-tools-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let binder = root.appendingPathComponent("binder")
        try FileManager.default.createDirectory(at: binder, withIntermediateDirectories: true)
        let tools = ClaudeAppTools(tools: [Self.tool]) { _, _ in .init(content: .null) }
        func plan(reach: ClaudeReadLaunch.Reach?, appTools: ClaudeAppTools?) throws -> ClaudeReadOnlyTurn.Launch {
            try ClaudeReadLaunch.plan(program: URL(fileURLWithPath: "/opt/invented/claude"), home: root.appendingPathComponent("home-\(UUID())"), sessionID: session,
                                      credential: "invented", policy: "invented", reach: reach, appTools: appTools)
        }
        func argument(_ name: String, _ launch: ClaudeReadOnlyTurn.Launch) -> String? {
            launch.arguments.firstIndex(of: name).map { launch.arguments[$0 + 1] }
        }
        let bare = try plan(reach: nil, appTools: nil)
        #expect(bare.tools.isEmpty && argument("--mcp-config", bare) == "{\"mcpServers\":{}}" && argument("--disallowedTools", bare) == "*")

        let todosOnly = try plan(reach: nil, appTools: tools)
        #expect(todosOnly.tools == [Self.name] && argument("--tools", todosOnly) == "" && argument("--allowedTools", todosOnly) == Self.name)
        #expect(argument("--disallowedTools", todosOnly) == nil)
        #expect(argument("--mcp-config", todosOnly) == #"{"mcpServers":{"sprava":{"type":"sdk","name":"sprava"}}}"#)

        let withFiles = try plan(reach: .init(folder: binder, proxyPort: 9), appTools: tools)
        #expect(withFiles.tools == Set(ClaudeReadLaunch.tools + [Self.name]))
        #expect(argument("--allowedTools", withFiles)?.contains(Self.name) == true && argument("--allowedTools", withFiles)?.contains("Bash(rm:*)") == true)
    }

    @Test func aWholeTurnAnswersItsToolsOnThePipe() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-app-tools-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        let locator = Process(), located = Pipe()
        locator.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); locator.arguments = ["--find", "python3"]; locator.standardOutput = located
        try locator.run()
        let python = String(decoding: located.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        locator.waitUntilExit()
        let titles = Titles()
        let tools = ClaudeAppTools(tools: [Self.tool]) { _, args in
            titles.add(args["title"]?.stringValue ?? "")
            return .init(content: .obj([("id", .str("t-1"))]))
        }
        let session = UUID()
        let runner = ClaudeReadOnlyTurn(launch: .init(executable: URL(fileURLWithPath: python), arguments: ["-I", "-S", "-u", script.path],
            environment: [:], directory: directory, sessionID: session, tools: [Self.name], appTools: tools),
            limits: try .init(inactivity: .seconds(10), overall: .seconds(20), terminationGrace: .milliseconds(100)))
        guard case .text(let reply) = try await runner.run("Add the invented task", resume: false) else { Issue.record("no reply"); return }
        #expect(reply == "added t-1")
        #expect(titles.values == ["Invented task"])
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    final class Titles: @unchecked Sendable {
        private let lock = NSLock(); private var list: [String] = []
        func add(_ title: String) { lock.withLock { list.append(title) } }
        var values: [String] { lock.withLock { list } }
    }

    /// What the real CLI 2.1.316 does: asks for the tools first, repeats each answer, calls a tool after the person's line.
    static let script = #"""
    import json, sys
    sid = sys.argv[-1]
    def emit(value): print(json.dumps(value), flush=True)
    def ask(id, message):
        emit(dict(type='control_request', request_id=id, request=dict(subtype='mcp_message', server_name='sprava', message=message)))
        global line
        answer = json.loads(sys.stdin.readline())
        if answer['type'] == 'user':
            line = answer # The person's line waits in the pipe while the tools are asked for.
            answer = json.loads(sys.stdin.readline())
        assert answer['type'] == 'control_response' and answer['response']['request_id'] == id
        emit(answer)
        return answer['response']['response']['mcp_response']
    line = None
    assert ask('a', dict(jsonrpc='2.0', id=0, method='initialize', params=dict(protocolVersion='2025-11-25')))['result']['serverInfo']['name'] == 'sprava'
    ask('b', dict(jsonrpc='2.0', method='notifications/initialized'))
    assert ask('c', dict(jsonrpc='2.0', id=1, method='tools/list'))['result']['tools'][0]['name'] == 'add_todo'
    emit(dict(type='system', subtype='init', session_id=sid, tools=['mcp__sprava__add_todo'], mcp_servers=[dict(name='sprava', status='connected', source='sdk')], permissionMode='default'))
    line = line or json.loads(sys.stdin.readline())
    emit(dict(type='user', session_id=sid, message=dict(role='user', content=line['message']['content'])))
    emit(dict(type='assistant', session_id=sid, message=dict(role='assistant', content=[dict(type='tool_use', id='u1', name='mcp__sprava__add_todo', input=dict(title='Invented task'))])))
    done = ask('d', dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='add_todo', arguments=dict(title='Invented task'))))
    assert done['result']['isError'] is False
    emit(dict(type='user', session_id=sid, parent_tool_use_id=None, message=dict(role='user', content=[dict(type='tool_result', tool_use_id='u1', content=[])])))
    emit(dict(type='result', session_id=sid, subtype='success', is_error=False, result='added ' + done['result']['structuredContent']['id']))
    """#
}
