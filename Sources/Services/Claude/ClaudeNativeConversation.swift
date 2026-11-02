import Brains
import Foundation

/// All effective local checks precede a person/binder turn. The only initial model request when the
/// person presses Enable is a fixed data-free canary, through the same launch and framing contract.
enum ClaudeNativeConversation {
    /// `binder` gives the session its tools inside that folder; nil keeps it tool-free.
    static func driver(program: URL, support: URL, credential: String, connection: UUID, session: UUID,
                       policy: String, binder: URL?, appTools: ClaudeAppTools?, onSpawn: @escaping @Sendable (Int32) throws -> Void) async throws -> ClaudeConversationRuntime.Driver {
        let proxy = try binder.map { _ in try AgentEgressProxy.shared() }
        let reach = binder.flatMap { folder in proxy.map { ClaudeReadLaunch.Reach(folder: folder, proxyPort: $0.port) } }
        let prepared = try ClaudeReadLaunch.prepare(program: program, support: support, connectionID: connection, sessionID: session,
                                                   credential: credential, policy: policy, reach: reach, appTools: appTools, onSpawn: { pid in
            proxy?.authorize(pid) // sandbox-exec becomes the CLI, keeping this pid.
            try onSpawn(pid)
        })
        try await ClaudeReadAccount.verify(prepared)
        // A command the agent runs can take minutes; a turn of reading and filing can take many.
        let runner = ClaudeReadOnlyTurn(launch: prepared.launch,
            limits: try binder == nil && appTools == nil ? .init(inactivity: .seconds(90), overall: .seconds(240), terminationGrace: .seconds(2))
                                      : .init(inactivity: .seconds(300), overall: .seconds(1200), terminationGrace: .seconds(2)))
        return .init(run: { line, resume in
            switch try await runner.run(line, resume: resume) {
            case .text(let text): return text
            case .interrupted: return nil
            }
        }, stop: { runner.stop() }, exited: { runner.processExitConfirmed }, hash: prepared.programHash)
    }
}
